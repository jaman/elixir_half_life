defmodule ElixirHalfLife.Host do
  @moduledoc """
  FTE's host starting up for Half-Life: the one console variable table a game's server,
  client program and menu share, with FTE's engine variables registered
  (`QuakeServer.Cvars.Engine`) and the startup configs run as FTE's
  `CL_ExecInitialConfigs` runs them, before any level starts.

      cvars = ElixirHalfLife.Host.start()
      {:ok, runner} = QuakeServer.Runner.start_link(map: "c1a0", server: [cvar_table: cvars, ...])

  The table belongs to the calling process. Its home directory, where `cfg_save` writes
  and `exec` looks first, is `:home` (default
  `Cauldron2D.Paths.data(:elixir_half_life, ["fte"])`). The game files must have been
  loaded (`ElixirHalfLife.Assets.load/2`).

  Before them the game is chosen as FTE's `FS_ChangeGame` chooses it
  (`ElixirHalfLife.GameDirs.current/0`): `com_fullgamename` and `com_protocolname` take
  the game's name as value and engine default, `fs_game` its directory, `fs_gamepath`
  that directory's path and `fs_basepath` and `fs_homepath` the base directory's.

  The startup commands, in FTE's order: `unbindall`, `showpic_removeall`, the aliases
  `restart_ents`, `restart`, `startmap_sp`, `+attack2` and `-attack2`, `cl_warncmd 0`,
  `cvar_purgedefaults`, `cvarreset *`, `sv_gamedir valve`, `plug_load ffmpeg` (the
  Half-Life game's own command), `register_bestweapon reset`; then the configs chosen by
  where they are found (`ElixirHalfLife.Assets.depth/1`): `exec quake.rc` when it is
  found no later than `default.cfg` and `hexen.rc`, else `exec hexen.rc` when that is
  found no later than `default.cfg`, else `exec default.cfg`, `exec q3config.cfg` (when
  found no later than `default.cfg`) or `exec config.cfg`, and `exec autoexec.cfg` when
  there is a `default.cfg`; then `cl_warncmd 1`. The `exec` rules of
  `QuakeServer.Console.Configs` apply (`config.cfg` superseded by an earlier
  `default.cfg`, `fte.cfg` after it, `cvar_lockdefaults` after `default.cfg`). The
  archived variables are then marked saved, and the renderer as running, so renderer
  and video variables latch from then on.

  Commands this port has no engine part for (pictures, plugins, weapon lists, the game
  directory) are not known to the console; `cl_warncmd 0` keeps them quiet, as in FTE.
  Key bindings are the console's (`QuakeServer.Console.Bindings`). Everything the commands
  print is returned with the table.
  """

  alias ElixirHalfLife.GameDirs
  alias QuakeServer.Console
  alias QuakeServer.Console.Configs
  alias QuakeServer.{Cvars, Server}
  alias QuakeServer.Cvars.Engine

  @missing 0x7FFFFFFF

  @doc "Start the host: the shared console variable table, with the startup configs run."
  @spec start(keyword()) :: Cvars.t()
  def start(opts \\ []), do: opts |> boot() |> elem(0)

  @doc "As `start/1`, also returning the lines the startup commands printed, in order."
  @spec boot(keyword()) :: {Cvars.t(), [String.t()]}
  def boot(opts \\ []) do
    cvars = Engine.register(Cvars.new())

    Cvars.put_home(
      cvars,
      Keyword.get_lazy(opts, :home, fn -> Cauldron2D.Paths.data(:elixir_half_life, ["fte"]) end)
    )

    change_game(cvars)
    console = %Server{cvars: cvars, source: ElixirHalfLife.Source, map: "", ext: %{}}
    console = Console.run(console, startup(console))
    Cvars.saved(cvars)
    Cvars.put_running(cvars, :renderer, true)
    {events, _console} = Server.drain(console)
    {cvars, for({:print, _where, line} <- events, do: line)}
  end

  @doc """
  Run console commands `text` against `cvars` outside any program, as typed at FTE's
  console with no level running; returns the lines printed.
  """
  @spec run(Cvars.t(), String.t()) :: [String.t()]
  def run(%Cvars{} = cvars, text) do
    console = %Server{cvars: cvars, source: ElixirHalfLife.Source, map: "", ext: %{}}
    {events, _console} = console |> Console.run(text) |> Server.drain()
    for {:print, _where, line} <- events, do: line
  end

  defp change_game(cvars) do
    game = GameDirs.current()
    base = (GameDirs.base_dir() || "") <> "/"

    for name <- ["com_fullgamename", "com_protocolname"] do
      value =
        if name == "com_fullgamename", do: game.description, else: game.manifest.protocolname

      Cvars.put_engine_default(cvars, name, value)
      Cvars.set(cvars, name, value, force: true)
    end

    Cvars.set(cvars, "fs_game", game.gamedir, force: true)
    Cvars.set(cvars, "fs_gamepath", base <> game.gamedir, force: true)
    Cvars.set(cvars, "fs_basepath", base, force: true)
    Cvars.set(cvars, "fs_homepath", base, force: true)
  end

  defp startup(console) do
    Enum.join(
      [
        "unbindall",
        "showpic_removeall",
        "alias restart_ents \"changelevel . .\"",
        "alias restart map_restart",
        "alias startmap_sp \"map start\"",
        "alias +attack2 +button3",
        "alias -attack2 -button3",
        "cl_warncmd 0",
        "cvar_purgedefaults",
        "cvarreset *",
        "sv_gamedir \"valve\"",
        "plug_load ffmpeg",
        "register_bestweapon reset"
      ] ++ configs(console) ++ ["cl_warncmd 1"],
      "\n"
    )
  end

  defp configs(console) do
    defaults = Configs.depth(console, "default.cfg")
    quake = Configs.depth(console, "quake.rc")
    hexen = Configs.depth(console, "hexen.rc")

    cond do
      quake <= defaults and quake <= hexen and quake != @missing ->
        ["exec quake.rc"]

      hexen <= defaults and hexen != @missing ->
        ["exec hexen.rc"]

      true ->
        default_configs(console, defaults)
    end
  end

  defp default_configs(console, defaults) do
    q3 = Configs.depth(console, "q3config.cfg")

    config =
      if q3 <= defaults and q3 != @missing, do: "exec q3config.cfg", else: "exec config.cfg"

    autoexec = if defaults != @missing, do: ["exec autoexec.cfg"], else: []
    ["exec default.cfg", config] ++ autoexec
  end
end
