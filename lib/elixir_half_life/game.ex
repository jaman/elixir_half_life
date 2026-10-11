defmodule ElixirHalfLife.Game do
  @moduledoc """
  Half-Life as a `Cauldron2D.Game`, single player. When the player joins, FreeHL's server
  program starts in a `QuakeServer.Runner` of its own, on its own clock, and its client
  program in an `ElixirHalfLife.ClientProgram` that takes the world from it. Each tick
  the held actions become the client program's input (`ElixirHalfLife.Movement`, FTE's
  keyboard and mouse movement), which each client frame turns through the program's
  input hook and hands to the runner; the client program's sound events since
  (`Cauldron2D.Audio` keyed events) are handed on, and view angles the server set are
  taken up.

      Cauldron2D.World.start_link(game: ElixirHalfLife.Game, game_opts: [map: "c0a0", skill: 1], hz: 20)

  Options: `:map` (default `"c0a0"`), `:skill` (1 to 3, default 1), `:picture_width`
  (the most pixels across the client program draws when the player's options give none,
  default 480) and `:cvars` (`ElixirHalfLife.Movement`'s console variables over its
  defaults) and `:setpos` (`"x y z"` or `"x y z pitch yaw roll"`: once the player is in
  the first level, the server's `setpos` puts them there, in noclip). Game files must
  have been loaded with `ElixirHalfLife.Assets.load/2`.

  Joining starts FTE's host (`ElixirHalfLife.Host`): one console variable table, with
  the startup configs run, that the server, the client program and the menu share, as
  FTE's single process has one; then `set skill <skill>; maxplayers 1`, the commands
  FreeHL's menu runs for a new game. The client program, and with it FreeHL's menu
  program and its `m_init`, starts before the level loads, as FTE starts its menu before
  any map. Leaving frees it.

  The player's options (`ElixirHalfLife.Options`) come with the join's props as
  `:options` and with each input after; whenever they change they are put into effect:
  the client program's console variables (`ElixirHalfLife.ClientProgram.configure/2`),
  the server's (`QuakeServer.Runner.console/2`), the picture's width and the mouse
  settings movement reads.

  The actions read are those `ElixirHalfLife.Movement` reads, and `:fire`, `:alt_fire`,
  `:jump`, `:crouch`, `:use`, `:reload` (the command's buttons), `:flashlight`
  (impulse 100), `:next_weapon`, `:prev_weapon`, `:last_weapon` and `:weapon_1` to
  `:weapon_6` (the console commands `invnext`, `invprev`, `lastinv` and `slot1` to
  `slot6`), `:screenshot` (`ElixirHalfLife.ClientProgram.screenshot/1`) and `:where`
  (the server's `setpos` with no position; the line it prints is added, after the map's
  name, to `positions.txt` under `Cauldron2D.Paths.data(:elixir_half_life, [])`); a stick's
  `strength` scales moving, turning and looking.
  """

  @behaviour Cauldron2D.Game

  import Bitwise

  alias ElixirHalfLife.{Assets, ClientProgram, Host, Movement, Options}
  alias QuakeServer.{Cvars, Runner}

  @buttons [fire: 1, jump: 2, reload: 8, use: 16, alt_fire: 32, crouch: 128]
  @commands [next_weapon: "invnext", prev_weapon: "invprev", last_weapon: "lastinv"] ++
              for(n <- 1..6, do: {:"weapon_#{n}", "slot#{n}"})

  @impl true
  def init(opts) do
    %{
      map: Keyword.get(opts, :map, "c0a0"),
      skill: Keyword.get(opts, :skill, 1),
      runner: nil,
      program: nil,
      client_sounds: nil,
      shared: nil,
      handoff: nil,
      options: Options.complete(%{picture_width: Keyword.get(opts, :picture_width, 480)}),
      look: Movement.new(Keyword.get(opts, :cvars, %{})),
      motion: %{onground: false, velocity: {0.0, 0.0, 0.0}},
      angles: {0.0, 0.0, 0.0},
      input: %{held: MapSet.new()},
      previous: MapSet.new(),
      walking: false,
      setpos: Keyword.get(opts, :setpos),
      where: false,
      time: 0.0,
      events: [],
      listener: {0.0, 0.0, 0.0},
      joined: nil,
      over: nil,
      cvars: nil
    }
  end

  @impl true
  def join(state, id, props) do
    options = Map.merge(state.options, Map.get(props, :options) || %{})
    cvars = Host.start()
    Host.run(cvars, "set skill #{state.skill}; maxplayers 1")

    {:ok, runner} =
      Runner.start_link(map: state.map, held: true, server: server_options(state.skill, cvars))

    {:ok, program} =
      ClientProgram.start_link(
        runner: runner,
        width: Options.complete(options).picture_width,
        cvars: cvars
      )

    state = %{
      state
      | joined: id,
        cvars: cvars,
        program: program,
        runner: runner,
        options: Options.complete(options),
        handoff: Runner.handoff(runner),
        client_sounds: ClientProgram.sounds(program),
        shared: ClientProgram.shared(program)
    }

    Runner.load(runner)
    {:ok, put_options(state)}
  end

  @impl true
  def leave(state, _id) do
    if state.runner, do: GenServer.stop(state.runner)
    if state.program, do: GenServer.stop(state.program)
    if state.cvars, do: Cvars.delete(state.cvars)
    %{state | joined: nil, program: nil, runner: nil, cvars: nil}
  end

  @impl true
  def handle_input(state, _id, input),
    do: %{state | input: input} |> take_options(Map.get(input, :options))

  @impl true
  def step(%{program: nil} = state, _dt), do: state

  def step(%{over: reason} = state, _dt) when is_binary(reason), do: state

  def step(state, dt) do
    case Runner.take(state.handoff) do
      %{ended: reason} when is_binary(reason) -> %{state | over: reason}
      taken -> play(state, taken, dt)
    end
  end

  defp play(state, taken, dt) do
    state = if pressed?(state, :walk), do: %{state | walking: not state.walking}, else: state
    motion = Map.take(taken, [:onground, :velocity])

    state =
      %{state | listener: taken.listener, motion: motion}
      |> face(taken.setangle)
      |> place_start(taken)
      |> note_positions(taken)

    {angles, moves, look} =
      Movement.step(
        state.look,
        movement_input(state),
        state.angles,
        mouse(state),
        state.motion,
        dt
      )

    consoles(state)
    if pressed?(state, :screenshot), do: ClientProgram.screenshot(state.program)
    state = if pressed?(state, :where), do: ask_position(state), else: state
    ClientProgram.input(state.program, command(state, angles, moves, dt))

    sounds = ClientProgram.take_sounds(state.client_sounds)

    %{
      state
      | angles: angles,
        look: look,
        time: state.time + dt,
        previous: held(state),
        events: Enum.reverse(sounds, state.events)
    }
  end

  @impl true
  def view(state, _id),
    do: %{
      program: state.program,
      time: state.time,
      over: state.over,
      listener: state.listener,
      picture_width: state.options.picture_width
    }

  @impl true
  def drain_events(state), do: {Enum.reverse(state.events), %{state | events: []}}

  defp server_options(skill, cvars) do
    [
      source: ElixirHalfLife.Source,
      skill: skill,
      hull: &Assets.hull/2,
      inhibit: fn _, _ -> false end,
      budget: 50_000_000,
      builtins: QuakeServer.Extensions,
      coords: :float,
      cvar_table: cvars
    ]
  end

  defp take_options(state, nil), do: state

  defp take_options(state, options) do
    options = Options.complete(options)

    cond do
      options == state.options -> state
      state.program == nil -> %{state | options: options}
      true -> put_options(%{state | options: options}, state.options)
    end
  end

  defp put_options(state) do
    ClientProgram.configure(state.program, Options.client_commands(state.options))
    Runner.console(state.runner, Options.server_commands(state.options))
    state
  end

  defp put_options(state, before) do
    if before.picture_width != state.options.picture_width,
      do: ClientProgram.width(state.program, state.options.picture_width)

    if Options.client_commands(before) != Options.client_commands(state.options),
      do: ClientProgram.configure(state.program, Options.client_commands(state.options))

    if Options.server_commands(before) != Options.server_commands(state.options),
      do: Runner.console(state.runner, Options.server_commands(state.options))

    state
  end

  defp mouse(state),
    do:
      Map.put(Options.mouse(state.options), :scale, ClientProgram.sensitivity_scale(state.shared))

  defp movement_input(state),
    do: %{
      held: walking(held(state), state.walking),
      strength: Map.get(state.input, :strength, %{}),
      previous: walking(state.previous, state.walking)
    }

  defp place_start(%{setpos: nil} = state, _taken), do: state
  defp place_start(state, %{map: nil}), do: state
  defp place_start(state, %{listener: listener}) when listener == {0.0, 0.0, 0.0}, do: state

  defp place_start(state, _taken) do
    Runner.console(state.runner, "setpos " <> state.setpos)
    %{state | setpos: nil}
  end

  defp ask_position(state) do
    Runner.console(state.runner, "setpos")
    %{state | where: true}
  end

  defp note_positions(%{where: false} = state, _taken), do: state

  defp note_positions(state, taken) do
    case Enum.find(taken.events, &match?({:print, _, "setpos " <> _}, &1)) do
      nil ->
        state

      {:print, _, line} ->
        directory = Cauldron2D.Paths.data(:elixir_half_life, [])
        File.mkdir_p!(directory)
        File.write!(Path.join(directory, "positions.txt"), "#{taken.map} #{line}", [:append])
        %{state | where: false}
    end
  end

  defp walking(actions, true), do: MapSet.put(actions, :walk)
  defp walking(actions, false), do: MapSet.delete(actions, :walk)

  defp face(state, nil), do: state

  defp face(%{angles: {pitch, _, roll}} = state, {:turn, yaw}),
    do: %{state | angles: {pitch, yaw, roll}}

  defp face(state, {pitch, yaw, _}), do: %{state | angles: {pitch, yaw, 0.0}}

  defp held(state), do: Map.get(state.input, :held, MapSet.new())

  defp pressed?(state, action),
    do: MapSet.member?(held(state), action) and not MapSet.member?(state.previous, action)

  defp command(state, angles, {forward, side, up}, dt) do
    buttons =
      Enum.reduce(@buttons, 0, fn {action, bit}, acc ->
        if MapSet.member?(held(state), action), do: acc ||| bit, else: acc
      end)

    %{
      forward: forward,
      side: side,
      up: up,
      angles: angles,
      buttons: buttons,
      impulse: if(pressed?(state, :flashlight), do: 100, else: 0),
      timelength: dt
    }
  end

  defp consoles(state) do
    for {action, text} <- @commands,
        pressed?(state, action),
        do: ClientProgram.console(state.program, text)
  end
end
