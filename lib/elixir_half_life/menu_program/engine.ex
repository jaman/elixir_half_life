defmodule ElixirHalfLife.MenuProgram.Engine do
  @moduledoc """
  The menu program's own builtins about the engine around it (FTE's `pr_menu.c`), by
  name:

    * `checkextension` — whether FTE lists the extension, ignoring case
      (`QuakeServer.Extensions.Settings.extension?/1`)
    * `objerror` — prints `======OBJECT ERROR======` and the joined arguments, and
      removes `self` (not the world) unless `developer` is set
    * `bprint`, `msprint` — print to every player, or to player number `n` (from 0),
      through the host's `ext.server_print` (a function of `:all` or the player number
      and the text) while a server runs; nothing otherwise
    * `cprint` — the joined arguments in the middle of the screen, as a
      `{:print, :center, text}` event
    * `isserver` — 0.5 while a server runs in the host's console variable table (one
      player slot), else 0; `clientcount` — 1 while a server runs, else 0;
      `clientstate` — 2 while a server runs (connected), else 1 (disconnected)
    * `crash` — stops the menu program with an error; `stackdump` — nothing to print,
      as the menu program keeps no QuakeC call stack
    * `changelevel` — queues `changelevel "map"` on the menu's console
    * `localsound(name, channel, volume)` — a `{:sound, sound}` event, the sound heard
      everywhere at full volume unless given
    * `getmousepos` — the cursor position while the mouse is absolute for the menu
      (`ext.absolute_mouse`, true unless `setmousetarget` 1 made it relative), else the
      movement since the last call (`ext.mouse_delta`, then cleared)
    * `setkeydest(dest)` — 2 gives the keyboard to the menu, 0 takes it away
      (`ext.keydest`); another value is a program error; `getkeydest` — 2 while the
      menu has the keyboard, else 0
    * `registercommand(name)` — makes console command `name` run the menu's
      `m_consolecommand` (`ext.commands`)
    * `clipboard_get(kind)` — hands each character of the host's clipboard of that kind
      (`ext.clipboard`) to `Menu_InputEvent` as a paste event (8)
    * the `crypto_` builtins — null or 0: no keys or identities are kept
  """

  alias ElixirHalfLife.Csqc.Client
  alias QuakeC.Exec
  alias QuakeServer.{Args, Edicts, Events, Server}
  alias QuakeServer.Extensions.Settings

  @doc "The builtins this module runs, by name."
  @spec builtins() :: [String.t()]
  def builtins,
    do: ~w(checkextension objerror bprint msprint cprint isserver clientcount clientstate
      crash stackdump changelevel localsound getmousepos setkeydest getkeydest
      registercommand clipboard_get crypto_getkeyfp crypto_getidfp crypto_getencryptlevel
      crypto_getmykeyfp crypto_getmyidfp crypto_getmyidstatus crypto_getidstatus)

  @doc "Run menu builtin `name`, one of `builtins/0`."
  @spec call(map(), String.t(), non_neg_integer()) :: map()
  def call(s, "checkextension", _argc), do: Args.return(s, Settings.extension?(Args.str(s, 0)))

  def call(s, "objerror", argc) do
    self = Args.self(s)
    s = Events.print(s, :notify, "======OBJECT ERROR======\n#{joined(s, 0, argc)}\n")

    if self != 0 and Server.cvar(s, "developer") == 0,
      do: Edicts.free(s, self),
      else: s
  end

  def call(s, "bprint", argc), do: server_print(s, :all, joined(s, 0, argc))
  def call(s, "msprint", argc), do: server_print(s, Args.int(s, 0), joined(s, 1, argc))
  def call(s, "cprint", argc), do: Events.print(s, :center, joined(s, 0, argc))
  def call(s, "isserver", argc), do: Client.call(s, 350, argc)

  def call(s, "clientcount", _argc),
    do: Args.return(s, if(Client.server_running?(s), do: 1.0, else: 0.0))

  def call(s, "clientstate", _argc),
    do: Args.return(s, if(Client.server_running?(s), do: 2.0, else: 1.0))

  def call(_s, "crash", _argc), do: raise(Exec.Error, "\ncrash called")
  def call(s, "stackdump", _argc), do: s

  def call(s, "changelevel", _argc),
    do: %{s | console: s.console ++ ["changelevel \"#{Args.str(s, 0)}\""]}

  def call(s, "localsound", argc) do
    Server.emit(
      s,
      {:sound,
       %{
         entity: 0,
         channel: trunc(Args.num(s, 1, argc, 0.0)),
         name: Args.str(s, 0),
         volume: Args.num(s, 2, argc, 1.0),
         attenuation: 0.0,
         origin: {0.0, 0.0, 0.0},
         pitch: 100.0
       }}
    )
  end

  def call(s, "getmousepos", _argc) do
    if Map.get(s.ext, :absolute_mouse, true) do
      {x, y} = Map.get(s.ext, :mouse, {0.0, 0.0})
      Args.return(s, {x / 1, y / 1, 0.0})
    else
      {x, y} = Map.get(s.ext, :mouse_delta, {0.0, 0.0})
      %{s | ext: Map.put(s.ext, :mouse_delta, {0.0, 0.0})} |> Args.return({x / 1, y / 1, 0.0})
    end
  end

  def call(s, "setkeydest", _argc) do
    case Args.int(s, 0) do
      0 -> %{s | ext: Map.put(s.ext, :keydest, 0)}
      2 -> %{s | ext: Map.put(s.ext, :keydest, 2)}
      dest -> raise Exec.Error, "PF_setkeydest: wrong destination #{dest} !"
    end
  end

  def call(s, "getkeydest", _argc), do: Args.return(s, Map.get(s.ext, :keydest, 0) / 1)

  def call(s, "registercommand", _argc) do
    name = Args.str(s, 0)
    %{s | ext: Map.update(s.ext, :commands, MapSet.new([name]), &MapSet.put(&1, name))}
  end

  def call(s, "crypto_" <> _, _argc), do: Args.return(s, 0)

  def call(s, "clipboard_get", _argc) do
    text = s.ext |> Map.get(:clipboard, %{}) |> Map.get(Args.int(s, 0), "")
    text |> String.codepoints() |> Enum.reduce(s, &paste/2)
  end

  defp paste(char, s) do
    case QuakeC.Progs.function(s.qc.progs, "Menu_InputEvent") do
      nil ->
        s

      function ->
        <<code::utf8>> = char

        qc =
          s.qc
          |> QuakeC.put_slot(4, 8.0)
          |> QuakeC.put_slot(7, 0.0)
          |> QuakeC.put_slot(10, code / 1)
          |> QuakeC.put_slot(13, 0.0)

        Exec.call(%{s | qc: qc}, function, s.builtins, Server.exec_opts(s))
    end
  end

  defp server_print(s, target, text) do
    case Map.get(s.ext, :server_print) do
      print when is_function(print, 2) ->
        if Client.server_running?(s), do: print.(target, text)
        s

      _ ->
        s
    end
  end

  defp joined(s, from, argc), do: Enum.map_join(from..(argc - 1)//1, &Args.str(s, &1))
end
