defmodule ElixirHalfLife.Csqc do
  @moduledoc """
  FreeHL's client program (`csprogs.dat`, FTE's CSQC) running in its own world of the
  same map: it hears the server's entity updates and events, reads the player's input,
  and draws each frame — the world, the entities it chose, and its own screen.

      csqc = ElixirHalfLife.Csqc.start("c1a0")
      csqc = ElixirHalfLife.Csqc.receive(csqc, packets, time)

  The client's entity for server entity `n` is made on its first update, with `entnum`
  set to `n`, and given to `CSQC_Ent_Update(isnew)` as `self`; a removal calls
  `CSQC_Ent_Remove`. A packet whose first byte is 83 (`SVC_CGAMEPACKET`) is handed to
  `CSQC_Parse_Event` without that byte.
  """

  alias Cauldron3D.Bsp.Surfaces

  alias ElixirHalfLife.Csqc.{
    Animation,
    Builtins,
    Messages,
    Parse,
    Precaches,
    Scene,
    Screen,
    VirtualSize
  }

  alias QuakeServer.{Edicts, Models, Server}
  alias QuakeServer.Extensions.Web

  @doc """
  The client program started on map `name`, as FTE's `CSQC_Init` and `CSQC_WorldLoaded`
  start one: the program's `init` runs with `-1` and its `initents` after, the world's
  `message` becomes the level's name, `CSQC_Init` runs with FTE's API version 1, engine
  name `"FTE QW"` and version 10700, the client's physics clock starts at 0.1, then
  `CSQC_RendererRestarted` runs (given the renderer's name, `"OpenGL"`) and
  `CSQC_WorldLoaded`.

  Option `:serverinfo` is the server's info keys, there before `CSQC_Init` runs, as FTE's
  client has them from connecting; `:levelname` the level's name (FTE's `levelname` from
  `svc_serverdata`); `:models` the server's model list, shared before the program starts
  (`QuakeServer.Models.share/2`); `:sounds` the server's sound list, index 0 the empty
  name (`ElixirHalfLife.Csqc.Precaches`); `:surfaces` is the `Cauldron3D.Bsp.Surfaces` cache to draw the world
  with, which must belong to a process that outlives the program (default a new one,
  belonging to the caller); the rest are `QuakeServer.Server.open/2`'s.
  """
  @spec start(String.t(), keyword()) :: Server.t()
  def start(name, opts \\ []) do
    {models, opts} = Keyword.pop(opts, :models, [""])
    {surfaces, opts} = Keyword.pop_lazy(opts, :surfaces, &Surfaces.new/0)
    {serverinfo, opts} = Keyword.pop(opts, :serverinfo, %{})
    {levelname, opts} = Keyword.pop(opts, :levelname, "")
    {sounds, opts} = Keyword.pop(opts, :sounds, [""])

    opts =
      [
        source: ElixirHalfLife.ClientSource,
        builtins: Builtins,
        budget: 50_000_000,
        coords: :float,
        hull: &ElixirHalfLife.Assets.hull/2
      ]
      |> Keyword.merge(opts)

    name
    |> Server.open(opts)
    |> Models.share(models)
    |> Map.update!(
      :ext,
      &(&1
        |> Map.put(:entities, %{})
        |> Map.put(:surfaces, surfaces)
        |> Map.put(:serverinfo, serverinfo))
    )
    |> Precaches.put_sounds(1, Enum.drop(sounds, 1))
    |> put_globals(0.0)
    |> call("init", [-1.0])
    |> call("initents", [])
    |> Edicts.put(0, "message", levelname)
    |> call("CSQC_Init", [1.0, "FTE QW", 10_700.0])
    |> QuakeServer.Console.flush()
    |> Map.update!(:ext, &Map.put(&1, :physicstime, 0.1))
    |> call("CSQC_RendererRestarted", ["OpenGL"])
    |> QuakeServer.Console.flush()
    |> call("CSQC_WorldLoaded", [])
    |> QuakeServer.Console.flush()
  end

  @doc """
  Hand the client the server's packets, at server time `time` (the program's `time`
  global; `cltime` keeps what the last frame set): for each, oldest first, its reliable
  messages, the command it acknowledges (its `sequence`, kept as `ext.acknowledged` and
  put in the command frame globals, `put_command_frames/1`), its entity updates, its
  animation states (`ElixirHalfLife.Csqc.Animation.receive/2`) and its datagram, as FTE's
  client reads a packet (`ElixirHalfLife.Csqc.Parse`).
  """
  @spec receive(Server.t(), [map()], float()) :: Server.t()
  def receive(%Server{} = csqc, packets, time) do
    csqc = %{csqc | time: time, qc: QuakeC.put_declared(csqc.qc, "time", time / 1)}
    Enum.reduce(packets, csqc, &packet/2)
  end

  defp packet(packet, csqc) do
    csqc = Enum.reduce(packet.reliable, csqc, &Parse.messages/2)
    csqc = acknowledge(csqc, packet)
    csqc = Enum.reduce(packet.entities, csqc, &update/2)
    csqc = Animation.receive(csqc, packet)
    Enum.reduce(packet.datagram, csqc, &Parse.messages/2)
  end

  defp acknowledge(csqc, %{sequence: sequence}) do
    ext = Map.put(csqc.ext, :acknowledged, sequence)
    put_command_frames(%{csqc | ext: ext})
  end

  defp acknowledge(csqc, _packet), do: csqc

  @doc """
  The `clientcommandframe` and `servercommandframe` globals set from `ext.movesequence`
  (the number of the command being gathered) and `ext.acknowledged` (the last the
  server acknowledged), as FTE sets them before the program reads entities or draws.
  """
  @spec put_command_frames(Server.t()) :: Server.t()
  def put_command_frames(%Server{} = csqc) do
    qc =
      csqc.qc
      |> QuakeC.put_declared("clientcommandframe", Map.get(csqc.ext, :movesequence, 0) / 1)
      |> QuakeC.put_declared("servercommandframe", Map.get(csqc.ext, :acknowledged, 0) / 1)

    %{csqc | qc: qc}
  end

  @doc """
  Draw a frame of `width` by `height`, as FTE's `CSQC_DrawView` does: the client's own
  entities run their physics frames up to the server's time (`physics_mode` set: frames
  of 0.01 to 0.1 seconds, ten at most, the rest dropped; unset: one `StartFrame` and
  `EndFrame` at the server's time), the replies to `uri_get` that came are handed to its
  `URI_Get_Callback` (`QuakeServer.Extensions.Web.run/1`), then the program's
  `CSQC_UpdateView` runs on a fresh black screen with an empty
  scene, `frametime` seconds after the last frame (at most
  0.1), `cltime` seconds since the level started, and the command frames set
  (`put_command_frames/1`). The program is given the 2D size
  `ElixirHalfLife.Csqc.VirtualSize` works out for the picture (its pixels each the host's
  `ext.aspect` times as tall as wide, default 1), also put in the `autocvar_vid_conwidth`
  and `autocvar_vid_conheight` globals when it has them; everything it draws in 2D is
  scaled from that size to the picture's pixels. Returns the frame (RGBA) and the
  client.
  """
  @spec view(Server.t(), pos_integer(), pos_integer(), float(), float()) ::
          {Cauldron3D.Frame.t(), Server.t()}
  def view(%Server{} = csqc, width, height, frametime, cltime) do
    csqc = physics(csqc, csqc.time)

    qc =
      csqc.qc
      |> QuakeC.put_declared("frametime", (frametime |> max(0.0) |> min(0.1)) / 1)
      |> QuakeC.put_declared("clframetime", frametime / 1)
      |> QuakeC.put_declared("cltime", cltime / 1)
      |> QuakeC.put_declared("time", csqc.time / 1)

    {vw, vh} = virtual = VirtualSize.size(csqc, width, height, Map.get(csqc.ext, :aspect, 1.0))

    qc =
      qc
      |> put_known("autocvar_vid_conwidth", vw / 1)
      |> put_known("autocvar_vid_conheight", vh / 1)

    csqc =
      %{csqc | qc: qc}
      |> Web.run()
      |> Screen.begin(width, height, virtual)
      |> Scene.clear()
      |> put_command_frames()
      |> call("CSQC_UpdateView", [vw / 1, vh / 1, 1.0])
      |> QuakeServer.Console.flush()

    {Screen.frame(csqc), csqc}
  end

  defp put_known(qc, name, value) do
    if QuakeC.global?(qc, name), do: QuakeC.put_declared(qc, name, value), else: qc
  end

  defp physics(csqc, servertime) do
    physicstime = Map.get(csqc.ext, :physicstime, servertime)

    mode =
      if QuakeC.global?(csqc.qc, "physics_mode"),
        do: QuakeC.float(QuakeC.global(csqc.qc, "physics_mode")),
        else: 0.0

    if mode == 0,
      do: still(csqc, servertime),
      else: step(csqc, servertime, physicstime, 10)
  end

  defp still(csqc, servertime) do
    csqc
    |> then(&%{&1 | time: servertime})
    |> Server.set_globals(0, 0)
    |> Server.call_named("StartFrame")
    |> Server.set_globals(0, 0)
    |> Server.call_named("EndFrame")
    |> then(&%{&1 | time: servertime, ext: Map.put(&1.ext, :physicstime, servertime)})
  end

  defp step(csqc, servertime, physicstime, left) do
    seconds = servertime - physicstime

    cond do
      seconds < 0.01 ->
        done(csqc, servertime, physicstime)

      left - 1 == 0 ->
        done(csqc, servertime, servertime)

      true ->
        seconds = min(seconds, 0.1)
        qc = QuakeC.put_declared(csqc.qc, "frametime", seconds / 1)

        csqc =
          %{csqc | qc: qc, time: physicstime, frametime: seconds}
          |> QuakeServer.Physics.frame()

        step(csqc, servertime, physicstime + seconds, left - 1)
    end
  end

  defp done(csqc, servertime, physicstime),
    do: %{csqc | time: servertime, ext: Map.put(csqc.ext, :physicstime, physicstime)}

  defp update({:update, number, bytes}, csqc) do
    {csqc, entity, new?} = entity(csqc, number)

    csqc
    |> Messages.start(bytes)
    |> Server.set_globals(entity, 0)
    |> put_args([if(new?, do: 1.0, else: 0.0)])
    |> Server.call_named("CSQC_Ent_Update")
  end

  defp update({:remove, number}, csqc) do
    case Map.pop(csqc.ext.entities, number) do
      {nil, _} ->
        csqc

      {entity, entities} ->
        %{csqc | ext: Map.put(csqc.ext, :entities, entities)}
        |> Server.set_globals(entity, 0)
        |> Server.call_named("CSQC_Ent_Remove")
    end
  end

  defp entity(csqc, number) do
    case Map.get(csqc.ext.entities, number) do
      entity when is_integer(entity) ->
        if Edicts.free?(csqc, entity), do: fresh(csqc, number), else: {csqc, entity, false}

      nil ->
        fresh(csqc, number)
    end
  end

  defp fresh(csqc, number) do
    {csqc, entity} = Edicts.alloc(csqc)
    csqc = Edicts.put(csqc, entity, "entnum", number / 1)
    {%{csqc | ext: put_in(csqc.ext, [:entities, number], entity)}, entity, true}
  end

  defp call(csqc, name, args),
    do: csqc |> Server.set_globals(0, 0) |> put_args(args) |> Server.call_named(name)

  defp put_args(csqc, args) do
    qc =
      args
      |> Enum.with_index()
      |> Enum.reduce(csqc.qc, fn {value, i}, qc -> QuakeC.put_slot(qc, 4 + 3 * i, value) end)

    %{csqc | qc: qc}
  end

  defp put_globals(csqc, time) do
    qc =
      csqc.qc
      |> QuakeC.put_declared("time", time)
      |> QuakeC.put_declared("cltime", time)
      |> QuakeC.put_declared("player_localentnum", 1.0)
      |> QuakeC.put_declared("player_localnum", 0.0)
      |> QuakeC.put_declared("maxclients", 1.0)
      |> QuakeC.put_declared("numclientseats", 1.0)

    %{csqc | qc: qc}
  end
end
