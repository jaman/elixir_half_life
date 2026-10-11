defmodule ElixirHalfLife.Csqc.Animation do
  @moduledoc """
  Studio entities posed by GoldSrc's client rule (`CStudioModelRenderer::StudioEstimateFrame`
  in Valve's `cl_dll/StudioModelRenderer.cpp`, `R_StudioEstimateFrame` in Xash3D) from the
  animation the server carries with each packet (`QuakeServer.Animation`).

      csqc = ElixirHalfLife.Csqc.Animation.receive(csqc, packet)
      seconds = ElixirHalfLife.Csqc.Animation.seconds(csqc, entity, time)
      frame = ElixirHalfLife.Csqc.Animation.frame(sequence, seconds)

  `receive/2` keeps a packet's states by server entity number, and forgets the state of
  each entity the packet removes. `note/2` marks an entity the client program gives a
  `frame1time` of its own (not 0) when it is added to the scene; the program times that
  entity from then on, until the server removes it.

  `seconds/3` is how far into its sequence an entity the server sent (`entnum` not 0) is
  shown at client time `time`, when the program does not time it itself: its
  `frame1time` is 0, it is not marked, its render flags lack `RF_FRAMETIMESARESTARTTIMES`
  (64), and the server's state is for the sequence its `frame` names. The seconds are
  `time + (time_now - animtime) * framerate` of the state, with no time passed while
  `time_now` is before `animtime`; otherwise `nil`.

  `frame/2` is the frame shown `seconds` into a sequence (`%{frames:, fps:, flags:}`),
  as GoldSrc's client works it out: `seconds * fps`; a looping sequence (flag 1) wraps
  every `frames - 1` frames, back into `0..frames - 1` when below 0; one that does not
  loop stays between 0 and `frames - 1.001`; a sequence of one frame or none is at 0.
  """

  import Bitwise

  alias QuakeServer.{Edicts, Server}

  @start_times 64

  @doc "Keep `packet`'s animation states and forget those of the entities it removes."
  @spec receive(Server.t(), map()) :: Server.t()
  def receive(%Server{} = csqc, packet) do
    removed = for {:remove, number} <- Map.get(packet, :entities, []), do: number
    states = csqc.ext |> Map.get(:animation, %{}) |> Map.drop(removed)

    timed =
      csqc.ext |> Map.get(:program_timed, MapSet.new()) |> MapSet.difference(MapSet.new(removed))

    states = Map.merge(states, Map.get(packet, :animation, %{}))
    %{csqc | ext: csqc.ext |> Map.put(:animation, states) |> Map.put(:program_timed, timed)}
  end

  @doc "Mark `entity` as timed by the client program when its `frame1time` is not 0."
  @spec note(Server.t(), non_neg_integer()) :: Server.t()
  def note(%Server{} = csqc, entity) do
    case {entnum(csqc, entity), Edicts.float(csqc, entity, "frame1time")} do
      {0, _time} ->
        csqc

      {_number, time} when time == 0 ->
        csqc

      {number, _time} ->
        timed = csqc.ext |> Map.get(:program_timed, MapSet.new()) |> MapSet.put(number)
        %{csqc | ext: Map.put(csqc.ext, :program_timed, timed)}
    end
  end

  @doc "How many seconds into its sequence `entity` is shown at client time `time`, or `nil`."
  @spec seconds(Server.t(), non_neg_integer(), float()) :: float() | nil
  def seconds(%Server{} = csqc, entity, time) do
    number = entnum(csqc, entity)
    state = csqc.ext |> Map.get(:animation, %{}) |> Map.get(number)

    if number != 0 and state != nil and untimed?(csqc, entity, number) and
         trunc(state.sequence) == sequence(csqc, entity),
       do: state.time + max(time - state.animtime, 0.0) * state.framerate
  end

  @doc "The frame shown `seconds` into `sequence`."
  @spec frame(%{frames: integer(), fps: number(), flags: integer()}, float()) :: float()
  def frame(%{frames: frames}, _seconds) when frames <= 1, do: 0.0

  def frame(%{frames: frames, fps: fps, flags: flags}, seconds) when band(flags, 1) != 0 do
    span = frames - 1
    frame = seconds * fps
    frame = frame - trunc(frame / span) * span
    if frame < 0, do: frame + span, else: frame
  end

  def frame(%{frames: frames, fps: fps}, seconds),
    do: (seconds * fps) |> min(frames - 1.001) |> max(0.0)

  defp untimed?(csqc, entity, number) do
    Edicts.float(csqc, entity, "frame1time") == 0 and
      band(Edicts.int(csqc, entity, "renderflags"), @start_times) == 0 and
      not MapSet.member?(Map.get(csqc.ext, :program_timed, MapSet.new()), number)
  end

  defp sequence(csqc, entity), do: band(Edicts.int(csqc, entity, "frame"), bnot(0x8000))

  defp entnum(csqc, entity) do
    if QuakeC.field_offset(csqc.qc, "entnum"),
      do: Edicts.int(csqc, entity, "entnum"),
      else: 0
  end
end
