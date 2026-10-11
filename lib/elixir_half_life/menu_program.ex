defmodule ElixirHalfLife.MenuProgram do
  @moduledoc """
  FreeHL's menu program (`menu.dat`, FTE's menu QC) running on its own, started as FTE's
  `MP_Init` starts it.

      menu = ElixirHalfLife.MenuProgram.start()

  `start/1` sets the menu's `time` global, runs its `m_init` and then the console
  commands it queued. The menu's `time` global is the seconds since the menu started and
  `frametime` the time since the last drawing, as FTE sets them. Its builtins are FTE's
  menu builtins (`ElixirHalfLife.MenuProgram.Builtins`).

  A menu program error (a `QuakeC.Exec.Error`, such as an unimplemented builtin or
  `crash`) shuts the menu down, as FTE's `Menu_Abort` does: `m_shutdown` is not run, the
  reason is kept (`aborted/1`) and printed as `Menu_Abort: reason` and `Shutting down
  menu.dat`, and from then on the menu runs nothing and draws nothing over the screen. A
  menu without `m_drawloading` draws nothing over the screen either (black).
  """

  alias ElixirHalfLife.{Assets, ClientSource}
  alias QuakeServer.{Cvars, Events, Server}
  alias QuakeServer.Cvars.Engine

  @doc """
  The menu program, its memory belonging to the calling process, reading and setting
  console variables in `cvars` (a `QuakeServer.Cvars` table shared with the game; by
  default a table of its own with FTE's engine variables), started with its `m_init`.
  Its `autocvar_` globals follow the table (`QuakeServer.Autocvars`).
  """
  @spec start(QuakeServer.Cvars.t() | nil) :: Server.t()
  def start(cvars \\ nil) do
    now = System.monotonic_time(:microsecond)

    %Server{
      qc: QuakeC.new(Assets.menu()),
      cvars: cvars || Engine.register(Cvars.new()),
      map: "",
      source: ClientSource,
      builtins: ElixirHalfLife.MenuProgram.Builtins,
      budget: 50_000_000,
      coords: :float,
      slots: 0,
      ext: %{started: now, drawn: now, keydest: 0, absolute_mouse: true}
    }
    |> init()
  end

  @doc "Why the menu program was shut down, or `nil` while it runs."
  @spec aborted(Server.t()) :: String.t() | nil
  def aborted(%Server{ext: ext}), do: Map.get(ext, :aborted)

  defp init(menu) do
    qc = put_known(menu.qc, "time", 0.0)

    guarded(%{menu | qc: qc}, fn menu ->
      menu
      |> Server.call_named("m_init")
      |> QuakeServer.Console.flush()
    end)
  end

  defp guarded(menu, run) do
    run.(menu)
  rescue
    error in QuakeC.Exec.Error ->
      menu
      |> Events.print(:notify, "Menu_Abort: #{error.message}\nShutting down menu.dat\n")
      |> then(&%{&1 | ext: Map.put(&1.ext, :aborted, error.message)})
  end

  defp put_known(qc, name, value) do
    if QuakeC.global?(qc, name), do: QuakeC.put_declared(qc, name, value), else: qc
  end
end
