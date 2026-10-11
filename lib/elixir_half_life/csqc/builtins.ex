defmodule ElixirHalfLife.Csqc.Builtins do
  @moduledoc """
  The builtins of FTE's client program: the client's own (messages, the scene, the
  screen, input, keys, sound, the client and engine around it, the server browser,
  sub-consoles and video) and the rest as the server's (`QuakeServer.Extensions`).
  """

  alias ElixirHalfLife.Csqc.{
    Client,
    Consoles,
    Cvars,
    Input,
    Keys,
    Media,
    Messages,
    Scene,
    Screen,
    Servers,
    Sounds
  }

  @families [
    {Cvars, [45]},
    {Sounds, [8, 483, 533, "stopsound", "soundupdate", "getchannellevel"]},
    {Messages, [360, 361, 362, 363, 364, 365, 366, 367, 368, "readint"]},
    {Screen,
     [
       315,
       316,
       319,
       320,
       321,
       356,
       317,
       318,
       322,
       323,
       324,
       325,
       326,
       327,
       328,
       357,
       "drawtextfield",
       "drawrotpic",
       "drawrotsubpic",
       "spriteframe"
     ]},
    {Scene,
     [
       69,
       310,
       336,
       337,
       238,
       300,
       301,
       302,
       303,
       304,
       305,
       306,
       307,
       308,
       309,
       311,
       333,
       355,
       359,
       373,
       374,
       375,
       376,
       377,
       378,
       "addentity_lighting",
       "removeentity",
       "R_EndPolygonRibbon",
       "dynamiclight_spawnstatic",
       "remapshader"
     ]},
    {Keys, Keys.builtins()},
    {Client, Client.builtins()},
    {Servers, Servers.builtins()},
    {Consoles, Consoles.builtins()},
    {Media, Media.builtins()},
    {Input,
     [
       343,
       344,
       345,
       346,
       348,
       351,
       534,
       "getcursormode",
       "setmousepos",
       "getplayerkeyfloat",
       "getplayerkeyblob",
       "setup_reverb",
       "soundnameforindex",
       "r_uploadimage",
       "r_readimage"
     ]}
  ]

  @table for {module, builtins} <- @families,
             builtin <- builtins,
             into: %{},
             do: {builtin, module}

  @doc "Whether `builtin` is one this module runs, its own or the server's."
  @spec known?(integer() | String.t() | nil) :: boolean()
  def known?(builtin), do: Map.has_key?(@table, builtin) or QuakeServer.Extensions.known?(builtin)

  @doc "Run builtin `builtin`, a number or a name, with `argc` arguments."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(host, builtin, argc) do
    case Map.get(@table, builtin) do
      nil -> QuakeServer.Extensions.call(host, builtin, argc)
      module -> module.call(host, builtin, argc)
    end
  end
end
