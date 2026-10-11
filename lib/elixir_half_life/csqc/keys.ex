defmodule ElixirHalfLife.Csqc.Keys do
  @moduledoc """
  The key builtins of FTE's client and menu programs (`pr_clcmd.c`), under the client
  program's numbers: `keynumtostring` (340, also 520 and 609), `stringtokeynum` (341,
  also 614), `getkeybind` (342), `findkeysforcommand` (521), `findkeysforcommandex`,
  `setkeybind` (630), `getbindmaps` (631) and `setbindmaps` (632).

  Keys are QuakeC key codes, turned into FTE's key numbers and back as FTE turns them
  (`QuakeServer.Keys`); the bindings are the console's (`QuakeServer.Console.Bindings`)
  in the host's console variable table. A binding set by a program is made at FTE's
  insecure level (30).
  """

  import Bitwise

  alias QuakeServer.Args
  alias QuakeServer.Console.Bindings
  alias QuakeServer.Cvars
  alias QuakeServer.Keys

  @altbindmap 8
  @insecure 30

  @doc "The builtins this module runs."
  @spec builtins() :: [integer() | String.t()]
  def builtins, do: [340, 341, 342, 520, 521, 609, 614, "findkeysforcommandex", 630, 631, 632]

  @doc "Run key builtin `builtin`, one of `builtins/0`."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, keynumtostring, _argc) when keynumtostring in [340, 520, 609],
    do: Args.return(s, Keys.keynum_to_string(Keys.from_qc(Args.int(s, 0)), 0))

  def call(s, stringtokeynum, _argc) when stringtokeynum in [341, 614] do
    case Keys.string_to_keynum(Args.str(s, 0)) do
      {keynum, :all} when keynum >= 0 -> Args.return(s, Keys.to_qc(keynum) / 1)
      _ -> Args.return(s, -1.0)
    end
  end

  def call(%{cvars: nil} = s, 342, _argc), do: Args.return(s, 0)

  def call(s, 342, argc) do
    bindmap = if argc > 1, do: Args.int(s, 1), else: 0
    modifier = if argc > 2, do: Args.int(s, 2), else: 0

    case Bindings.get(s.cvars, Keys.from_qc(Args.int(s, 0)), bindmap, modifier) do
      nil -> Args.return(s, 0)
      text -> Args.return(s, text)
    end
  end

  def call(s, 521, argc) do
    bindmap = if argc > 1, do: Args.int(s, 1), else: 0
    keys = s |> found(bindmap, 16) |> Enum.map(fn {keynum, _} -> Keys.to_qc(keynum) end)
    padded = keys ++ List.duplicate(-1, max(2 - length(keys), 0))
    Args.return(s, Enum.map_join(padded, &" '#{&1}'"))
  end

  def call(s, "findkeysforcommandex", argc) do
    bindmap = if argc > 1, do: Args.int(s, 1), else: 0

    text =
      s
      |> found(bindmap, 256)
      |> Enum.map_join(" ", fn {keynum, modifier} -> Keys.keynum_to_string(keynum, modifier) end)

    Args.return(s, text)
  end

  def call(%{cvars: nil} = s, 630, _argc), do: s

  def call(s, 630, argc) do
    bindmap = if argc > 2, do: Args.int(s, 2), else: 0
    modifier = if argc > 3, do: Args.int(s, 3), else: :all

    modifier =
      if bindmap > 0 and bindmap <= @altbindmap,
        do: bor(bindmap - 1, @altbindmap),
        else: state(modifier)

    Bindings.set(s.cvars, Keys.from_qc(Args.int(s, 0)), modifier, Args.str(s, 1), @insecure)
    s
  end

  def call(%{cvars: nil} = s, 631, _argc), do: Args.return(s, {0.0, 0.0, 0.0})

  def call(s, 631, _argc) do
    {first, second} = Cvars.bindmaps(s.cvars)
    Args.return(s, {shown_map(first), shown_map(second), 0.0})
  end

  def call(%{cvars: nil} = s, 632, _argc), do: Args.return(s, 1.0)

  def call(s, 632, _argc) do
    {first, second, _} = Args.vec(s, 0)
    Cvars.put_bindmaps(s.cvars, {chosen_map(first), chosen_map(second)})
    Args.return(s, 1.0)
  end

  defp found(%{cvars: nil}, _bindmap, _count), do: []
  defp found(s, bindmap, count), do: Bindings.find(s.cvars, bindmap, Args.str(s, 0), count)

  defp state(:all), do: :all
  defp state(-1), do: :all
  defp state(modifier), do: modifier

  defp shown_map(0), do: 0.0
  defp shown_map(map), do: (band(map, bnot(@altbindmap)) + 1) / 1

  defp chosen_map(value) do
    map = trunc(value)
    if map > 0 and map <= @altbindmap, do: bor(map - 1, @altbindmap), else: 0
  end
end
