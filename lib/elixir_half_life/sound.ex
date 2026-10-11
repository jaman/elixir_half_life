defmodule ElixirHalfLife.Sound do
  @moduledoc """
  FTE's sound channels for one listener (`snd_dma.c`): which channel a sound starts on,
  how loud it is in each ear, where it is in its sample, and when it is re-placed as the
  listener moves. The result is a list of commands for a stage of keyed voices, one key
  a channel.

      sound = ElixirHalfLife.Sound.new()
      sound = ElixirHalfLife.Sound.listen(sound, 1, eye, view_angles)
      {sound, commands} = ElixirHalfLife.Sound.start(sound, start, &samples/1, now)
      {sound, commands} = ElixirHalfLife.Sound.update(sound, now)

  A start is `%{entity:, channel:, name:, origin:, volume:, attenuation:, pitch:}`, with
  `:flags` optional: `volume` 0.0 to 1.0 (below 0 stops the channel), `attenuation` 0
  heard everywhere and 1 normal, `pitch` a playback rate (0 meaning 1), `origin` `nil` for
  the listener's own place; `flags` bit 2 loops the sound (`CF_FORCELOOP`), bit 4 plays
  it unspatialised (`CF_NOSPACIALISE`), bit 64 has it follow its entity (`CF_FOLLOW`,
  `follow/2`), bit 128 leaves a sound already on that entity and channel alone
  (`CF_NOREPLACE`). `samples` gives a sound's `%{seconds:, loop:,
  rate:, pcm:}` (`loop` the loop start in seconds or `nil`, `pcm` mono 16-bit), or `nil`
  for a sound that cannot be loaded. `now` is seconds on any steady clock.

  Channels:

    * a sound on a channel other than 0 replaces the sound playing on the same entity
      and channel; otherwise it takes the last channel that has finished, or a new one;
      channels are never taken from a sound still playing
    * a channel finishes when its sound has played to its end; a looping sound plays
      until replaced or stopped

  Each ear's level is `volume × (1 − distance × attenuation / 1000) × (1 ± d)`, `d` the
  direction to the sound along the listener's right, each bounded to 0 to 1; a sound
  with attenuation 0, or from the listener's own entity (other than 0), is at `volume`
  in both ears, and an unspatialised one at `volume × (1 − distance × attenuation /
  1000)`. The levels become a stage's gain and pan under the constant-power law:
  `gain = √(left² + right²)`, `pan = 4·atan2(right, left)/π − 1`.

  Commands are `{:play, key, name, gain, pan, rate}`, `{:place, key, gain, pan}` when a
  channel's levels change, and `{:stop, key}`; a key is `{:channel, index}`.
  """

  alias Cauldron3D.Vec
  alias QuakeServer.Angles

  @nominal_distance 1000.0
  @force_loop 2
  @unspatialised 4
  @follow 64
  @no_replace 128

  @typedoc "A key for one channel."
  @type key :: {:channel, non_neg_integer()}

  @type command ::
          {:play, key(), String.t(), float(), float(), float()}
          | {:place, key(), float(), float()}
          | {:stop, key()}

  @typedoc "A sound's sample: its length and loop start in seconds, rate and mono 16-bit PCM."
  @type sample :: %{seconds: number(), loop: number() | nil, rate: pos_integer(), pcm: binary()}

  @type samples :: (String.t() -> sample() | nil)

  @type t :: %__MODULE__{channels: %{non_neg_integer() => map()}, listener: map()}

  defstruct channels: %{},
            listener: %{entity: 0, origin: {0.0, 0.0, 0.0}, right: {0.0, -1.0, 0.0}}

  @doc "No channels, the listener at the origin facing along x."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Put the listener, entity `entity`, at `origin` facing `angles` (pitch, yaw, roll in degrees)."
  @spec listen(t(), integer(), Vec.t(), Vec.t()) :: t()
  def listen(%__MODULE__{} = sound, entity, origin, angles) do
    {_forward, right, _up} = Angles.vectors(angles)
    %{sound | listener: %{entity: entity, origin: origin, right: right}}
  end

  @doc "Start `start` at time `now`, as `S_StartSound`."
  @spec start(t(), map(), samples(), number()) :: {t(), [command()]}
  def start(%__MODULE__{} = sound, start, samples, now) do
    if Bitwise.band(Map.get(start, :flags, 0), @no_replace) != 0 and
         playing(sound, start.entity, start.channel, now) != nil,
       do: {sound, []},
       else: put(sound, pick(sound, start.entity, start.channel, now), start, samples, now)
  end

  @doc """
  Change the sound playing on `start`'s entity and channel to `start`, keeping its place
  in the sample, or start it when none plays and `start` names a sound, as
  `S_UpdateSound`. An empty name keeps the playing sound. Returns whether one was
  changed, as 1.0 or 0.0.
  """
  @spec update_sound(t(), map(), samples(), number()) :: {t(), [command()], float()}
  def update_sound(%__MODULE__{} = sound, start, samples, now) do
    case playing(sound, start.entity, start.channel, now) do
      nil when start.name == "" ->
        {sound, [], 0.0}

      nil ->
        {sound, commands} = start(sound, start, samples, now)
        {sound, commands, 0.0}

      index ->
        {sound, commands} = change(sound, index, start, samples)
        {sound, commands, 1.0}
    end
  end

  @doc "Stop what plays on `entity`'s `channel`, or on every channel of `entity` for channel 0, as `S_StopSound`."
  @spec stop(t(), integer(), integer(), number()) :: {t(), [command()]}
  def stop(%__MODULE__{} = sound, entity, 0, now) do
    sound.channels
    |> Enum.filter(fn {_index, held} -> held.entity == entity and not finished?(held, now) end)
    |> Enum.reduce({sound, []}, fn {index, _}, {acc, commands} ->
      {acc, more} = silence(acc, index)
      {acc, commands ++ more}
    end)
  end

  def stop(%__MODULE__{} = sound, entity, channel, now) do
    case playing(sound, entity, channel, now) do
      nil -> {sound, []}
      index -> silence(sound, index)
    end
  end

  @doc "Stop every channel, as `S_StopAllSounds`."
  @spec stop_all(t()) :: {t(), [command()]}
  def stop_all(%__MODULE__{} = sound),
    do:
      {%{sound | channels: %{}},
       sound.channels |> Map.keys() |> Enum.sort() |> Enum.map(&{:stop, key(&1)})}

  @doc "Seconds into the sample of what plays on `entity`'s `channel`, playback rate left out; -1.0 for none (`S_GetSoundTime`)."
  @spec sound_time(t(), integer(), integer(), number()) :: float()
  def sound_time(%__MODULE__{} = sound, entity, channel, now) do
    case playing(sound, entity, channel, now) do
      nil -> -1.0
      index -> position(sound.channels[index], now) / 1
    end
  end

  @doc "The sample's level, 0.0 to 1.0, where what plays on `entity`'s `channel` has got to; -1.0 for none (`S_GetChannelLevel`)."
  @spec level(t(), integer(), integer(), number()) :: float()
  def level(%__MODULE__{} = sound, entity, channel, now) do
    case playing(sound, entity, channel, now) do
      nil -> -1.0
      index -> sample_level(sound.channels[index], now)
    end
  end

  @doc """
  Move each channel started with flag 64 (`CF_FOLLOW`) on an entity below zero to where
  `place` says that entity is now, as `SND_Spatialize` does; one `place` answers `nil`
  for keeps its place.
  """
  @spec follow(t(), (integer() -> Vec.t() | nil)) :: t()
  def follow(%__MODULE__{} = sound, place) do
    channels =
      Map.new(sound.channels, fn
        {index, %{follow?: true, entity: entity} = channel} when entity < 0 ->
          {index, %{channel | origin: place.(entity) || channel.origin}}

        other ->
          other
      end)

    %{sound | channels: channels}
  end

  @doc "Forget finished channels and re-place the rest for the listener, as `S_Update` does each frame."
  @spec update(t(), number()) :: {t(), [command()]}
  def update(%__MODULE__{} = sound, now) do
    live = Map.reject(sound.channels, fn {_index, channel} -> finished?(channel, now) end)

    {channels, commands} =
      Enum.map_reduce(live, [], fn {index, channel}, commands ->
        {gain, pan} = placement(sound.listener, channel)

        if {gain, pan} == {channel.gain, channel.pan},
          do: {{index, channel}, commands},
          else:
            {{index, %{channel | gain: gain, pan: pan}},
             [{:place, key(index), gain, pan} | commands]}
      end)

    {%{sound | channels: Map.new(channels)}, Enum.reverse(commands)}
  end

  defp put(sound, index, start, samples, now) do
    with true <- start.volume >= 0,
         %{} = sample <- samples.(start.name) do
      begin(sound, index, start, sample, now)
    else
      _ -> silence(sound, index)
    end
  end

  defp change(sound, index, start, samples) do
    held = sound.channels[index]
    name = if start.name == "", do: held.name, else: start.name

    with true <- start.volume >= 0,
         %{} = sample <- samples.(name) do
      changed = channel(sound, %{start | name: name}, sample, held.started)
      {gain, pan} = placement(sound.listener, changed)
      changed = %{changed | gain: gain, pan: pan}
      sound = %{sound | channels: Map.put(sound.channels, index, changed)}

      if name == held.name,
        do: {sound, [{:place, key(index), gain, pan}]},
        else: {sound, [{:play, key(index), name, gain, pan, changed.rate}]}
    else
      _ -> silence(sound, index)
    end
  end

  defp playing(sound, entity, channel, now) do
    sound.channels
    |> Enum.sort()
    |> Enum.find_value(fn {index, held} ->
      if held.entity == entity and held.channel == channel and not finished?(held, now),
        do: index
    end)
  end

  defp pick(sound, entity, channel, now) do
    indices = sound.channels |> Map.keys() |> Enum.sort()

    replaced = if channel != 0, do: playing(sound, entity, channel, now)
    free = indices |> Enum.filter(&finished?(sound.channels[&1], now)) |> List.last()
    replaced || free || next_index(indices)
  end

  defp next_index([]), do: 0
  defp next_index(indices), do: List.last(indices) + 1

  defp begin(sound, index, start, sample, now) do
    channel = channel(sound, start, sample, now)
    {gain, pan} = placement(sound.listener, channel)
    channel = %{channel | gain: gain, pan: pan}
    command = {:play, key(index), start.name, gain, pan, channel.rate}
    {%{sound | channels: Map.put(sound.channels, index, channel)}, [command]}
  end

  defp channel(sound, start, sample, started) do
    flags = Map.get(start, :flags, 0)
    rate = if start.pitch > 0, do: start.pitch / 1, else: 1.0
    loop = if Bitwise.band(flags, @force_loop) != 0, do: sample.loop || 0.0, else: sample.loop

    %{
      entity: start.entity,
      channel: start.channel,
      name: start.name,
      origin: start.origin || sound.listener.origin,
      volume: min(max(start.volume / 1, 0.0), 1.0),
      dist_mult: start.attenuation / @nominal_distance,
      unspatialised?: Bitwise.band(flags, @unspatialised) != 0,
      follow?: Bitwise.band(flags, @follow) != 0,
      sample: sample,
      loop: loop,
      rate: rate,
      started: started,
      ends: if(loop, do: :never, else: started + sample.seconds / rate),
      gain: 0.0,
      pan: 0.0
    }
  end

  defp silence(sound, index) do
    case Map.pop(sound.channels, index) do
      {nil, _channels} -> {sound, []}
      {_channel, channels} -> {%{sound | channels: channels}, [{:stop, key(index)}]}
    end
  end

  defp finished?(%{ends: :never}, _now), do: false
  defp finished?(%{ends: ends}, now), do: now >= ends

  defp position(%{loop: nil} = channel, now), do: (now - channel.started) * channel.rate

  defp position(channel, now) do
    at = (now - channel.started) * channel.rate
    length = channel.sample.seconds

    if at < length or length <= channel.loop,
      do: at,
      else: channel.loop + :math.fmod(at - channel.loop, length - channel.loop)
  end

  defp sample_level(channel, now) do
    frame = trunc(position(channel, now) * channel.sample.rate)
    pcm = channel.sample.pcm

    if frame >= 0 and frame * 2 + 2 <= byte_size(pcm) do
      <<value::little-signed-16>> = binary_part(pcm, frame * 2, 2)
      abs(value) / 32_767
    else
      0.0
    end
  end

  defp placement(listener, channel) do
    {left, right} = ears(listener, channel)
    gain = :math.sqrt(left * left + right * right)
    pan = if gain == 0, do: 0.0, else: 4 * :math.atan2(right, left) / :math.pi() - 1
    {Float.round(gain, 3), Float.round(pan, 3)}
  end

  defp ears(%{entity: entity}, %{entity: entity, volume: volume}) when entity != 0,
    do: {volume, volume}

  defp ears(_listener, %{dist_mult: dist_mult, volume: volume}) when dist_mult == 0,
    do: {volume, volume}

  defp ears(listener, %{unspatialised?: true} = channel) do
    level = bounded(channel.volume * falloff(listener, channel))
    {level, level}
  end

  defp ears(listener, channel) do
    offset = Vec.sub(channel.origin, listener.origin)
    distance = Vec.length(offset)
    direction = if distance == 0, do: {0.0, 0.0, 0.0}, else: Vec.scale(offset, 1 / distance)
    falloff = 1.0 - distance * channel.dist_mult
    side = Vec.dot(listener.right, direction)

    {bounded(channel.volume * falloff * (1 - side)),
     bounded(channel.volume * falloff * (1 + side))}
  end

  defp falloff(listener, channel),
    do: 1.0 - Vec.length(Vec.sub(channel.origin, listener.origin)) * channel.dist_mult

  defp bounded(level), do: level |> max(0.0) |> min(1.0)

  defp key(index), do: {:channel, index}
end
