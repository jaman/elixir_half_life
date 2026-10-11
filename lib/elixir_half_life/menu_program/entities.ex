defmodule ElixirHalfLife.MenuProgram.Entities do
  @moduledoc """
  The menu program's own entity and text builtins (FTE's `pr_menu.c`), by name:

    * `clearscene` — the client program's `clearscene` (`ElixirHalfLife.Csqc.Scene`),
      the world left out of the scene (view property 19, `VF_DRAWWORLD`, 0)
    * `etof`, `ftoe` — an entity as its number and back
    * `findchain(field, text)`, `findchainfloat(field, value)` — every entity whose string
      field equals `text` (a null field never matches) or whose float field equals
      `value`, linked through `.chain` (the first found last, ending at the world) and
      the last found returned; `findchainflags(field, flags)` links every entity whose
      field has none of `flags`' bits, as FTE's menu program does
    * `setmodel(entity, name)` — `.model` set to the name, `.modelindex` to the model's
      index in the menu's own list (`QuakeServer.Models.precache/2`) and `.mins`/`.maxs`
      to its box; `precache_model(name)` registers the model; `getmodelindex(name)` its
      index
    * `setorigin(entity, origin)` — `.origin` only
    * `validstring(text)` — whether the string is not null
    * `altstr_count`, `altstr_prepare`, `altstr_get`, `altstr_set` — DarkPlaces'
      single-quoted string lists: the count of quoted strings, a string with its `'`
      escaped, string `n` unescaped, and the list with string `n` replaced
  """

  import Bitwise

  alias ElixirHalfLife.Csqc.Scene
  alias QuakeServer.{Args, Edicts, Models}

  @doc "The builtins this module runs, by name."
  @spec builtins() :: [String.t()]
  def builtins,
    do: ~w(clearscene etof ftoe findchain findchainfloat findchainflags setmodel precache_model
      getmodelindex setorigin validstring altstr_count altstr_prepare altstr_get altstr_set)

  @doc "Run menu builtin `name`, one of `builtins/0`."
  @spec call(map(), String.t(), non_neg_integer()) :: map()
  def call(s, "clearscene", _argc) do
    s = Scene.call(s, 300, 0)
    qc = s.qc |> QuakeC.put_slot(4, 19.0) |> QuakeC.put_slot(7, 0.0)
    Scene.call(%{s | qc: qc}, 303, 2)
  end

  def call(s, "etof", _argc), do: Args.return(s, Args.int(s, 0) / 1)
  def call(s, "ftoe", _argc), do: Args.return(s, trunc(Args.num(s, 0)))

  def call(s, "findchain", _argc) do
    text = Args.str(s, 1)

    chain(s, fn entity, offset ->
      value = QuakeC.field_slot(s.qc, entity, offset)
      value not in [0, nil, 0.0] and QuakeC.string(s.qc, value) == text
    end)
  end

  def call(s, "findchainfloat", _argc) do
    match = Args.num(s, 1)

    chain(s, fn entity, offset ->
      QuakeC.float(QuakeC.field_slot(s.qc, entity, offset)) == match
    end)
  end

  def call(s, "findchainflags", _argc) do
    flags = trunc(Args.num(s, 1))

    chain(s, fn entity, offset ->
      band(trunc(QuakeC.float(QuakeC.field_slot(s.qc, entity, offset))), flags) == 0
    end)
  end

  def call(s, "setmodel", _argc) do
    entity = Args.int(s, 0)
    name = Args.str(s, 1)
    {s, index} = Models.precache(s, name)
    model = Models.get(s, index) || %{}

    s
    |> put_field(entity, "model", Args.slot(s, 1))
    |> put_field(entity, "modelindex", index / 1)
    |> put_field(entity, "mins", Map.get(model, :mins, {0.0, 0.0, 0.0}))
    |> put_field(entity, "maxs", Map.get(model, :maxs, {0.0, 0.0, 0.0}))
  end

  def call(s, "precache_model", _argc), do: s |> Models.precache(Args.str(s, 0)) |> elem(0)

  def call(s, "getmodelindex", _argc) do
    {s, index} = Models.precache(s, Args.str(s, 0))
    Args.return(s, index / 1)
  end

  def call(s, "setorigin", _argc), do: put_field(s, Args.int(s, 0), "origin", Args.vec(s, 1))

  def call(s, "validstring", _argc), do: Args.return(s, Args.slot(s, 0) not in [0, nil, 0.0])

  def call(s, "altstr_count", _argc),
    do: Args.return(s, div(quotes(Args.str(s, 0), 0), 2) / 1)

  def call(s, "altstr_prepare", _argc),
    do: Args.return(s, String.replace(Args.str(s, 0), "'", "\\'"))

  def call(s, "altstr_get", _argc) do
    case skip(Args.str(s, 0), trunc(Args.num(s, 1)) * 2 + 1) do
      "" -> Args.return(s, "")
      rest -> Args.return(s, take(rest, ""))
    end
  end

  def call(s, "altstr_set", _argc) do
    {before, rest} = split_at(Args.str(s, 0), trunc(Args.num(s, 1)) * 2 + 1, "")
    Args.return(s, before <> Args.str(s, 2) <> after_string(rest))
  end

  defp chain(s, matches?) do
    offset = Args.int(s, 0)
    chain_offset = QuakeC.field_offset(s.qc, "chain")

    {s, last} =
      Enum.reduce(1..(s.count - 1)//1, {s, 0}, fn entity, {s, last} ->
        if not Edicts.free?(s, entity) and matches?.(entity, offset) do
          {link(s, entity, chain_offset, last), entity}
        else
          {s, last}
        end
      end)

    Args.return(s, last)
  end

  defp link(s, _entity, nil, _last), do: s

  defp link(s, entity, offset, last),
    do: %{s | qc: QuakeC.put_field_slot(s.qc, entity, offset, last)}

  defp put_field(s, entity, name, value) do
    if QuakeC.field_offset(s.qc, name), do: Edicts.put(s, entity, name, value), else: s
  end

  defp quotes(<<>>, count), do: count
  defp quotes(<<?\\>>, count), do: count
  defp quotes(<<?\\, _, rest::binary>>, count), do: quotes(rest, count)
  defp quotes(<<?', rest::binary>>, count), do: quotes(rest, count + 1)
  defp quotes(<<_, rest::binary>>, count), do: quotes(rest, count)

  defp skip(text, 0), do: text
  defp skip(<<>>, _count), do: ""
  defp skip(<<?\\>>, _count), do: ""
  defp skip(<<?\\, _, rest::binary>>, count), do: skip(rest, count)
  defp skip(<<?', rest::binary>>, count), do: skip(rest, count - 1)
  defp skip(<<_, rest::binary>>, count), do: skip(rest, count)

  defp take(<<>>, acc), do: acc
  defp take(<<?\\>>, acc), do: acc
  defp take(<<?\\, char, rest::binary>>, acc), do: take(rest, acc <> <<char>>)
  defp take(<<?', _::binary>>, acc), do: acc
  defp take(<<char, rest::binary>>, acc), do: take(rest, acc <> <<char>>)

  defp split_at(text, 0, acc), do: {acc, text}
  defp split_at(<<>>, _count, acc), do: {acc, ""}
  defp split_at(<<?\\>>, _count, acc), do: {acc, ""}

  defp split_at(<<?\\, char, rest::binary>>, count, acc),
    do: split_at(rest, count, acc <> <<char>>)

  defp split_at(<<?', rest::binary>>, count, acc), do: split_at(rest, count - 1, acc <> "'")
  defp split_at(<<char, rest::binary>>, count, acc), do: split_at(rest, count, acc <> <<char>>)

  defp after_string(<<>>), do: ""
  defp after_string(<<?', _::binary>> = rest), do: rest
  defp after_string(<<?\\>>), do: ""
  defp after_string(<<?\\, _, rest::binary>>), do: after_string(rest)
  defp after_string(<<_, rest::binary>>), do: after_string(rest)
end
