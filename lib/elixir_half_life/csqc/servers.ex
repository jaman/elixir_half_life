defmodule ElixirHalfLife.Csqc.Servers do
  @moduledoc """
  The server browser builtins of FTE's client and menu programs (`pr_clcmd.c` over
  `net_master.c`), under the client program's numbers: `gethostcachevalue` (611),
  `gethostcachestring` (612), `resethostcachemasks` (615), `sethostcachemaskstring`
  (616), `sethostcachemasknumber` (617), `resorthostcache` (618), `sethostcachesort`
  (619), `refreshhostcache` (620), `gethostcachenumber` (621), `gethostcacheindexforkey`
  (622), `addwantedhostcachekey` (623) and `getextresponse` (624).

  No master server or network is queried, so the server list stays empty: the view and
  total counts are 0, a server's string key is empty and its number key -1. What the
  program sets is kept as FTE keeps it, in the host's `ext.hostcache`: the sort field
  and flags (`gethostcachevalue` 6 and 7 read them back), up to eight mask rules, and up
  to 64 custom key names, numbered from 279 in the order asked for. Key names are FTE's:
  `ping` 0, `map` 1, `name`/`hostname` 2, `address`/`cname` 3, `numplayers` 4,
  `maxplayers` 5, `gamedir`/`game`/`*gamedir` 6, `freeplayers`/`freeslots` 7, `basegame`
  8, `flags` 9, `mod` 12, `protocol` 13, `numbots` 14, `numspectators` 15, `numhumans` 16,
  `qcstatus` 17, `category` 18, `isfavorite` 19, `islocal` 20, `isproxy` 21,
  `serverinfo` 22, `playerN` 24 + N; past 64 custom keys, 23 (too many).
  """

  import Bitwise

  alias QuakeServer.Args

  @keys %{
    "map" => 1,
    "ping" => 0,
    "name" => 2,
    "hostname" => 2,
    "address" => 3,
    "cname" => 3,
    "maxplayers" => 5,
    "numplayers" => 4,
    "freeplayers" => 7,
    "freeslots" => 7,
    "gamedir" => 6,
    "game" => 6,
    "*gamedir" => 6,
    "basegame" => 8,
    "flags" => 9,
    "mod" => 12,
    "protocol" => 13,
    "numbots" => 14,
    "numhumans" => 16,
    "numspectators" => 15,
    "qcstatus" => 17,
    "isfavorite" => 19,
    "islocal" => 20,
    "isproxy" => 21,
    "category" => 18,
    "serverinfo" => 22
  }

  @too_many 23
  @player0 24
  @custom @player0 + 255
  @max_rules 8
  @max_keys 64

  @doc "The builtins this module runs."
  @spec builtins() :: [integer()]
  def builtins, do: [611, 612, 615, 616, 617, 618, 619, 620, 621, 622, 623, 624]

  @doc "Run server browser builtin `builtin`, one of `builtins/0`."
  @spec call(map(), integer(), non_neg_integer()) :: map()
  def call(s, 611, _argc) do
    cache = cache(s)

    value =
      case Args.int(s, 0) do
        6 -> cache.sortfield / 1
        7 -> band(cache.sortflags, 1) / 1
        _ -> 0.0
      end

    Args.return(s, value)
  end

  def call(s, 612, _argc), do: Args.return(s, "")
  def call(s, 615, _argc), do: update(s, &%{&1 | rules: []})
  def call(s, 616, _argc), do: rule(s, Args.str(s, 2))
  def call(s, 617, _argc), do: rule(s, Args.int(s, 2))
  def call(s, 618, _argc), do: s

  def call(s, 619, _argc),
    do: update(s, &%{&1 | sortfield: Args.int(s, 0), sortflags: Args.int(s, 1)})

  def call(s, 620, _argc), do: s
  def call(s, 621, _argc), do: Args.return(s, -1.0)

  def call(s, number, _argc) when number in [622, 623] do
    {s, key} = key_for(s, Args.str(s, 0))
    Args.return(s, key / 1)
  end

  def call(s, 624, _argc), do: Args.return(s, 0)

  defp rule(s, operand) do
    rule = %{
      or: band(Args.int(s, 0), 512) != 0,
      field: Args.int(s, 1),
      operand: operand,
      op: Args.int(s, 3)
    }

    update(s, fn cache ->
      if length(cache.rules) >= @max_rules,
        do: cache,
        else: %{cache | rules: cache.rules ++ [rule]}
    end)
  end

  defp key_for(s, name) do
    cond do
      Map.has_key?(@keys, name) ->
        {s, @keys[name]}

      String.starts_with?(name, "player") ->
        {s, @player0 + leading_integer(String.slice(name, 6..-1//1))}

      index = Enum.find_index(cache(s).keys, &(&1 == name)) ->
        {s, @custom + index}

      length(cache(s).keys) >= @max_keys ->
        {s, @too_many}

      true ->
        s = update(s, &%{&1 | keys: &1.keys ++ [name]})
        {s, @custom + length(cache(s).keys) - 1}
    end
  end

  defp cache(s),
    do: Map.get(s.ext, :hostcache, %{sortfield: 0, sortflags: 0, rules: [], keys: []})

  defp update(s, fun), do: %{s | ext: Map.put(s.ext, :hostcache, fun.(cache(s)))}

  defp leading_integer(text) do
    case Integer.parse(String.trim_leading(text)) do
      {number, _} -> number
      :error -> 0
    end
  end
end
