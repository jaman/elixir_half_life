defmodule ElixirHalfLife.Csqc.Parse do
  @moduledoc """
  The server messages a FreeHL server sends, read as FTE's client reads them
  (`CL_ParseServerMessage`) and handed to the client program:

    * the sound message (6) `QuakeServer.Sounds` writes: started on the client's
      channels (`ElixirHalfLife.Csqc.Sounds.start/2`)
    * `svc_print` (8): a level byte and text, gathered line by line; each whole line
      goes to `CSQC_Parse_Print(line, level)` (`CSQC_ParsePrint`)
    * `svc_stufftext` (9): text, gathered line by line; each whole line goes to
      `CSQC_Parse_StuffCmd(line)` with its newline, or to the client's console
    * `svc_centerprint` (26): text for `CSQC_Parse_CenterPrint(text)`
    * `svc_serverinfo` (52): a key and value set in the client's copy of the server's
      info; a stuffed `fullserverinfo "\\key\\value..."` line replaces the whole copy
    * `svcfte_soundlistshort` (56): the first index less one, the server's sound names
      from there to an empty one, and a byte; `svcfte_precache` (77): a sound's or
      particle effect's code and name (`ElixirHalfLife.Csqc.Precaches`)
    * `svcfte_trailparticles` (80), `svcfte_pointparticles` (81) and
      `svcfte_pointparticles1` (82): the server's particle effects
      (`ElixirHalfLife.Csqc.ServerParticles`)
    * `svc_cgamepacket` (83): the rest is read by `CSQC_Parse_Event`, and the messages
      go on from where it stopped reading
    * `svc_spawnstatic` (20) as `QuakeServer.Signon` writes it: an entity made static
      (FTE's `CL_ParseStaticProt`), drawn with the client's own static entities (the
      host's `ext.statics`)
    * `svc_spawnstaticsound` (29) and `svcfte_spawnstaticsound2` (94): a sound of the
      server's sound list looping at a place on its own channel (FTE's
      `CL_ParseStaticSound`, `S_StaticSound`), its volume scaled by the cvar
      `cl_staticsounds` when there is one and left out when that is below 0
    * `svc_updateuserinfo` (40): a player slot's info keys, replacing the client's copy
      (the host's `ext.userinfo`, by entity: the slot plus one)

  A message of another kind ends the reading and is printed as illegible.

      csqc = ElixirHalfLife.Csqc.Parse.messages(bytes, csqc)
  """

  alias ElixirHalfLife.Csqc.{Messages, Precaches, Render, ServerParticles, Sounds}
  alias QuakeServer.{Console, Edicts, Events, Models, Server}
  alias QuakeServer.Extensions.{Settings, Strings}

  @doc "Hand the client program the messages in `bytes`, in order."
  @spec messages(binary(), Server.t()) :: Server.t()
  def messages(<<>>, csqc), do: csqc

  def messages(
        <<6, flags::little-16, entity::little-signed-32, channel::little-16, volume,
          attenuation::little-float-32, pitch::little-float-32, _timeofs::little-float-32,
          x::little-float-32, y::little-float-32, z::little-float-32, rest::binary>>,
        csqc
      ) do
    {name, rest} = string(rest)

    start = %{
      entity: entity,
      channel: channel,
      name: name,
      origin: {x, y, z},
      volume: volume / 255,
      attenuation: attenuation,
      pitch: pitch,
      flags: flags
    }

    messages(rest, Sounds.start(csqc, start))
  end

  def messages(<<8, level, rest::binary>>, csqc) do
    {text, rest} = string(rest)
    messages(rest, print(csqc, text, level))
  end

  def messages(<<9, rest::binary>>, csqc) do
    {text, rest} = string(rest)
    messages(rest, stuff(csqc, text))
  end

  def messages(<<52, rest::binary>>, csqc) do
    {key, rest} = string(rest)
    {value, rest} = string(rest)
    messages(rest, Settings.put_info(csqc, 0, key, value))
  end

  def messages(<<26, rest::binary>>, csqc) do
    {text, rest} = string(rest)
    messages(rest, call(csqc, "CSQC_Parse_CenterPrint", [text]))
  end

  def messages(<<83, rest::binary>> = bytes, csqc) do
    csqc =
      csqc
      |> Messages.start(rest)
      |> Server.set_globals(0, 0)
      |> Server.call_named("CSQC_Parse_Event")

    {_, at} = Map.get(csqc.ext, :message, {rest, byte_size(rest)})
    taken = min(at, byte_size(rest))
    messages(binary_part(bytes, 1 + taken, byte_size(rest) - taken), csqc)
  end

  def messages(<<56, first::little-16, rest::binary>>, csqc) do
    {names, rest} = names(rest, [])

    case rest do
      <<_next, rest::binary>> -> messages(rest, Precaches.put_sounds(csqc, first + 1, names))
      <<>> -> Precaches.put_sounds(csqc, first + 1, names)
    end
  end

  def messages(<<77, code::little-16, rest::binary>>, csqc) do
    {name, rest} = string(rest)
    messages(rest, Precaches.put(csqc, code, name))
  end

  def messages(
        <<80, entity::little-16, effect::little-16, x0::little-float-32, y0::little-float-32,
          z0::little-float-32, x1::little-float-32, y1::little-float-32, z1::little-float-32,
          rest::binary>>,
        csqc
      ),
      do: messages(rest, ServerParticles.trail(csqc, effect, entity, {x0, y0, z0}, {x1, y1, z1}))

  def messages(
        <<81, effect::little-16, x::little-float-32, y::little-float-32, z::little-float-32,
          dx::little-float-32, dy::little-float-32, dz::little-float-32, count::little-16,
          rest::binary>>,
        csqc
      ),
      do: messages(rest, ServerParticles.point(csqc, effect, {x, y, z}, {dx, dy, dz}, count))

  def messages(
        <<82, effect::little-16, x::little-float-32, y::little-float-32, z::little-float-32,
          rest::binary>>,
        csqc
      ),
      do: messages(rest, ServerParticles.point(csqc, effect, {x, y, z}, {0.0, 0.0, 0.0}, 1))

  def messages(
        <<20, model::little-16, frame, _colormap, skin, x::little-float-32,
          pitch::little-signed-16, y::little-float-32, yaw::little-signed-16, z::little-float-32,
          roll::little-signed-16, rest::binary>>,
        csqc
      ) do
    angles = {angle(pitch), angle(yaw), angle(roll)}
    messages(rest, spawn_static(csqc, model, frame, skin, {x, y, z}, angles))
  end

  def messages(
        <<29, x::little-float-32, y::little-float-32, z::little-float-32, sound, volume,
          attenuation, rest::binary>>,
        csqc
      ),
      do: messages(rest, static_sound(csqc, sound, {x, y, z}, volume, attenuation))

  def messages(
        <<94, 1, x::little-float-32, y::little-float-32, z::little-float-32, sound::little-16,
          volume, attenuation, rest::binary>>,
        csqc
      ),
      do: messages(rest, static_sound(csqc, sound, {x, y, z}, volume, attenuation))

  def messages(<<40, slot, _userid::little-32, rest::binary>>, csqc) do
    {info, rest} = string(rest)
    userinfo = csqc.ext |> Map.get(:userinfo, %{}) |> Map.put(slot + 1, info_pairs(info))
    messages(rest, %{csqc | ext: Map.put(csqc.ext, :userinfo, userinfo)})
  end

  def messages(<<svc, _rest::binary>>, csqc),
    do: Events.print(csqc, :notify, "Illegible server message #{svc}\n")

  defp angle(value), do: value * 360 / 65_536

  defp spawn_static(csqc, model, frame, skin, origin, angles) do
    {csqc, entity} = Edicts.alloc(csqc)

    csqc =
      csqc
      |> Edicts.put(entity, "modelindex", model / 1)
      |> Edicts.put(entity, "model", Models.name(csqc, model))
      |> Edicts.put(entity, "frame", frame / 1)
      |> Edicts.put(entity, "skin", skin / 1)
      |> Edicts.put(entity, "origin", origin)
      |> Edicts.put(entity, "angles", angles)

    csqc =
      case Render.snapshot(csqc, entity, nil) do
        nil -> csqc
        thing -> %{csqc | ext: Map.update(csqc.ext, :statics, [thing], &[thing | &1])}
      end

    Edicts.free(csqc, entity)
  end

  defp static_sound(csqc, sound, origin, volume, attenuation) do
    scale =
      if Server.cvar?(csqc, "cl_staticsounds"),
        do: Server.cvar(csqc, "cl_staticsounds"),
        else: 1.0

    volume = volume / 255 * scale

    if volume < 0 do
      csqc
    else
      Sounds.start(csqc, %{
        entity: 0,
        channel: 0,
        name: Precaches.sound(csqc, sound),
        origin: origin,
        volume: volume,
        attenuation: attenuation / 64,
        pitch: 0.0,
        flags: 2
      })
    end
  end

  defp print(csqc, text, level) do
    if defined?(csqc, "CSQC_Parse_Print") do
      {lines, held} = lines(Map.get(csqc.ext, :print_buffer, "") <> text)
      csqc = %{csqc | ext: Map.put(csqc.ext, :print_buffer, held)}
      Enum.reduce(lines, csqc, &call(&2, "CSQC_Parse_Print", [&1, level / 1]))
    else
      Events.print(csqc, :notify, text)
    end
  end

  defp stuff(csqc, text) do
    {lines, held} = lines(Map.get(csqc.ext, :stuff_buffer, "") <> text)
    csqc = %{csqc | ext: Map.put(csqc.ext, :stuff_buffer, held)}

    Enum.reduce(lines, csqc, &stuffed/2)
  end

  defp stuffed("fullserverinfo " <> _ = line, csqc), do: full_serverinfo(csqc, line)
  defp stuffed("//fullserverinfo " <> _ = line, csqc), do: full_serverinfo(csqc, line)

  defp stuffed(line, csqc) do
    if defined?(csqc, "CSQC_Parse_StuffCmd"),
      do: call(csqc, "CSQC_Parse_StuffCmd", [line]),
      else: Console.run(csqc, line, from: :server)
  end

  defp full_serverinfo(csqc, line) do
    case line |> String.trim() |> Strings.tokenize_console() |> Enum.map(&elem(&1, 0)) do
      [_, info | _] -> %{csqc | ext: Map.put(csqc.ext, :serverinfo, info_pairs(info))}
      _ -> csqc
    end
  end

  defp info_pairs(info) do
    info
    |> String.trim_leading("\\")
    |> String.split("\\")
    |> Enum.chunk_every(2, 2, :discard)
    |> Map.new(fn [key, value] -> {key, value} end)
  end

  defp lines(text) do
    parts = String.split(text, "\n")
    {whole, [held]} = Enum.split(parts, -1)
    {Enum.map(whole, &(&1 <> "\n")), held}
  end

  defp names(bytes, acc) do
    case string(bytes) do
      {"", rest} -> {Enum.reverse(acc), rest}
      {name, rest} -> names(rest, [name | acc])
    end
  end

  defp string(bytes) do
    case :binary.split(bytes, <<0>>) do
      [text, rest] -> {text, rest}
      [text] -> {text, <<>>}
    end
  end

  defp defined?(csqc, name), do: QuakeC.Progs.function(csqc.qc.progs, name) != nil

  defp call(csqc, name, args) do
    if defined?(csqc, name) do
      qc =
        args
        |> Enum.with_index()
        |> Enum.reduce(csqc.qc, fn {value, i}, qc -> QuakeC.put_slot(qc, 4 + 3 * i, value) end)

      %{csqc | qc: qc} |> Server.set_globals(0, 0) |> Server.call_named(name)
    else
      csqc
    end
  end
end
