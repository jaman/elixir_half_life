defmodule ElixirHalfLife.Csqc.Sounds do
  @moduledoc """
  The client program's sound builtins as FTE's client runs them (`PF_cs_sound`,
  `PF_cs_pointsound`, `PF_stopsound`, `PF_soundupdate`, `PF_getsoundtime`,
  `PF_getchannellevel`), on the client's channels (`ElixirHalfLife.Sound`) kept in the
  host's `ext.sound`; the channel commands they make gather in `ext.sound_commands`,
  oldest first. A client entity's sounds are numbered by its negated entity number; a
  sound from a brush entity (solid 4) comes from the middle of its box. Pitch is in
  percent, 0 meaning normal.

      csqc = ElixirHalfLife.Csqc.Sounds.start(csqc, %{entity: 1, channel: 1, name: "a.wav",
        origin: {0.0, 0.0, 0.0}, volume: 1.0, attenuation: 1.0, pitch: 0.0})
  """

  alias Cauldron3D.Vec
  alias ElixirHalfLife.{Assets, Sound}
  alias QuakeServer.{Args, Edicts}

  @doc "Run sound builtin `builtin` called with `argc` arguments."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 8, argc) do
    case Args.str(s, 2) do
      "" -> s
      name -> start(s, entity_sound(s, Args.int(s, 0), Args.int(s, 1), name, 3, argc))
    end
  end

  def call(s, 483, argc) do
    start(s, %{
      entity: 0,
      channel: 0,
      name: Args.str(s, 1),
      origin: Args.vec(s, 0),
      volume: Args.num(s, 2),
      attenuation: Args.num(s, 3),
      pitch: Args.num(s, 4, argc, 0.0) * 0.01
    })
  end

  def call(s, "stopsound", _argc) do
    {sound, commands} = Sound.stop(sound(s), -Args.int(s, 0), Args.int(s, 1), now())
    put(s, sound, commands)
  end

  def call(s, "soundupdate", argc) do
    started = entity_sound(s, Args.int(s, 0), Args.int(s, 1), Args.str(s, 2), 3, argc)
    {sound, commands, result} = Sound.update_sound(sound(s), started, &Assets.sample/1, now())
    s |> put(sound, commands) |> Args.return(result)
  end

  def call(s, 533, _argc),
    do: Args.return(s, Sound.sound_time(sound(s), -Args.int(s, 0), Args.int(s, 1), now()))

  def call(s, "getchannellevel", _argc),
    do: Args.return(s, Sound.level(sound(s), -Args.int(s, 0), Args.int(s, 1), now()))

  @doc "Start `start` (as `ElixirHalfLife.Sound.start/4` takes it) on the client's channels."
  @spec start(map(), map()) :: map()
  def start(s, start) do
    {sound, commands} = Sound.start(sound(s), start, &Assets.sample/1, now())
    put(s, sound, commands)
  end

  @doc """
  Put the listener at `origin` facing `angles` as entity `entity`, move the channels
  that follow a client entity to where it is now (`ElixirHalfLife.Sound.follow/2`: its
  origin, plus half its `absmin` and half its `absmax` for a brush entity, solid 4; a
  freed entity leaves its channels where they are), and re-place every channel.
  """
  @spec update(map(), integer(), tuple(), tuple()) :: map()
  def update(s, entity, origin, angles) do
    {sound, commands} =
      s
      |> sound()
      |> Sound.listen(entity, origin, angles)
      |> Sound.follow(&followed(s, -&1))
      |> Sound.update(now())

    put(s, sound, commands)
  end

  @doc "Where the listener was last put (`update/4`), the origin before then."
  @spec listener_origin(map()) :: tuple()
  def listener_origin(s), do: sound(s).listener.origin

  @doc "Stop every channel, as FTE's client does when it disconnects (`S_StopAllSounds`)."
  @spec stop_all(map()) :: map()
  def stop_all(s) do
    {sound, commands} = s |> sound() |> Sound.stop_all()
    put(s, sound, commands)
  end

  @doc "The channel commands gathered since the last take, oldest first, and the host without them."
  @spec take(map()) :: {[Sound.command()], map()}
  def take(s) do
    {commands, ext} = Map.pop(s.ext, :sound_commands, [])
    {commands, %{s | ext: ext}}
  end

  defp entity_sound(s, entity, channel, name, first, argc) do
    %{
      entity: -entity,
      channel: channel,
      name: name,
      origin: origin(s, entity),
      volume: Args.num(s, first),
      attenuation: Args.num(s, first + 1),
      pitch: Args.num(s, first + 2, argc, 0.0) * 0.01,
      flags: trunc(Args.num(s, first + 3, argc, 0.0))
    }
  end

  defp origin(s, entity) do
    origin = Edicts.vector(s, entity, "origin")

    if Edicts.int(s, entity, "solid") == 4 do
      {x0, y0, z0} = Edicts.vector(s, entity, "mins")
      {x1, y1, z1} = Edicts.vector(s, entity, "maxs")
      {x, y, z} = origin
      {x + 0.5 * x0 + 0.5 * x1, y + 0.5 * y0 + 0.5 * y1, z + 0.5 * z0 + 0.5 * z1}
    else
      origin
    end
  end

  defp followed(s, entity) do
    cond do
      Edicts.free?(s, entity) ->
        nil

      Edicts.int(s, entity, "solid") == 4 ->
        s
        |> Edicts.vector(entity, "origin")
        |> Vec.madd(Edicts.vector(s, entity, "absmin"), 0.5)
        |> Vec.madd(Edicts.vector(s, entity, "absmax"), 0.5)

      true ->
        Edicts.vector(s, entity, "origin")
    end
  end

  defp sound(s), do: Map.get(s.ext, :sound) || Sound.new()

  defp put(s, sound, commands),
    do: %{
      s
      | ext:
          s.ext
          |> Map.put(:sound, sound)
          |> Map.update(:sound_commands, commands, &(&1 ++ commands))
    }

  defp now, do: System.monotonic_time(:microsecond) / 1_000_000
end
