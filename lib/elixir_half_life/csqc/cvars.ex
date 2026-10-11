defmodule ElixirHalfLife.Csqc.Cvars do
  @moduledoc """
  The console variable builtins whose client and menu forms differ from the server's,
  as FTE's `pr_csqc.c` and `pr_menu.c` run them; the rest are the server's
  (`QuakeServer.Extensions.Settings`).

  The client program's `cvar` (45) gives the 2D screen's size for `vid_conwidth` and
  `vid_conheight` (`ElixirHalfLife.Csqc.Screen.virtual_size/1`) and any other variable's
  value as the server's `cvar` reads it.

  The menu's `localcmd` (13), `cvar` (14), `cvar_set` (15), `registercvar` (42),
  `cvar_string` (71) and `cvar_defstring` (89) take DarkPlaces names for FTE's
  (`vid_bitsperpixel` → `vid_bpp`, `_cl_playermodel` → `model`, `_cl_playerskin` →
  `skin`, `_cl_color` → `topcolor`, `_cl_name` → `name`, `v_hwgamma` →
  `vid_hardwaregamma`, `showfps` → `show_fps`, `sv_progs` → `progs`). Its `cvar` gives
  `vid_conwidth` and `vid_conheight` as the 2D size, `vid_pixwidth` and `vid_pixheight`
  as the screen's pixels, and a latched variable's latched value (the value the player
  chose); its `cvar_string` likewise.
  """

  alias ElixirHalfLife.Csqc.Screen
  alias QuakeServer.{Args, Cvars, Server}
  alias QuakeServer.Extensions.Settings

  @remaps %{
    "vid_bitsperpixel" => "vid_bpp",
    "_cl_playermodel" => "model",
    "_cl_playerskin" => "skin",
    "_cl_color" => "topcolor",
    "_cl_name" => "name",
    "v_contrast" => "v_contrast",
    "v_hwgamma" => "vid_hardwaregamma",
    "showfps" => "show_fps",
    "sv_progs" => "progs"
  }

  @doc "Run the client program's builtin `builtin` (45)."
  @spec call(map(), integer(), non_neg_integer()) :: map()
  def call(s, 45, argc) do
    case Args.str(s, 0) do
      "vid_conwidth" -> Args.return(s, size(s, :virtual, 0))
      "vid_conheight" -> Args.return(s, size(s, :virtual, 1))
      _name -> Settings.call(s, 45, argc)
    end
  end

  @doc "Run the menu's builtin `builtin`: 13, 14, 15, 42, 71 or 89."
  @spec menu_call(map(), integer(), non_neg_integer()) :: map()
  def menu_call(s, 13, argc), do: QuakeServer.Extensions.call(s, 46, argc)

  def menu_call(s, 14, _argc) do
    case Args.str(s, 0) do
      "vid_conwidth" -> Args.return(s, size(s, :virtual, 0))
      "vid_conheight" -> Args.return(s, size(s, :virtual, 1))
      "vid_pixwidth" -> Args.return(s, size(s, :pixels, 0))
      "vid_pixheight" -> Args.return(s, size(s, :pixels, 1))
      name -> Args.return(s, menu_value(Settings.readable(s, remap(name))))
    end
  end

  def menu_call(s, 15, _argc) do
    name = remap(Args.str(s, 0))

    case Settings.readable(s, name) || Cvars.fetch(s.cvars, name) do
      nil ->
        s

      cvar ->
        if Cvars.flag?(cvar, :notfromserver),
          do: s,
          else: Server.put_cvar(s, name, Args.str(s, 1))
    end
  end

  def menu_call(s, 42, argc), do: Settings.call(s, 93, argc)

  def menu_call(s, 71, _argc) do
    case Settings.readable(s, remap(Args.str(s, 0))) do
      nil -> Args.return(s, 0)
      cvar -> Args.return(s, cvar.latched || cvar.string)
    end
  end

  def menu_call(s, 89, argc), do: Settings.call(s, 482, argc)

  defp menu_value(nil), do: 0.0
  defp menu_value(%{latched: nil, value: value}), do: value
  defp menu_value(%{latched: latched}), do: Cvars.c_atof(latched)

  defp size(s, :virtual, index) do
    case Screen.virtual_size(s) do
      nil -> 0.0
      virtual -> elem(virtual, index) / 1
    end
  end

  defp size(s, :pixels, index) do
    case Map.get(s.ext, :screen) do
      %{width: width, height: height} -> elem({width, height}, index) / 1
      _ -> 0.0
    end
  end

  defp remap(name), do: Map.get(@remaps, String.downcase(name, :ascii), name)
end
