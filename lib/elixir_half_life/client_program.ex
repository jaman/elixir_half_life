defmodule ElixirHalfLife.ClientProgram do
  @moduledoc """
  The process that runs FreeHL's client program (`ElixirHalfLife.Csqc`) for one player,
  one client frame per picture, as FTE's client runs. It subscribes to the level's
  `QuakeServer.Runner` and reads each packet as it arrives; a picture never waits on the
  runner or on a level's program starting.

  Each level is joined as FTE's client joins one. On the runner's
  `{QuakeServer.Runner, {:changing, map}}` (FTE's `changing`) every sound channel
  stops. On its `{QuakeServer.Runner, {:serverdata, serverdata}}` (`svc_serverdata`)
  the level's program before, if any, is shut down (`CSQC_Shutdown`, its channels
  stopped, its memory released) and the new level's is started from the serverdata
  (`ElixirHalfLife.Csqc.start/2`: its map and name, the server's model and sound lists
  and info keys); once it has started, the signon messages are read
  (`ElixirHalfLife.Csqc.Parse`), the runner is told to begin the player
  (`QuakeServer.Runner.begin/3`, as a client running a client program), and the packets
  of the level that came meanwhile are read in order. Packets of another level are
  dropped. While a level loads the picture is the loading picture
  (`ElixirHalfLife.LoadingScreen`), from the moment a level change begins until the new
  level's program has started and the first packet of the level has arrived, and for 60
  seconds at most: when the change begins (at start, or on the runner's
  `{QuakeServer.Runner, {:changing, map}}`, FTE's `changing` command) one picture is
  drawn, the last game picture rendered (black before any) with "LOADING..." over it, and
  kept until the level is running.
  Each frame gathers the player's latest input into the command being built and, when
  `ElixirHalfLife.CommandClock` says it is time, sends it as FTE's `CL_SendCmd` does;
  then draws, at whatever size is asked: drawn at most `:width` pixels across (keeping
  the shape) and scaled up to the size asked. Console commands run in the program as
  they arrive.

  Commands are numbered as FTE numbers them (`cl.movesequence`), from 1 when the client
  starts, counting on from level to level; the first two carry no buttons. Sending
  command `n` runs the program's `CSQC_Input_Frame` with `clientcommandframe` `n` and the
  `input_` globals the command's (`input_sequence` `n`), reads the command back from
  them, keeps it with the time it was sent among the last 64 sent, and hands it to the
  runner with its number and its whole milliseconds; the command being gathered is then
  `n + 1`. The runner acknowledges the last command it ran in each packet, read as
  `servercommandframe` (`ElixirHalfLife.Csqc.put_command_frames/1`), and the program's
  `getinputstate` gives the kept commands and the one being gathered
  (`ElixirHalfLife.Csqc.Input.input_frame/2`), so a program predicting the player
  replays the commands the server has not acknowledged yet.

      {:ok, runner} = QuakeServer.Runner.start_link(map: "c1a0", server: options)
      {:ok, program} = ElixirHalfLife.ClientProgram.start_link(runner: runner, width: 480)
      ElixirHalfLife.ClientProgram.input(program, command)
      rgba = ElixirHalfLife.ClientProgram.picture(program, {320, 200}, 1.0)

  Input is a command as the server takes it (`QuakeServer.Physics.Command`); giving it
  does not wait. An impulse is kept until a command has sent it.

  The client's sound channels (`ElixirHalfLife.Csqc.Sounds`) take the server's sounds and
  the program's own; after each frame the listener is put at the view's origin and
  angles as the player's entity, and the channel commands are kept in a table
  (`sounds/1`) that `take_sounds/1` empties without waiting on the program, as
  `Cauldron2D.Audio` keyed events: each channel is a key, its sound named
  `{:sample, name, rate}` (`{:sample, name, rate, :s8}` while the console variable
  `loadas8bit` is set, the sound to be played cut to 8 bits, as FTE loads it) and
  placed by `{:level, gain, pan}`.

  Every picture, the loading screen too, goes through FTE's gamma ramp
  (`ElixirHalfLife.Gamma`) for the program's console variables `gamma`, `contrast` and
  `brightness` once drawn, after any overlay `picture/4` is given. Console commands
  given to `configure/2` are run again in each level's program as it starts, so the
  console variables they set last from level to level. `width/2` changes how many
  pixels across the picture is drawn with; `screenshot/1` writes the last one drawn.
  The program's sensitivity scaler is shared in a table (`shared/1`) read without
  waiting on the program.

  When a level's serverdata arrives, and when the client disconnects, every console
  variable the server took over goes back to the value it had before
  (`QuakeServer.Cvars.apply_latches/3` with `:serveroverride`, the flag cleared), as
  FTE's `CL_ClearState` and `CL_Disconnect` release them.

  When the runner ends the server (`{QuakeServer.Runner, {:ended, reason}}`) the client
  disconnects as FTE's `CL_Disconnect` does: the server's console variables are
  released, every sound channel is stopped, the
  program's `CSQC_Shutdown` runs and its memory is released, and from then on each
  picture is black (with any overlay) and nothing more is read from the runner.
  """

  use GenServer

  alias Cauldron2D.Audio
  alias Cauldron3D.Bsp.Surfaces
  alias ElixirHalfLife.{CommandClock, Csqc, Gamma, LoadingScreen, MenuProgram}
  alias ElixirHalfLife.Csqc.{Input, Parse, Scene, Sounds, VirtualSize}
  alias QuakeServer.{Models, Runner, Server}

  @player 1

  @doc """
  Start the client program for runner `:runner`, drawing at most `:width` pixels across
  (default 480). `:cvars` is the `QuakeServer.Cvars` table the client program and the
  menu read and set console variables in, the one the runner's server uses; without it
  each program has a table of its own.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Use `command` as the player's input from the next frame on."
  @spec input(pid(), map()) :: :ok
  def input(pid, command), do: GenServer.cast(pid, {:input, command})

  @doc "The table the program's sounds are kept in, for `take_sounds/1`."
  @spec sounds(pid()) :: :ets.tid()
  def sounds(pid), do: GenServer.call(pid, :sounds, :infinity)

  @doc "The sounds kept in `table` since the last take, oldest first; the table is left empty."
  @spec take_sounds(:ets.tid()) :: [term()]
  def take_sounds(table) do
    taken = :ets.tab2list(table)
    Enum.each(taken, fn {key, _sound} -> :ets.delete(table, key) end)
    Enum.map(taken, &elem(&1, 1))
  end

  @doc "Run console command `text` in the client program."
  @spec console(pid(), String.t()) :: :ok
  def console(pid, text), do: GenServer.cast(pid, {:console, text})

  @doc "Run console commands `text` in the client program now and in every level's program started after, as FTE keeps console variables from level to level."
  @spec configure(pid(), String.t()) :: :ok
  def configure(pid, text), do: GenServer.cast(pid, {:configure, text})

  @doc "Draw at most `width` pixels across from the next picture on."
  @spec width(pid(), pos_integer()) :: :ok
  def width(pid, width), do: GenServer.cast(pid, {:width, width})

  @doc "Write the last picture drawn, at the size it was drawn, as a PNG under `Cauldron2D.Paths.data(:elixir_half_life, \"screenshots\")`."
  @spec screenshot(pid()) :: :ok
  def screenshot(pid), do: GenServer.cast(pid, :screenshot)

  @doc "The table the program shares what it reads each frame in, for `sensitivity_scale/1`."
  @spec shared(pid()) :: :ets.tid()
  def shared(pid), do: GenServer.call(pid, :shared, :infinity)

  @doc "The client program's mouse sensitivity scaler (`setsensitivityscaler`) as of its last frame, 1.0 before any."
  @spec sensitivity_scale(:ets.tid()) :: float()
  def sensitivity_scale(table) do
    case :ets.lookup(table, :sensitivity) do
      [{_, scale}] -> scale
      [] -> 1.0
    end
  end

  @doc """
  A frame of `{width, height}` as RGBA bytes, for a terminal whose pixels are `aspect`
  times as tall as wide. `overlay`, when given, is drawn over the picture at the size it
  is drawn before it is scaled: a function of a `Cauldron3D.Frame` returning one.
  """
  @spec picture(
          pid(),
          {pos_integer(), pos_integer()},
          number(),
          (Cauldron3D.Frame.t() ->
             Cauldron3D.Frame.t())
          | nil
        ) :: binary()
  def picture(pid, size, aspect, overlay \\ nil),
    do: GenServer.call(pid, {:picture, size, aspect, overlay}, :infinity)

  @doc """
  A frame of `{width, height}` for a graphics card to draw: the same frame as
  `picture/4` runs, with the scene described rather than drawn
  (`ElixirHalfLife.Csqc.Described`). Returns `%{overlay:, scene:}`: `overlay` the 2D
  layer as a `Cauldron3D.Frame` at the size the program drew at (at most `:width`
  across), its colours multiplied by its alpha, see-through where the scene shows,
  with `overlay` drawn over it, not put through the gamma ramp; `gamma` the ramp's
  console variables `{gamma, contrast, brightness}` and `tone` the ramp
  (`ElixirHalfLife.Gamma.table/3`); `scene` the frame's last
  scene description, or `nil` when the frame drew none (the level is loading, or the
  client has disconnected), when the scene last described still stands.
  """
  @spec gpu_picture(
          pid(),
          {pos_integer(), pos_integer()},
          number(),
          (Cauldron3D.Frame.t() -> Cauldron3D.Frame.t()) | nil
        ) :: %{
          overlay: Cauldron3D.Frame.t(),
          scene: map() | nil,
          gamma: {number(), number(), number()},
          tone: Gamma.table()
        }
  def gpu_picture(pid, size, aspect, overlay \\ nil),
    do: GenServer.call(pid, {:gpu_picture, size, aspect, overlay}, :infinity)

  @impl true
  def init(opts) do
    runner = Keyword.fetch!(opts, :runner)
    Runner.subscribe(runner, self())

    {:ok,
     %{
       runner: runner,
       level: 0,
       csqc: nil,
       surfaces: Surfaces.new(),
       last: System.monotonic_time(:microsecond),
       started: System.monotonic_time(:microsecond),
       movesequence: 1,
       clock: CommandClock.new(),
       outframes: %{},
       acknowledged: 0,
       gathering: nil,
       input: nil,
       sounds: :ets.new(__MODULE__, [:ordered_set, :public]),
       heard: 0,
       width: Keyword.get(opts, :width, 480),
       menu: MenuProgram.start(Keyword.get(opts, :cvars)),
       cvars: Keyword.get(opts, :cvars),
       loading: System.monotonic_time(:microsecond),
       plaque: :begin,
       keeper: nil,
       starting: false,
       pending: [],
       signon: [],
       configured: [],
       shared: :ets.new(__MODULE__, [:set, :public]),
       drawn: nil,
       scene: nil,
       layer: nil,
       tone: nil,
       ended: nil
     }}
  end

  @impl true
  def handle_cast({:input, command}, state),
    do: {:noreply, %{state | input: keep_impulse(command, state.input)}}

  def handle_cast({:console, _text}, %{csqc: nil} = state), do: {:noreply, state}

  def handle_cast({:console, text}, state),
    do: {:noreply, %{state | csqc: QuakeServer.Console.run(state.csqc, text)}}

  def handle_cast({:configure, text}, state) do
    csqc = if state.csqc, do: QuakeServer.Console.run(state.csqc, text)
    {:noreply, %{state | csqc: csqc, configured: state.configured ++ [text]}}
  end

  def handle_cast({:width, width}, state), do: {:noreply, %{state | width: width}}

  def handle_cast(:screenshot, %{drawn: nil} = state), do: {:noreply, state}

  def handle_cast(:screenshot, state) do
    write_screenshot(state.drawn)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sounds, _from, state), do: {:reply, state.sounds, state}
  def handle_call(:shared, _from, state), do: {:reply, state.shared, state}

  def handle_call({:picture, {width, height} = size, aspect, overlay}, _from, state) do
    {frame, _scene, state} = frame(:software, size, aspect, overlay, state)
    {:reply, scaled(frame, width, height).pixels, state}
  end

  def handle_call({:gpu_picture, size, aspect, overlay}, _from, state) do
    {frame, scene, state} = frame(:gpu, size, aspect, overlay, state)
    tone = state.tone || gamma(state.csqc)
    {:reply, %{overlay: frame, scene: scene, gamma: ramp(state.csqc), tone: tone}, state}
  end

  @impl true
  def handle_info({Runner, {:ended, reason}}, state), do: {:noreply, disconnect(state, reason)}

  def handle_info({Runner, _message}, %{ended: reason} = state) when is_binary(reason),
    do: {:noreply, state}

  def handle_info({:started, keeper, _level, _csqc}, %{ended: reason} = state)
      when is_binary(reason) do
    send(keeper, :release)
    {:noreply, state}
  end

  def handle_info({Runner, {:changing, _map}}, state),
    do: {:noreply, %{begin_loading(stop_sounds(state)) | plaque: :begin}}

  def handle_info({Runner, {:serverdata, serverdata}}, state),
    do: {:noreply, start_level(state, serverdata)}

  def handle_info({Runner, snapshot}, state), do: {:noreply, arrived(state, snapshot)}

  def handle_info({:started, keeper, level, csqc}, %{level: level} = state),
    do: {:noreply, install(state, keeper, csqc)}

  def handle_info({:started, keeper, _level, _csqc}, state) do
    send(keeper, :release)
    {:noreply, state}
  end

  defp arrived(%{level: level} = state, %{level: other}) when level != other, do: state

  defp arrived(%{starting: true} = state, snapshot),
    do: %{state | pending: state.pending ++ [snapshot]}

  defp arrived(state, snapshot), do: take_snapshot(state, snapshot)

  defp take_snapshot(%{level: level} = state, %{level: level} = snapshot) do
    csqc = Models.share(state.csqc, snapshot.model_names)
    csqc = %{csqc | lightstyles: Map.merge(csqc.lightstyles, snapshot.lightstyles)}

    csqc = %{
      csqc
      | ext:
          Map.update(
            csqc.ext,
            :lightstyle_rgb,
            snapshot.lightstyle_colours,
            &Map.merge(&1, snapshot.lightstyle_colours)
          )
    }

    {loading, plaque} =
      if snapshot.packets == [], do: {state.loading, state.plaque}, else: {nil, nil}

    csqc = Csqc.receive(csqc, snapshot.packets, snapshot.time)

    %{
      state
      | csqc: csqc,
        loading: loading,
        plaque: plaque,
        acknowledged: Map.get(csqc.ext, :acknowledged, state.acknowledged)
    }
  end

  defp start_level(state, serverdata) do
    state = if state.csqc, do: shut_down(state), else: state
    state = release_server_cvars(state)
    if state.keeper, do: send(state.keeper, :release)
    owner = self()
    surfaces = state.surfaces
    cvars = state.cvars
    spawn_link(fn -> keep_level(owner, serverdata, surfaces, cvars) end)

    %{
      begin_loading(state)
      | csqc: nil,
        keeper: nil,
        starting: true,
        pending: [],
        signon: serverdata.signon,
        level: serverdata.level,
        plaque: kept_plaque(state.plaque)
    }
  end

  defp keep_level(owner, serverdata, surfaces, cvars) do
    Surfaces.clear(surfaces)

    csqc =
      serverdata.map
      |> Csqc.start(
        models: serverdata.model_names,
        sounds: serverdata.sound_names,
        levelname: serverdata.levelname,
        surfaces: surfaces,
        serverinfo: serverdata.serverinfo,
        cvar_table: cvars
      )
      |> QuakeServer.Console.run("set hud_fastswitch 1")

    send(owner, {:started, self(), serverdata.level, csqc})

    receive do
      :release -> QuakeC.release(csqc.qc)
    end
  end

  defp install(state, keeper, csqc) do
    started = System.monotonic_time(:microsecond)
    pending = state.pending

    csqc = carry_input(csqc, state)
    csqc = Enum.reduce(state.configured, csqc, &QuakeServer.Console.run(&2, &1))
    csqc = Enum.reduce(state.signon, csqc, &Parse.messages/2)
    Runner.begin(state.runner, state.level, csqc: true)

    state = %{
      state
      | csqc: csqc,
        keeper: keeper,
        starting: false,
        pending: [],
        signon: [],
        started: started
    }

    Enum.reduce(pending, state, &arrived(&2, &1))
  end

  defp stop_sounds(%{csqc: nil} = state), do: state

  defp stop_sounds(state) do
    {commands, csqc} = state.csqc |> Sounds.stop_all() |> Sounds.take()
    put_sounds(%{state | csqc: csqc}, commands)
  end

  defp begin_loading(%{loading: nil} = state),
    do: %{state | loading: System.monotonic_time(:microsecond)}

  defp begin_loading(state), do: state

  defp loading_timeout(%{loading: since, csqc: csqc, starting: false} = state)
       when is_integer(since) and csqc != nil do
    if System.monotonic_time(:microsecond) - since > 60_000_000,
      do: %{state | loading: nil, plaque: nil},
      else: state
  end

  defp loading_timeout(state), do: state

  defp frame(_mode, size, _aspect, overlay, %{ended: reason} = state) when is_binary(reason),
    do: disconnected_frame(size, overlay, state)

  defp frame(mode, size, aspect, overlay, state) do
    state = loading_timeout(state)

    if state.loading || state.csqc == nil,
      do: loading_frame(mode, size, aspect, overlay, state),
      else: view_frame(mode, size, aspect, overlay, state)
  end

  defp loading_frame(mode, size, aspect, overlay, state) do
    now = System.monotonic_time(:microsecond)

    state =
      if state.csqc && not state.starting,
        do: send_input(state, frametime(state, now)),
        else: state

    {drawn_width, drawn_height} = drawn = fit(size, state.width)
    virtual = VirtualSize.size(state.csqc || state.menu, drawn_width, drawn_height, aspect)
    {frame, scene, state} = plaque(mode, state, drawn, virtual, aspect, now)
    frame = finish(frame, overlay, layered(mode, state.tone || gamma(state.csqc)))
    {frame, scene, %{state | last: now, drawn: frame}}
  end

  defp plaque(mode, %{plaque: :begin} = state, {width, height}, virtual, aspect, now) do
    {view, scene, state} = plaque_view(mode, state, {width, height}, aspect, now)
    {frame, menu} = LoadingScreen.beginning(state.menu, view, width, height, virtual)
    {frame, scene, %{state | menu: menu, plaque: {:frozen, frame}}}
  end

  defp plaque(
         _mode,
         %{plaque: {:frozen, %{width: width, height: height} = frame}} = state,
         {width, height},
         _virtual,
         _aspect,
         _now
       ),
       do: {frame, nil, state}

  defp plaque(
         _mode,
         %{plaque: {:frozen, frame}} = state,
         {width, height},
         _virtual,
         _aspect,
         _now
       ),
       do: {Cauldron3D.Frame.scale(frame, width, height), nil, state}

  defp kept_plaque({:frozen, _frame} = plaque), do: plaque
  defp kept_plaque(_plaque), do: :begin

  defp plaque_view(mode, %{csqc: nil} = state, size, _aspect, _now),
    do: {last_scene(mode, state, size), nil, state}

  defp plaque_view(mode, %{starting: true} = state, size, _aspect, _now),
    do: {last_scene(mode, state, size), nil, state}

  defp plaque_view(mode, state, {width, height}, aspect, now) do
    csqc = state.csqc |> put_ext(:aspect, aspect) |> drawing(mode)
    cltime = (now - state.started) / 1_000_000
    {frame, csqc} = Csqc.view(csqc, width, height, frametime(state, now), cltime)
    {scene, csqc} = described(csqc, mode)
    {frame, scene, %{state | csqc: csqc}}
  end

  defp last_scene(:software, %{scene: nil}, _size), do: nil
  defp last_scene(:software, %{scene: scene}, {width, height}), do: scaled(scene, width, height)
  defp last_scene(:gpu, %{layer: nil}, _size), do: nil
  defp last_scene(:gpu, %{layer: layer}, {width, height}), do: scaled(layer, width, height)

  defp put_ext(csqc, key, value), do: %{csqc | ext: Map.put(csqc.ext, key, value)}

  defp drawing(csqc, :gpu), do: csqc |> put_ext(:gpu, true) |> put_ext(:described, [])
  defp drawing(csqc, :software), do: %{csqc | ext: Map.drop(csqc.ext, [:gpu, :described])}

  defp described(csqc, :gpu) do
    {described, ext} = Map.pop(csqc.ext, :described, [])
    {List.last(described), %{csqc | ext: Map.delete(ext, :gpu)}}
  end

  defp described(csqc, :software), do: {nil, csqc}

  defp keep_screen(state, :software, screen), do: %{state | scene: screen}
  defp keep_screen(state, :gpu, screen), do: %{state | layer: screen}

  defp layered(:software, tone), do: tone
  defp layered(:gpu, _tone), do: Gamma.table(1.0, 1.0, 0.0)

  defp finish(frame, overlay, tone) do
    frame = if overlay, do: overlay.(frame), else: frame
    %{frame | pixels: Gamma.adjust(tone, frame.pixels)}
  end

  defp gamma(nil), do: Gamma.table(1.0, 1.0, 0.0)

  defp gamma(csqc),
    do:
      Gamma.table(
        cvar(csqc, "gamma", 1.0),
        cvar(csqc, "contrast", 1.0),
        cvar(csqc, "brightness", 0.0)
      )

  defp ramp(nil), do: {1.0, 1.0, 0.0}

  defp ramp(csqc),
    do: {cvar(csqc, "gamma", 1.0), cvar(csqc, "contrast", 1.0), cvar(csqc, "brightness", 0.0)}

  defp cvar(csqc, name, default),
    do: if(Server.cvar?(csqc, name), do: Server.cvar(csqc, name), else: default)

  defp write_screenshot(frame) do
    directory = Cauldron2D.Paths.data(:elixir_half_life, ["screenshots"])
    File.mkdir_p!(directory)
    taken = directory |> File.ls!() |> length()
    name = "fte-" <> String.pad_leading(Integer.to_string(taken), 5, "0") <> ".png"

    File.write!(
      Path.join(directory, name),
      FrenchCurve.Png.encode(frame.width, frame.height, frame.pixels)
    )
  end

  defp frametime(state, now), do: min((now - state.last) / 1_000_000, 0.25)

  defp scaled(%{width: width, height: height} = frame, width, height), do: frame
  defp scaled(frame, width, height), do: Cauldron3D.Frame.scale(frame, width, height)

  defp view_frame(mode, size, aspect, overlay, state) do
    now = System.monotonic_time(:microsecond)
    seconds = frametime(state, now)
    state = send_input(state, seconds)
    csqc = state.csqc |> put_ext(:aspect, aspect) |> drawing(mode)
    {drawn_width, drawn_height} = fit(size, state.width)
    cltime = (now - state.started) / 1_000_000
    {screen, csqc} = Csqc.view(csqc, drawn_width, drawn_height, seconds, cltime)
    {scene, csqc} = described(csqc, mode)
    tone = gamma(csqc)
    frame = finish(screen, overlay, layered(mode, tone))
    :ets.insert(state.shared, {:sensitivity, Map.get(csqc.ext, :sensitivity, 1.0) / 1})

    state =
      %{state | csqc: csqc, last: now, drawn: frame, tone: tone}
      |> keep_screen(mode, screen)
      |> keep_sounds()
      |> send_requests()

    {frame, scene, state}
  end

  defp send_requests(state) do
    {requests, ext} = Map.pop(state.csqc.ext, :sent_events, [])
    Enum.each(requests, fn {name, values} -> Runner.request(state.runner, name, values) end)
    %{state | csqc: %{state.csqc | ext: ext}}
  end

  defp keep_sounds(state) do
    {events, csqc} = Server.drain(state.csqc)
    csqc = Enum.reduce(events, csqc, &local_sound/2)
    view = Scene.scene(csqc).view
    origin = Map.get(view, 11, {0.0, 0.0, 0.0})
    angles = Map.get(view, 15, {0.0, 0.0, 0.0})
    {commands, csqc} = csqc |> Sounds.update(@player, origin, angles) |> Sounds.take()
    put_sounds(%{state | csqc: csqc}, commands)
  end

  defp local_sound({:sound, sound}, csqc) do
    Sounds.start(csqc, %{
      entity: 0,
      channel: -1,
      name: sound.name,
      origin: nil,
      volume: sound.volume,
      attenuation: 0.0,
      pitch: 0.0
    })
  end

  defp local_sound(_event, csqc), do: csqc

  defp audio_event({:play, key, name, gain, pan, rate}, :full),
    do: Audio.keyed(key, {:sample, name, rate}, {:level, gain, pan})

  defp audio_event({:play, key, name, gain, pan, rate}, :s8),
    do: Audio.keyed(key, {:sample, name, rate, :s8}, {:level, gain, pan})

  defp audio_event({:place, key, gain, pan}, _width), do: Audio.moved(key, {:level, gain, pan})
  defp audio_event({:stop, key}, _width), do: Audio.stopped(key)

  defp keep_impulse(%{impulse: 0} = command, %{impulse: impulse}),
    do: %{command | impulse: impulse}

  defp keep_impulse(command, _previous), do: command

  defp send_input(%{input: nil} = state, _frametime), do: state

  defp send_input(state, frametime) do
    netfps = cvar(state.csqc, "cl_netfps", 150.0)

    case CommandClock.tick(state.clock, frametime, netfps, server_maxfps(state.csqc)) do
      {:none, _msec, clock} -> %{state | clock: clock}
      {:hold, msec, clock} -> gather(%{state | clock: clock}, msec)
      {:send, msec, clock} -> %{state | clock: clock} |> gather(msec) |> send_command()
    end
  end

  defp disconnect(state, reason) do
    state = release_server_cvars(state)
    state = if state.csqc, do: shut_down(state), else: state
    if state.keeper, do: send(state.keeper, :release)

    %{
      state
      | csqc: nil,
        keeper: nil,
        ended: reason,
        loading: nil,
        plaque: nil,
        starting: false,
        pending: []
    }
  end

  defp shut_down(state) do
    csqc =
      state.csqc
      |> Sounds.stop_all()
      |> Server.set_globals(0, 0)
      |> Server.call_named("CSQC_Shutdown")

    {commands, csqc} = Sounds.take(csqc)
    put_sounds(%{state | csqc: csqc}, commands)
  end

  defp put_sounds(state, commands) do
    sample_width = if cvar(state.csqc, "loadas8bit", 0.0) != 0, do: :s8, else: :full
    sounds = Enum.map(commands, &audio_event(&1, sample_width))

    sounds
    |> Enum.with_index(state.heard)
    |> Enum.each(fn {sound, n} -> :ets.insert(state.sounds, {n, sound}) end)

    %{state | heard: state.heard + length(sounds)}
  end

  defp disconnected_frame({width, height}, overlay, state) do
    {drawn_width, drawn_height} = fit({width, height}, state.width)
    black = :binary.copy(<<0, 0, 0, 255>>, drawn_width * drawn_height)

    frame =
      finish(
        %Cauldron3D.Frame{width: drawn_width, height: drawn_height, pixels: black, format: :rgba},
        overlay,
        gamma(nil)
      )

    {frame, nil, %{state | drawn: frame}}
  end

  defp fit({width, height}, most) when width <= most, do: {width, height}
  defp fit({width, height}, most), do: {most, max(round(height * most / width), 1)}

  defp server_maxfps(csqc) do
    csqc.ext
    |> Map.get(:serverinfo, %{})
    |> Map.get("maxfps", "")
    |> QuakeServer.Cvars.atof()
  end

  defp gather(state, msec) do
    command = state.input
    {pitch, yaw, roll} = command.angles
    angles = {pitch / 1, yaw / 1, roll / 1}

    gathering = %{
      angles: angles,
      movevalues: {command.forward / 1, command.side / 1, command.up / 1},
      buttons: gathered_buttons(state, command.buttons),
      impulse: command.impulse,
      timelength: msec / 1000,
      sequence: state.movesequence
    }

    ext =
      state.csqc.ext
      |> Map.put(:pending, gathering)
      |> Map.put(:view_angles, angles)
      |> Map.put(:movesequence, state.movesequence)

    %{state | gathering: gathering, csqc: %{state.csqc | ext: ext}}
  end

  defp gathered_buttons(%{movesequence: sequence}, _buttons) when sequence <= 2, do: 0

  defp gathered_buttons(
         %{gathering: %{sequence: sequence, timelength: seconds} = held} = state,
         _buttons
       )
       when sequence == state.movesequence and seconds > 0,
       do: held.buttons

  defp gathered_buttons(_state, buttons), do: buttons

  defp send_command(state) do
    sequence = state.movesequence
    sent_at = System.monotonic_time(:microsecond)

    csqc =
      state.csqc
      |> Input.put_input(state.gathering)
      |> put_input_frame(sequence, state.gathering.angles)
      |> Server.set_globals(0, 0)
      |> Server.call_named("CSQC_Input_Frame")

    sent = csqc |> sent_input(sequence) |> Map.put(:sent, sent_at)
    Runner.command(state.runner, server_command(state.input, sent))
    following = %{sent | timelength: 0.0, impulse: 0, sequence: sequence + 1}

    ext =
      csqc.ext
      |> Input.keep_frame(sent)
      |> Map.put(:movesequence, sequence + 1)
      |> Map.put(:pending, following)

    %{
      state
      | csqc: %{csqc | ext: ext},
        movesequence: sequence + 1,
        outframes: Map.put(state.outframes, Bitwise.band(sequence, 63), sent),
        gathering: following,
        input: %{state.input | impulse: 0}
    }
  end

  defp put_input_frame(csqc, sequence, angles) do
    qc =
      csqc.qc
      |> QuakeC.put_declared("clientcommandframe", sequence / 1)
      |> QuakeC.put_declared("view_angles", angles)

    %{csqc | qc: qc}
  end

  defp sent_input(csqc, sequence) do
    %{
      angles: QuakeC.global_vector(csqc.qc, "input_angles"),
      movevalues: QuakeC.global_vector(csqc.qc, "input_movevalues"),
      buttons: trunc(QuakeC.float(QuakeC.global(csqc.qc, "input_buttons"))),
      impulse: trunc(QuakeC.float(QuakeC.global(csqc.qc, "input_impulse"))),
      timelength: QuakeC.float(QuakeC.global(csqc.qc, "input_timelength")),
      sequence: sequence
    }
  end

  defp server_command(command, sent) do
    {forward, side, up} = sent.movevalues

    command
    |> Map.merge(%{
      angles: sent.angles,
      forward: forward,
      side: side,
      up: up,
      buttons: sent.buttons,
      impulse: sent.impulse,
      timelength: sent.timelength
    })
    |> Map.put(:msec, sent.timelength |> Kernel.*(1000) |> single() |> trunc())
    |> Map.put(:sequence, sent.sequence)
  end

  defp single(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end

  defp release_server_cvars(state) do
    case state.cvars || (state.csqc && state.csqc.cvars) do
      nil -> :ok
      cvars -> QuakeServer.Cvars.apply_latches(cvars, :serveroverride, clear: true)
    end

    state
  end

  defp carry_input(csqc, state) do
    ext =
      csqc.ext
      |> Map.put(:movesequence, state.movesequence)
      |> Map.put(:input_frames, state.outframes)
      |> Map.put(:acknowledged, state.acknowledged)
      |> Map.put(:pending, state.gathering)

    Csqc.put_command_frames(%{csqc | ext: ext})
  end
end
