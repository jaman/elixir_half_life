defmodule ElixirHalfLife.Csqc.Fonts do
  @moduledoc """
  The client program's font slots, as FTE's menu and client programs keep them
  (`PF_CL_loadfont`, `PF_CL_findfont`, `PR_CL_ChooseFont`), held in the host's
  `ext.fonts`.

  There are 32 slots, each with a slot name, a face name (`ElixirHalfLife.Csqc.Fonts.Font`)
  and up to 16 sizes in 2D units. Text drawn with `drawfont` set to a slot uses that
  slot's size nearest the height asked; a slot with no sizes, or a `drawfont` outside 0
  to 31, uses the default font: the `gl_font` console variable at height 8. A font is
  made at its size times the screen's pixels per 2D unit down
  (`ElixirHalfLife.Csqc.Screen.ratio/1`), as FTE loads fonts at `vid.rotpixelheight /
  vid.height`.

  Console variables read, with FTE's defaults: `gl_font` (`""`), `r_font_linear` (1),
  `r_font_postprocess_outline` (0).

      {host, slot} = ElixirHalfLife.Csqc.Fonts.load(host, "", "fonts/ibm/IBMPlexSansCondensed-Medium.otf", "20", -1)
      ElixirHalfLife.Csqc.Fonts.choose(host, slot, 20, 20)
  """

  alias ElixirHalfLife.Csqc.Fonts.Font
  alias ElixirHalfLife.Csqc.Screen
  alias QuakeServer.Server

  @slots 32
  @sizes 16

  @doc """
  Load face `facename` into a slot at the sizes in `sizes` (a space-separated list,
  which may also hold `scale=`, `outline=`, `blur=` and `voffset=`), as FTE's
  `loadfont`: slot `slot` when not below zero, else the slot named `slotname`, else the
  slot already holding `facename` (when `slotname` is empty), else the highest free slot.
  A slot whose names change is emptied first. Returns the host and the slot, 0 when none
  could be had.
  """
  @spec load(map(), String.t(), String.t(), String.t(), integer()) :: {map(), non_neg_integer()}
  def load(host, slotname, facename, sizes, slot) do
    fonts = fonts(host)
    slot = pick_slot(fonts, slotname, facename, slot)

    if slot < 0 or slot >= @slots do
      {host, 0}
    else
      entry = fonts.slots |> Map.get(slot, empty()) |> renamed(slotname, facename, host)
      entry = sizes |> tokens() |> Enum.reduce(entry, &size_token/2)
      {put_fonts(host, %{fonts | slots: Map.put(fonts.slots, slot, entry)}), slot}
    end
  end

  @doc "The slot named `slotname` plus one, or 0 (the default font) when there is none."
  @spec find(map(), String.t()) :: non_neg_integer()
  def find(host, slotname), do: named(fonts(host).slots, slotname, :slotname) + 1

  @doc "The font text is drawn with for `drawfont` value `selector` at size `width` by `height`."
  @spec choose(map(), number(), number(), number()) :: Font.t()
  def choose(host, selector, _width, height) do
    index = trunc(selector)
    wanted = trunc(height)

    case Map.get(fonts(host).slots, index) do
      %{sizes: [_ | _]} = entry when index >= 0 and index < @slots ->
        load_size(host, entry, nearest_size(entry.sizes, wanted))

      _ ->
        default(host)
    end
  end

  @doc "The default font: `gl_font` at height 8, or the built-in characters when that cannot be had."
  @spec default(map()) :: Font.t()
  def default(host), do: Font.load(cvar(host, "gl_font", ""), 8, options(host, outline(host)))

  defp fonts(host), do: Map.get(host.ext, :fonts, %{slots: %{}})

  defp nearest_size(sizes, wanted) do
    {_difference, size} = Enum.reduce(sizes, {10_000, nil}, &closer(&1, &2, wanted))
    size
  end

  defp closer(size, {best, chosen}, wanted) do
    difference = abs(wanted - size)
    if difference < best, do: {difference, size}, else: {best, chosen}
  end

  defp put_fonts(host, fonts), do: %{host | ext: Map.put(host.ext, :fonts, fonts)}

  defp empty, do: %{slotname: "", facename: "", sizes: [], scale: 1.0, outline: 0}

  defp pick_slot(fonts, slotname, _facename, slot) when slot < 0 and slotname != "",
    do: or_unused(fonts, named(fonts.slots, slotname, :slotname))

  defp pick_slot(fonts, _slotname, facename, slot) when slot < 0,
    do: or_unused(fonts, named(fonts.slots, facename, :facename))

  defp pick_slot(_fonts, _slotname, _facename, slot), do: slot

  defp or_unused(fonts, -1), do: unused(fonts.slots)
  defp or_unused(_fonts, slot), do: slot

  defp named(slots, name, key) do
    wanted = String.downcase(name)

    Enum.find(0..(@slots - 1), -1, fn i ->
      String.downcase(Map.get(Map.get(slots, i, empty()), key)) == wanted
    end)
  end

  defp unused(slots) do
    Enum.find((@slots - 1)..1//-1, -1, fn i ->
      entry = Map.get(slots, i, empty())
      entry.slotname == "" and entry.facename == ""
    end)
  end

  defp renamed(entry, slotname, facename, host) do
    same? =
      String.downcase(entry.slotname) == String.downcase(slotname) and
        String.downcase(entry.facename) == String.downcase(facename) and entry.sizes != []

    if same?,
      do: entry,
      else: %{empty() | slotname: slotname, facename: facename, outline: outline(host)}
  end

  defp size_token("scale=" <> value, entry), do: %{entry | scale: atof(value)}
  defp size_token("outline=" <> value, entry), do: %{entry | outline: trunc(atof(value))}
  defp size_token("blur=" <> _value, entry), do: entry
  defp size_token("voffset=" <> _value, entry), do: entry

  defp size_token(token, entry) do
    size = trunc(atof(token))

    cond do
      size == 0 -> entry
      size in entry.sizes -> entry
      length(entry.sizes) >= @sizes -> entry
      true -> %{entry | sizes: entry.sizes ++ [size]}
    end
  end

  defp load_size(host, entry, size),
    do: Font.load(entry.facename, size, %{options(host, entry.outline) | scale: entry.scale})

  defp options(host, outline) do
    %{
      scale: 1.0,
      outline: outline,
      linear: cvar_number(host, "r_font_linear", 1.0) != 0,
      pixels: host |> Screen.ratio() |> elem(1)
    }
  end

  defp outline(host), do: trunc(cvar_number(host, "r_font_postprocess_outline", 0.0))

  defp cvar(host, name, default) do
    if Server.cvar?(host, name), do: Server.cvar_string(host, name), else: default
  end

  defp cvar_number(host, name, default) do
    if Server.cvar?(host, name), do: Server.cvar(host, name), else: default
  end

  defp tokens(text) do
    ~r/"([^"]*)"|(\S+)/
    |> Regex.scan(text)
    |> Enum.map(fn
      [_, quoted] -> quoted
      [_, "", plain] -> plain
    end)
  end

  defp atof(text) do
    case Float.parse(String.trim(text)) do
      {value, _} -> value
      :error -> 0.0
    end
  end
end
