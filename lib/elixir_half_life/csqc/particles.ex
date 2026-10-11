defmodule ElixirHalfLife.Csqc.Particles do
  @moduledoc """
  FTE's scripted particle effects for the client program, kept in the host's
  `ext.particles`.

      s = ElixirHalfLife.Csqc.Particles.point(s, "fx_impact.main", origin, normal, 1.0)
      s = ElixirHalfLife.Csqc.Particles.trail(s, "weapon_rpg.trail", entity, from, to)
      s = ElixirHalfLife.Csqc.Particles.decal(s, "decal_{shot1", origin, up, side, {1.0, 1.0, 1.0}, 1.0)
      s = ElixirHalfLife.Csqc.Particles.advance(s)
      ElixirHalfLife.Csqc.Particles.polygons(s, view)
      ElixirHalfLife.Csqc.Particles.lights(s)

  An effect is named `config.effect`, its config read from `particles/<config>.cfg` the
  first time it is named (`ElixirHalfLife.Csqc.Particles.Script`); an effect runs every
  effect chained after it. Particles spawn by the effect's spawn mode, move by their
  velocity, gravity and friction, change colour, alpha and size by their deltas or
  ramp, turn, spawn their emitted effect, bounce off or burst against the world by their
  clip type, and die after their life; beams join the particles one trail call left;
  `cdecal` effects cut their picture onto the world's faces
  (`ElixirHalfLife.Csqc.Particles.Decals`); `model` lines spawn animated sprites; light
  fields make lights that shrink and fade.

  Particles move in `advance/1`, run once a frame before drawing. Marks from `decal/7`
  belong to the frame they are made in and are cleared by `clear_scene/1`.

  The world is the only thing particles collide with.
  """

  alias Cauldron3D.Formats.Spr
  alias Cauldron3D.{Polygon, Vec}
  alias ElixirHalfLife.Assets
  alias ElixirHalfLife.Csqc.Particles.{Decals, Looks, Script}
  alias ElixirHalfLife.Csqc.Sprites

  @pi :math.pi()

  @decal_probes [
    {-16.0, 0.0, 0.0},
    {0.0, -16.0, 0.0},
    {0.0, 0.0, -16.0},
    {16.0, 0.0, 0.0},
    {0.0, 16.0, 0.0},
    {0.0, 0.0, 16.0}
  ]

  @doc "Run effect `name` at `origin` toward `direction` (zero for none), `count` times as many."
  @spec point(map(), String.t(), Vec.t(), Vec.t(), number()) :: map()
  def point(s, name, origin, direction, count) do
    {state, key} = state(s) |> resolve(name)
    state = if key, do: run_effect(state, s, key, origin, direction, count / 1, nil), else: state
    put(s, state)
  end

  @doc """
  Run trail effect `name` from `from` to `to` for client entity `entity` (0 for none),
  covering the frame's time; an entity's trails carry their spacing and beams from call
  to call.
  """
  @spec trail(map(), String.t(), non_neg_integer(), Vec.t(), Vec.t()) :: map()
  def trail(s, name, entity, from, to) do
    {state, key} = state(s) |> resolve(name)
    interval = frame_time(s)
    owner = if entity == 0, do: nil, else: {:entity, entity}
    state = if key, do: run_trail(state, s, key, from, to, interval, owner, 0), else: state
    put(s, state)
  end

  @doc """
  Lay shader `shader`'s picture on the world's faces at `origin` for this frame: `up` out
  of the surface (its length the depth), `side` across (its length the size), tinted
  `rgb` at `alpha`.
  """
  @spec decal(map(), String.t(), Vec.t(), Vec.t(), Vec.t(), Vec.t(), number()) :: map()
  def decal(s, shader, origin, up, side, rgb, alpha) do
    looks = decal_looks(s, shader)

    case looks.texture do
      nil ->
        s

      texture ->
        {r, g, b} = rgb
        normal = Vec.normalize(up)

        polygons =
          for corners <- Decals.project(s.bsp, origin, up, side) do
            {looks.sort,
             %Polygon{
               points: Enum.map(corners, fn {p, _, _} -> Vec.madd(p, normal, 0.25) end),
               uvs:
                 Enum.map(corners, fn {_, {u, v}, _} ->
                   {u * texture.width, v * texture.height}
                 end),
               tints:
                 Enum.map(corners, fn {_, _, fade} ->
                   if looks.tinted?, do: {r, g, b, alpha * fade}, else: {1.0, 1.0, 1.0, 1.0}
                 end),
               paint: {:texture, texture, nil},
               blend: looks.blend
             }}
          end

        state = state(s)
        put(s, %{state | frame_decals: state.frame_decals ++ polygons})
    end
  end

  @doc "Forget the marks `decal/7` made this frame."
  @spec clear_scene(map()) :: map()
  def clear_scene(s) do
    state = state(s)
    put(s, %{state | frame_decals: []})
  end

  @doc """
  Move everything on to the program's time now: particles, beams, marks, sprites and
  lights live or die, move and change as FTE runs them each frame.
  """
  @spec advance(map()) :: map()
  def advance(s) do
    state = state(s)
    now = clock(s)
    frametime = max(now - (state.last || now), 0.0)
    flurry_time = Map.get(state, :flurry_time, 0.0) - frametime

    {flurry?, flurry_time} =
      if flurry_time < 0, do: {true, 0.1 + random() * 0.3}, else: {false, flurry_time}

    state = Map.merge(state, %{last: now, shown: %{}, flurry?: flurry?, flurry_time: flurry_time})
    state = run_types(state, s, frametime)
    state = run_sprites(state, s, frametime)
    state = decay_lights(state, now, frametime)
    put(s, %{state | time: state.time + frametime})
  end

  @doc "Every particle, beam, mark and sprite as `{shader sort, polygon}` seen by `view`."
  @spec polygons(map(), Cauldron3D.View.t()) :: [{non_neg_integer(), Polygon.t()}]
  def polygons(s, view) do
    state = state(s)

    types =
      state.order
      |> Enum.flat_map(fn key -> type_polygons(state, key, view) end)

    state.frame_decals ++ types ++ sprite_polygons(state, view)
  end

  @doc "The lights the effects give now, `%{origin:, radius:, colour:}`."
  @spec lights(map()) :: [map()]
  def lights(s) do
    for light <- state(s).lights,
        light.radius > 0,
        do: %{origin: light.origin, radius: light.radius, colour: light.colour}
  end

  defp state(s) do
    Map.get(s.ext, :particles) ||
      %{
        time: clock(s),
        last: nil,
        types: %{},
        configs: MapSet.new(),
        live: %{},
        beams: %{},
        decals: %{},
        order: [],
        sprites: [],
        lights: [],
        trails: %{},
        overflow: %{},
        next: 1,
        frame_decals: []
      }
  end

  defp put(s, state), do: %{s | ext: Map.put(s.ext, :particles, state)}

  defp clock(s), do: QuakeC.float(QuakeC.global(s.qc, "time"))

  defp frame_time(s) do
    name = if QuakeC.global?(s.qc, "clframetime"), do: "clframetime", else: "frametime"
    QuakeC.float(QuakeC.global(s.qc, name))
  end

  defp resolve(state, name) do
    {config, effect} =
      case String.split(name, ".", parts: 2) do
        [config, effect] -> {config, effect}
        [effect] -> {"", effect}
      end

    state = load(state, config)

    key = effect_key(state.types, config, effect)

    case Map.get(state.types, key) do
      %{loaded: true} -> {state, key}
      _ -> {state, nil}
    end
  end

  defp effect_key(types, "", effect), do: Enum.find_value(types, &loaded_key(&1, effect))
  defp effect_key(_types, config, effect), do: {config, effect}

  defp loaded_key({{_, effect} = key, %{loaded: true}}, effect), do: key
  defp loaded_key(_entry, _effect), do: nil

  defp load(state, ""), do: state

  defp load(state, config) do
    if MapSet.member?(state.configs, config) do
      state
    else
      text = Assets.read("particles/#{config}.cfg") || ""
      types = Script.parse(text, config, state.types)
      %{state | types: types, configs: MapSet.put(state.configs, config)}
    end
  end

  defp type_of(state, nil), do: {state, nil}

  defp type_of(state, {config, _} = key) do
    state = load(state, config)

    case Map.get(state.types, key) do
      %{loaded: true} = ptype ->
        looks = Looks.looks(ptype)
        {state, Map.merge(ptype, Map.take(looks, [:s1, :t1, :s2, :t2, :randsmax]))}

      other ->
        {state, other}
    end
  end

  defp random, do: :rand.uniform()
  defp crandom, do: :rand.uniform() * 2 - 1
  defp hrandom, do: :rand.uniform() - 0.5

  defp run_effect(state, s, key, org, dir, count, owner) do
    run_chain(state, s, key, org, dir, count, owner, 0)
  end

  defp run_chain(state, _s, nil, _org, _dir, _count, _owner, _depth), do: state

  defp run_chain(state, s, key, org, dir, count, owner, depth) do
    {state, ptype} = type_of(state, key)

    case ptype do
      %{loaded: true} ->
        ts_key = if owner && not MapSet.member?(ptype.flags, :nostate), do: {owner, depth}
        axis = axis_for(dir)
        state = spawned(state, ptype, org, clock(s))

        {state, go_on?} =
          if ptype.type == :cdecal,
            do: {spawn_decals(state, s, key, ptype, org, dir), true},
            else: spawn_points(state, s, key, ptype, {org, dir, axis}, count, ts_key)

        if go_on?,
          do: run_chain(state, s, ptype.assoc, org, dir, count, owner, depth + 1),
          else: state

      _ ->
        state
    end
  end

  defp axis_for({x, y, z} = dir) when x != 0 or y != 0 or z != 0 do
    up = Vec.normalize(dir)
    right = up |> perpendicular() |> Vec.normalize()
    {right, up |> cross(right) |> Vec.normalize(), up}
  end

  defp axis_for(_dir), do: {{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, -1.0}}

  defp perpendicular(src) do
    {pos, _} =
      Enum.reduce(0..2, {0, 1.0}, fn i, {pos, least} ->
        value = abs(elem(src, i))
        if value < least, do: {i, value}, else: {pos, least}
      end)

    axis = put_elem({0.0, 0.0, 0.0}, pos, 1.0)
    inv = 1 / Vec.dot(src, src)
    d = Vec.dot(src, axis) * inv
    axis |> Vec.sub(Vec.scale(src, d * inv)) |> Vec.normalize()
  end

  defp cross({ax, ay, az}, {bx, by, bz}),
    do: {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}

  defp spawned(state, ptype, org, now) do
    {r0, r1} = ptype.dl_radius

    if r0 != 0 or r1 != 0 do
      {dr, dg, db, dradius} = ptype.dl_decay

      light = %{
        origin: org,
        radius: r0 + 0.5 * r1,
        die: now + ptype.dl_time,
        colour: ptype.dl_rgb,
        fade: {dr, dg, db},
        decay: dradius
      }

      %{state | lights: [light | state.lights]}
    else
      state
    end
  end

  defp spawn_points(state, s, key, ptype, placement, count, ts_key) do
    trailstate = ts_key && Map.get(state.trails, ts_key, new_trailstate())
    pcount = ptype.countextra + count * (ptype.count + ptype.countrand * random())
    pcount = per_frame_count(ptype, pcount, s)
    pcount = if trailstate, do: pcount + trailstate.emittime, else: pcount
    emitter = {ts_key, trailstate}

    cond do
      ptype.spawnchance < random() ->
        {state, false}

      ptype.models != [] ->
        {spawn_model_points(state, s, ptype, placement, {count, pcount}, emitter), true}

      true ->
        {spawn_particle_points(state, s, key, ptype, placement, pcount, emitter), true}
    end
  end

  defp per_frame_count(ptype, pcount, s) do
    if MapSet.member?(ptype.flags, :invframetime),
      do: pcount / max(frame_time(s), 0.001),
      else: pcount
  end

  defp spawn_model_points(state, s, ptype, placement, {count, pcount}, {ts_key, trailstate}) do
    pcount =
      if ptype.count == 0 and ptype.countrand == 0 and ptype.countextra == 0,
        do: count,
        else: pcount

    total = loop_count(pcount)
    state = spawn_models(state, s, ptype, placement, total, count)
    save_emit(state, ts_key, trailstate, pcount - total)
  end

  defp spawn_particle_points(state, s, key, ptype, placement, pcount, {ts_key, trailstate}) do
    {org, dir, axis} = placement

    pcount =
      if ptype.die == 0 and ptype.count == 1 and ptype.countrand == 0 and pcount < 1,
        do: 1.0,
        else: pcount

    spawn_count = loop_count(pcount)
    {state, ids} = spawn_particles(state, s, key, ptype, org, dir, axis, spawn_count)

    state =
      if ptype.type == :beam and ids != [], do: add_chain(state, key, ids, nil), else: state

    state = mark_running(state, key)
    save_emit(state, ts_key, trailstate, pcount - spawn_count)
  end

  defp loop_count(count) when count > 0, do: trunc(Float.ceil(count))
  defp loop_count(_count), do: 0

  defp new_trailstate,
    do: %{emittime: 0.0, statetime: 0.0, laststop: 0.0, lastdist: 0.0, chain: nil}

  defp save_emit(state, nil, _trailstate, _left), do: state

  defp save_emit(state, key, trailstate, left),
    do: %{state | trails: Map.put(state.trails, key, %{trailstate | emittime: left})}

  defp mark_running(state, key) do
    if key in state.order, do: state, else: %{state | order: [key | state.order]}
  end

  defp spawn_particles(state, s, key, ptype, org, dir, axis, total) do
    loop = spawn_loop_start(ptype, total)
    veladd_scale = Vec.length(dir)
    time = state.time

    {particles, {state, _loop}} =
      Enum.map_reduce(0..(total - 1)//1, {state, loop}, fn i, {acc, loop} ->
        {id, acc} = next_id(acc)
        base = new_particle(ptype, time, s)
        {ofs, ars, loop} = spawn_offsets(ptype, i, loop, clock(s))
        orgadd = ptype.orgadd + random() * ptype.randomorgadd
        veladd = (ptype.veladd + random() * ptype.randomveladd) * veladd_scale
        {a0, a1, a2} = axis
        {ox, oy, oz} = ofs
        {rx, ry, rz} = ars

        vel =
          {0.0, 0.0, 0.0}
          |> Vec.madd(a0, ox * ptype.spawnvel)
          |> Vec.madd(a1, oy * ptype.spawnvel)
          |> Vec.madd(a2, veladd + oz * ptype.spawnvelvert)

        pos = org |> Vec.madd(a0, rx) |> Vec.madd(a1, ry) |> Vec.madd(a2, orgadd + rz)
        {pos, vel} = world_spread(ptype, pos, vel)
        pos = Vec.add(pos, ptype.orgbias)

        particle = %{
          base
          | id: id,
            org: pos,
            oldorg: pos,
            vel: vel,
            die: time + ptype.die - base.die
        }

        {particle, {acc, loop}}
      end)

    live = Map.update(state.live, key, particles, &(Enum.reverse(particles) ++ &1))
    {%{state | live: live}, Enum.map(particles, & &1.id)}
  end

  defp next_id(state), do: {state.next, %{state | next: state.next + 1}}

  defp new_particle(ptype, time, _s) do
    die = ptype.randdie * random()
    alpha = if ptype.die != 0, do: ptype.alpha + die * ptype.alphachange, else: ptype.alpha
    alpha = alpha + ptype.alpharand * random()
    {r, g, b} = ptype.rgb
    {sr, sg, sb} = ptype.rgbrandsync
    {rr, rg, rb} = ptype.rgbrand
    {cr, cg, cb} = ptype.rgbchange
    base = random()
    vr = base * sr + random() * (1 - sr)
    vg = base * sg + random() * (1 - sg)
    vb = base * sb + random() * (1 - sb)

    offset =
      if ptype.randsmax != 1,
        do: ptype.texsstride * :rand.uniform(ptype.randsmax) - ptype.texsstride,
        else: 0.0

    %{
      id: 0,
      org: {0.0, 0.0, 0.0},
      oldorg: {0.0, 0.0, 0.0},
      vel: {0.0, 0.0, 0.0},
      die: die,
      scale: ptype.scale + ptype.scalerand * random(),
      rgba: {r + vr * rr + cr * die, g + vg * rg + cg * die, b + vb * rb + cb * die, alpha},
      nextemit: time + ptype.emitstart - die,
      rotationspeed: ptype.rotationmin + random() * ptype.rotationrand,
      angle: ptype.rotationstartmin + random() * ptype.rotationstartrand,
      s1: ptype.s1 + offset,
      t1: ptype.t1,
      s2: ptype.s2 + offset,
      t2: ptype.t2
    }
  end

  defp spawn_loop_start(%{spawnmode: :unicircle} = ptype, total) do
    %{m: unicircle_step(ptype, total), j: 0.0, k: 0.0, l: 0.0, spc: 8}
  end

  defp spawn_loop_start(%{spawnmode: mode} = ptype, _total)
       when mode in [:telebox, :lavasplash] do
    %{
      m: grid_jitter(ptype),
      j: -ptype.areaspread,
      k: -ptype.areaspread,
      l: grid_start_height(ptype),
      spc: grid_spacing(ptype)
    }
  end

  defp spawn_loop_start(_ptype, _total), do: %{m: 0.0, j: 0.0, k: 0.0, l: 0.0, spc: 8}

  defp unicircle_step(ptype, total) do
    points = if ptype.type == :beam, do: total - 1, else: total
    step = if points < 1, do: 0.0, else: 2 * @pi / points
    if ptype.spawnparam1 != 0, do: step * ptype.spawnparam1, else: step
  end

  defp grid_spacing(%{spawnparam2: spacing}) when spacing != 0, do: trunc(spacing)
  defp grid_spacing(%{spawnmode: :telebox}), do: 4
  defp grid_spacing(_ptype), do: 8

  defp grid_start_height(%{spawnmode: :telebox} = ptype), do: -ptype.areaspreadvert
  defp grid_start_height(_ptype), do: 0.0

  defp grid_jitter(%{spawnparam1: jitter}) when jitter != 0, do: jitter
  defp grid_jitter(_ptype), do: 0.55752

  defp spawn_offsets(%{spawnmode: :box} = p, _i, loop, _t) do
    ofs = {crandom(), crandom(), crandom()}
    {x, y, z} = ofs
    {ofs, {x * p.areaspread, y * p.areaspread, z * p.areaspreadvert}, loop}
  end

  defp spawn_offsets(%{spawnmode: :telebox} = p, _i, loop, _t) do
    %{j: j, k: k, l: l, m: m, spc: spc} = loop
    ofs = {k, j, l + 4} |> Vec.normalize() |> Vec.scale(1.0 - random() * m)
    ars = {j + :rand.uniform(spc) - 1, k + :rand.uniform(spc) - 1, l + :rand.uniform(spc) - 1}
    {ofs, ars, advance_telebox(p, loop)}
  end

  defp spawn_offsets(%{spawnmode: :lavasplash} = p, _i, loop, _t) do
    %{j: j, k: k, m: m, spc: spc} = loop
    raw = {k + :rand.uniform(spc) - 1, j + :rand.uniform(spc) - 1, 256.0}
    {rx, ry, _} = raw
    ars = {rx, ry, random() * p.areaspreadvert}
    ofs = raw |> Vec.normalize() |> Vec.scale(1.0 - random() * m)
    j = j + spc

    {j, k} =
      if j >= p.areaspread, do: {-p.areaspread, next_wrap(k + spc, p.areaspread)}, else: {j, k}

    {ofs, ars, %{loop | j: j, k: k}}
  end

  defp spawn_offsets(%{spawnmode: :unicircle} = p, i, loop, _t) do
    ofs = {:math.cos(loop.m * i), :math.sin(loop.m * i), 0.0}
    {ofs, Vec.scale(ofs, p.areaspread), loop}
  end

  defp spawn_offsets(%{spawnmode: :distball} = p, _i, loop, _t) do
    rdist = p.spawnparam2 - crandom() * (1 - crandom() * p.spawnparam1)
    raw = {hrandom(), hrandom(), if(p.areaspreadvert != 0, do: hrandom(), else: 0.0)}
    {x, y, z} = ofs = raw |> Vec.normalize() |> Vec.scale(rdist)
    {ofs, {x * p.areaspread, y * p.areaspread, z * p.areaspreadvert}, loop}
  end

  defp spawn_offsets(p, _i, loop, _t) do
    raw = {hrandom(), hrandom(), if(p.areaspreadvert != 0, do: hrandom(), else: 0.0)}
    ofs = Vec.normalize(raw)
    {x, y, z} = ofs = if p.spawnmode == :circle, do: ofs, else: Vec.scale(ofs, random())
    {ofs, {x * p.areaspread, y * p.areaspread, z * p.areaspreadvert}, loop}
  end

  defp advance_telebox(p, %{j: j, spc: spc} = loop), do: next_column(p, %{loop | j: j + spc})

  defp next_column(%{areaspread: spread}, %{j: j} = loop) when j < spread, do: loop

  defp next_column(p, %{k: k, spc: spc} = loop),
    do: next_row(p, %{loop | j: -p.areaspread, k: k + spc})

  defp next_row(%{areaspread: spread}, %{k: k} = loop) when k < spread, do: loop

  defp next_row(p, %{l: l, spc: spc} = loop),
    do: %{loop | k: -p.areaspread, l: next_wrap(l + spc, p.areaspreadvert)}

  defp next_wrap(value, limit), do: if(value >= limit, do: -limit, else: value)

  defp world_spread(ptype, pos, vel) do
    if MapSet.member?(ptype.flags, :worldspacerand) do
      {x, y, z} = unit_ball()
      {wx, wy, wz} = ptype.orgwrand
      {vx, vy, vz} = ptype.velwrand
      pos = Vec.add(pos, {x * wx, y * wy, z * wz})
      vel = vel |> Vec.add({x * vx, y * vy, z * vz}) |> Vec.add(ptype.velbias)
      {pos, vel}
    else
      {pos, vel}
    end
  end

  defp unit_ball do
    v = {crandom(), crandom(), crandom()}
    if Vec.dot(v, v) > 1, do: unit_ball(), else: v
  end

  defp spawn_models(state, s, ptype, {org, _dir, axis}, total, count) do
    Enum.reduce(0..(total - 1)//1, state, fn index, acc ->
      mod = Enum.at(ptype.models, :rand.uniform(length(ptype.models)) - 1)
      add_model_sprite(acc, s, ptype, {org, axis}, {mod, sprite_model(mod.name)}, {index, count})
    end)
  end

  defp add_model_sprite(state, _s, _ptype, _placement, {_mod, nil}, _index), do: state

  defp add_model_sprite(state, s, ptype, {org, axis}, {mod, sprite}, {index, count}) do
    scale = random() * (mod.scalemax - mod.scalemin) + mod.scalemin
    loop = spawn_loop_start(ptype, trunc(count))
    {ofs, ars, _} = spawn_offsets(ptype, index, loop, clock(s))
    {a0, a1, a2} = axis
    orgadd = ptype.orgadd + random() * ptype.randomorgadd
    veladd = ptype.veladd + random() * ptype.randomveladd
    {ox, oy, oz} = ofs
    {rx, ry, rz} = ars

    vel =
      {0.0, 0.0, 0.0}
      |> Vec.madd(a0, ox * ptype.spawnvel)
      |> Vec.madd(a1, oy * ptype.spawnvel)
      |> Vec.madd(a2, veladd + oz * ptype.spawnvelvert)

    pos = org |> Vec.madd(a0, rx) |> Vec.madd(a1, ry) |> Vec.madd(a2, orgadd + rz)
    {pos, vel} = world_spread(ptype, pos, vel)
    pos = Vec.add(pos, ptype.orgbias)
    up = if MapSet.member?(mod.flags, :orient), do: a2
    effect = sprite_effect(mod, sprite, pos, vel, up, scale, ptype, clock(s))
    %{state | sprites: [effect | state.sprites]}
  end

  defp sprite_model(name) do
    with data when is_binary(data) <- Assets.read(name),
         {:ok, %Spr{} = sprite} <- Spr.parse(data) do
      {name, sprite}
    else
      _ -> nil
    end
  end

  defp sprite_effect(mod, {name, sprite}, pos, vel, up, scale, ptype, now) do
    alpha = if mod.alpha != 0, do: mod.alpha, else: 1.0
    spin = ptype.rotationmin * 180 / @pi

    {angles, avel} =
      if spin != 0,
        do:
          {{random() * 360, random() * 360, random() * 360},
           {crandom() * spin, crandom() * spin, crandom() * spin}},
        else: {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}}

    angles = if up, do: orientation(up, angles), else: angles

    %{
      name: name,
      sprite: sprite,
      start: now,
      origin: pos,
      oldorigin: pos,
      velocity: vel,
      angles: angles,
      avel: avel,
      firstframe: trunc(mod.framestart),
      numframes: trunc(mod.framecount),
      framerate: if(mod.framerate != 0, do: mod.framerate, else: 10.0),
      startalpha: abs(alpha),
      endalpha: abs(alpha),
      scale: scale,
      gravity: ptype.gravity,
      rgb: mod.rgb,
      flags: mod.flags,
      trail: mod.trail,
      shown: nil
    }
  end

  defp orientation({x, y, z}, {_, _, roll}) do
    pitch = :math.acos(z) / @pi * 180

    yaw =
      cond do
        x != 0 -> :math.atan2(y, x) / @pi * 180
        y > 0 -> 90.0
        y < 0 -> 270.0
        true -> 0.0
      end

    {pitch, yaw, roll}
  end

  defp spawn_decals(state, s, key, ptype, org, dir) do
    {center, dir} = decal_center(s, org, dir)
    dir = if dir == {0.0, 0.0, 0.0}, do: Vec.normalize({0.0, 0.73, 0.73}), else: dir
    normal = dir |> Vec.scale(-1.0) |> Vec.normalize()
    vec = Vec.normalize({0.5, 0.5, 0.5})
    tangent1 = cross(normal, vec)
    tangent2 = rotate(tangent1, normal, random() * 360)
    tangent1 = cross(normal, tangent2) |> Vec.normalize()
    tangent2 = Vec.normalize(tangent2)
    looks = Looks.looks(ptype)
    scale1 = looks.s2 - looks.s1
    bias1 = looks.s1 + scale1 / 2
    scale2 = looks.t2 - looks.t1
    bias2 = looks.t1 + scale2 / 2
    m = ptype.scale + random() * ptype.scalerand

    bias1 =
      if looks.randsmax != 1,
        do: bias1 + ptype.texsstride * (:rand.uniform(looks.randsmax) - 1),
        else: bias1

    context = %{
      center: center,
      tangent1: tangent1,
      tangent2: tangent2,
      scale1: scale1 / m,
      scale2: scale2 / m,
      bias1: bias1,
      bias2: bias2,
      normal: normal
    }

    triangles = Decals.clip(s.bsp, center, normal, tangent2, tangent1, m)
    decals = Enum.map(triangles, &clipped_decal(&1, context, ptype, state.time))
    state = %{state | decals: Map.update(state.decals, key, decals, &(decals ++ &1))}
    mark_running(state, key)
  end

  defp decal_center(s, org, {x, y, z} = dir) when x != 0 or y != 0 or z != 0 do
    trace = world_trace(s, Vec.madd(org, dir, 16.0), Vec.madd(org, dir, -16.0))
    {trace.end_pos, dir}
  end

  defp decal_center(s, org, _dir) do
    best = {1.0, Vec.normalize({0.0, 0.73, 0.73}), org}

    {_, normal, center} =
      Enum.reduce(@decal_probes, best, fn offset, {best_frac, _, _} = acc ->
        trace = world_trace(s, Vec.sub(org, offset), Vec.add(org, offset))

        if best_frac > trace.fraction,
          do: {trace.fraction, trace.normal, trace.end_pos},
          else: acc
      end)

    {center, normal}
  end

  defp rotate(v, axis, degrees) do
    angle = degrees * @pi / 180
    {c, s} = {:math.cos(angle), :math.sin(angle)}
    k = Vec.normalize(axis)

    v
    |> Vec.scale(c)
    |> Vec.add(Vec.scale(cross(k, v), s))
    |> Vec.add(Vec.scale(k, Vec.dot(k, v) * (1 - c)))
  end

  defp clipped_decal({a, b, c}, context, ptype, time) do
    die = ptype.randdie * random()
    alpha = if ptype.die != 0, do: ptype.alpha + die * ptype.alphachange, else: ptype.alpha
    alpha = alpha + ptype.alpharand * random()
    {r, g, bl} = ptype.rgb
    {sr, sg, sb} = ptype.rgbrandsync
    {rr, rg, rb} = ptype.rgbrand
    {cr, cg, cb} = ptype.rgbchange
    base = random()
    vr = base * sr + random() * (1 - sr)
    vg = base * sg + random() * (1 - sg)
    vb = base * sb + random() * (1 - sb)

    corners =
      for point <- [a, b, c] do
        vec = Vec.sub(point, context.center)
        s = Vec.dot(vec, context.tangent1) * context.scale1 + context.bias1
        t = Vec.dot(vec, context.tangent2) * context.scale2 + context.bias2
        {point, {s, t}, 1.0}
      end

    die_at = time + ptype.die - die
    die_at = if ptype.type != :cdecal, do: die_at + 20, else: die_at

    %{
      corners: corners,
      normal: context.normal,
      die: die_at,
      rgba: {r + vr * rr + cr * die, g + vg * rg + cg * die, bl + vb * rb + cb * die, alpha}
    }
  end

  defp run_trail(state, _s, nil, _from, _to, _interval, _owner, _depth), do: state

  defp run_trail(state, s, key, from, to, interval, owner, depth) do
    {state, ptype} = type_of(state, key)

    case ptype do
      %{loaded: true} ->
        state = spawned(state, ptype, from, clock(s))
        state = run_trail(state, s, ptype.assoc, from, to, interval, owner, depth + 1)
        trail_spawn(state, s, key, ptype, {from, to, interval}, owner && {owner, depth})

      _ ->
        state
    end
  end

  defp trail_spawn(state, s, key, ptype, path, ts_key) do
    ts_key = if MapSet.member?(ptype.flags, :nostate), do: nil, else: ts_key
    trailstate = ts_key && Map.get(state.trails, ts_key, new_trailstate())
    {skip?, trailstate, state} = spawn_timer(state, ptype, trailstate, ts_key)

    cond do
      skip? ->
        state

      ptype.models != [] ->
        state

      ptype.spawnchance < random() ->
        state

      true ->
        emitter = {emitting_trailstate(ptype, trailstate), ts_key}
        trail_particles(state, s, key, ptype, path, emitter)
    end
  end

  defp spawn_timer(state, _ptype, nil, _ts_key), do: {false, nil, state}

  defp spawn_timer(state, %{spawntime: spawntime}, trailstate, _ts_key) when spawntime == 0,
    do: {false, trailstate, state}

  defp spawn_timer(%{time: time} = state, _ptype, %{statetime: statetime} = trailstate, _ts_key)
       when statetime > time,
       do: {true, trailstate, state}

  defp spawn_timer(state, ptype, trailstate, ts_key) do
    timed = %{trailstate | statetime: state.time + ptype.spawntime}
    {false, nil, %{state | trails: Map.put(state.trails, ts_key, timed)}}
  end

  defp emitting_trailstate(%{die: die}, _trailstate) when die == 0, do: nil
  defp emitting_trailstate(_ptype, trailstate), do: trailstate

  defp trail_particles(state, s, key, ptype, {from, to, interval}, {trailstate, ts_key}) do
    delta = Vec.sub(to, from)
    len = Vec.length(delta)
    vec = if len > 0, do: Vec.scale(delta, 1 / len), else: {0.0, 0.0, 0.0}
    {state, count} = trail_count(state, key, ptype, interval)
    {step, len} = averaged_spacing(ptype, len)
    {stop, len} = trail_span(trailstate, len)
    {count, step, vstep} = trail_steps({count, step}, len, stop, vec)
    geometry = trail_geometry(ptype, {vec, vstep, step}, len, stop)

    {particles, {state, _start, len}} =
      Enum.map_reduce(1..max(count, 0)//1, {state, from, len}, fn _, acc ->
        trail_particle(acc, s, ptype, geometry)
      end)

    live = Enum.map(particles, &elem(&1, 0))

    state = %{
      state
      | live: Map.update(state.live, key, Enum.reverse(live), &(Enum.reverse(live) ++ &1))
    }

    state = mark_running(state, key)
    ids = Enum.map(particles, fn {p, l} -> {p.id, l} end)

    state =
      if ptype.type == :beam and ids != [],
        do: add_trail_chain(state, key, ids, vec, trailstate, ts_key),
        else: state

    save_trail_progress(state, trailstate, ts_key, stop, len)
  end

  defp trail_count(state, key, ptype, interval) do
    step = ptype.countextra + ptype.count * interval
    step = step + Map.get(state.overflow, key, 0.0)
    count = trunc(step)
    {%{state | overflow: Map.put(state.overflow, key, step - count)}, count}
  end

  defp averaged_spacing(ptype, len) do
    step = ptype.countspacing

    if MapSet.member?(ptype.flags, :averagetrail) and step != 0 do
      tavg = len / step
      tavg = tavg / Float.ceil(tavg)
      {step * tavg, len + step * tavg}
    else
      {step, len}
    end
  end

  defp trail_span(nil, len), do: {len, 0.0}
  defp trail_span(trailstate, len), do: {trailstate.laststop + len, trailstate.lastdist}

  defp trail_steps({count, step}, len, stop, vec)
       when step != 0 and len < stop and count != 0 and len != 0 do
    count = trunc(count + (stop - len) / step)
    step = (stop - len) / count
    {count, step, Vec.scale(vec, step)}
  end

  defp trail_steps({count, step}, len, stop, vec) when step != 0 and len < stop,
    do: {trunc(count + (stop - len) / step), step, Vec.scale(vec, step)}

  defp trail_steps({count, _step}, _len, _stop, _vec), do: {count, 0.0, {0.0, 0.0, 0.0}}

  defp trail_geometry(ptype, {vec, vstep, step}, len, stop) do
    {right, up} = trail_axes(ptype, vec)
    {tdegree, sdegree} = trail_degrees(ptype)
    nrfirst = if MapSet.member?(ptype.flags, :nospreadfirst), do: len + step * 1.5, else: len
    nrlast = if MapSet.member?(ptype.flags, :nospreadlast), do: stop, else: stop + step

    %{
      vec: vec,
      vstep: vstep,
      right: right,
      up: up,
      tdegree: tdegree,
      sdegree: sdegree,
      nrfirst: nrfirst,
      nrlast: nrlast,
      step: step
    }
  end

  defp trail_degrees(%{spawnmode: :spiral, spawnparam1: turn, spawnparam2: start})
       when turn != 0,
       do: {2 * @pi / turn, start * (@pi / 180)}

  defp trail_degrees(%{spawnmode: :spiral, spawnparam2: start}),
    do: {2 * @pi / 256, start * (@pi / 180)}

  defp trail_degrees(_ptype), do: {2 * @pi / 256, 0.0}

  defp trail_particle({state, start, len}, s, ptype, geometry) do
    len = len + geometry.step
    {id, state} = next_id(state)
    base = ptype |> new_particle(state.time, s) |> wrap_coords(ptype)
    {pos, vel} = trail_place(ptype, geometry, start, len)
    {pos, vel} = world_spread(ptype, pos, vel)
    pos = Vec.add(pos, ptype.orgbias)
    start = Vec.add(start, geometry.vstep)

    start =
      if ptype.countrand != 0,
        do: Vec.madd(start, geometry.vec, random() / ptype.countrand),
        else: start

    particle = %{
      base
      | id: id,
        org: pos,
        oldorg: pos,
        vel: vel,
        die: state.time + ptype.die - base.die
    }

    {{particle, len}, {state, start, len}}
  end

  defp save_trail_progress(state, nil, _ts_key, _stop, _len), do: state

  defp save_trail_progress(state, trailstate, ts_key, stop, len) do
    trails = Map.get(state.trails, ts_key, trailstate)
    %{state | trails: Map.put(state.trails, ts_key, %{trails | laststop: stop, lastdist: len})}
  end

  defp wrap_coords(%{s1: s1} = p, ptype) when s1 >= 1,
    do:
      wrap_coords(
        %{p | s1: s1 - 1, s2: p.s2 - 1, t1: p.t1 + ptype.texsstride, t2: p.t2 + ptype.texsstride},
        ptype
      )

  defp wrap_coords(p, _ptype), do: p

  defp trail_axes(%{spawnmode: mode}, vec) when mode in [:spiral, :circle] do
    right = vv_perpendicular(vec)
    {right, cross(right, vec)}
  end

  defp trail_axes(_ptype, _vec), do: {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}}

  defp vv_perpendicular({x, y, z}) when x == 0 and y == 0,
    do: {0.0, if(z != 0, do: -1.0, else: 0.0), 0.0}

  defp vv_perpendicular({x, y, _z}), do: Vec.normalize({y, -x, 0.0})

  defp trail_place(ptype, g, start, len) do
    veladd = -ptype.veladd
    {vx, vy, vz} = g.vec

    if len < g.nrfirst or len >= g.nrlast do
      {start, Vec.scale(g.vec, veladd)}
    else
      {pos, vel} = trail_mode(ptype, g, start, len, veladd)
      pos = if ptype.orgadd != 0, do: Vec.madd(pos, {vx, vy, vz}, ptype.orgadd), else: pos
      {pos, vel}
    end
  end

  defp trail_mode(%{spawnmode: :tracer} = p, g, {sx, sy, sz}, len, veladd) do
    {vx, vy, vz} = g.vec

    tcount =
      if p.spawnparam1 != 0, do: trunc(len * p.count / p.spawnparam1), else: trunc(len * p.count)

    {ox, oy, velx, vely} =
      if Bitwise.band(tcount, 1) == 1,
        do: {vy * p.areaspread, -vx * p.areaspread, vy * p.spawnvel, -vx * p.spawnvel},
        else: {-vy * p.areaspread, vx * p.areaspread, -vy * p.spawnvel, vx * p.spawnvel}

    {{ox + sx, oy + sy, sz}, {velx + vx * veladd, vely + vy * veladd, vz * veladd}}
  end

  defp trail_mode(%{spawnmode: :spiral} = p, g, start, len, veladd) do
    tcos = :math.cos(len * g.tdegree + g.sdegree)
    tsin = :math.sin(len * g.tdegree + g.sdegree)
    pos = start |> Vec.madd(g.right, tcos * p.areaspread) |> Vec.madd(g.up, tsin * p.areaspread)

    vel =
      g.vec
      |> Vec.scale(veladd)
      |> Vec.madd(g.right, tcos * p.spawnvel)
      |> Vec.madd(g.up, tsin * p.spawnvel)

    {pos, vel}
  end

  defp trail_mode(%{spawnmode: :ball} = p, g, start, _len, veladd) do
    {x, y, z} = {crandom(), crandom(), crandom()} |> Vec.normalize() |> Vec.scale(random())
    {vx, vy, vz} = g.vec

    vel =
      {vx * veladd + x * p.spawnvel, vy * veladd + y * p.spawnvel,
       vz * veladd + z * p.spawnvelvert}

    {sx, sy, sz} = start
    {{x * p.areaspread + sx, y * p.areaspread + sy, z * p.areaspreadvert + sz}, vel}
  end

  defp trail_mode(%{spawnmode: :circle} = p, g, start, len, veladd) do
    tcos = :math.cos(len * g.tdegree) * p.areaspread
    tsin = :math.sin(len * g.tdegree) * p.areaspread
    {vsx, vsy, vsz} = g.vstep
    {sx, sy, sz} = start |> Vec.madd(g.right, tcos) |> Vec.madd(g.up, tsin)

    pos =
      {sx + vsx * (len * g.tdegree), sy + vsy * (len * g.tdegree),
       sz + vsz * (len * g.tdegree) * 50}

    vcos = :math.cos(len * g.tdegree) * p.spawnvel
    vsin = :math.sin(len * g.tdegree) * p.spawnvel
    vel = g.vec |> Vec.scale(veladd) |> Vec.madd(g.right, vcos) |> Vec.madd(g.up, vsin)
    {pos, vel}
  end

  defp trail_mode(%{spawnmode: :distball} = p, g, start, _len, veladd) do
    rdist = p.spawnparam2 - crandom() * (1 - crandom() * p.spawnparam1)
    {x, y, z} = {crandom(), crandom(), crandom()} |> Vec.normalize() |> Vec.scale(rdist)
    {vx, vy, vz} = g.vec

    vel =
      {vx * veladd + x * p.spawnvel, vy * veladd + y * p.spawnvel,
       vz * veladd + z * p.spawnvelvert}

    {sx, sy, sz} = start
    {{x * p.areaspread + sx, y * p.areaspread + sy, z * p.areaspreadvert + sz}, vel}
  end

  defp trail_mode(p, g, start, _len, veladd) do
    {x, y, z} = {crandom(), crandom(), crandom()}
    {vx, vy, vz} = g.vec

    vel =
      {vx * veladd + x * p.spawnvel, vy * veladd + y * p.spawnvel,
       vz * veladd + z * p.spawnvelvert}

    {sx, sy, sz} = start
    {{x * p.areaspread + sx, y * p.areaspread + sy, z * p.areaspreadvert + sz}, vel}
  end

  defp add_chain(state, key, ids, _dir) do
    segments =
      Enum.with_index(ids, fn id, i -> %{id: id, texture_s: i / 1, dir: {0.0, 0.0, 0.0}} end)

    chain = %{segments: segments, open: false}
    %{state | beams: Map.update(state.beams, key, [chain], &[chain | &1])}
  end

  defp add_trail_chain(state, key, ids, vec, trailstate, ts_key) do
    segments = Enum.map(ids, fn {id, len} -> %{id: id, texture_s: len, dir: vec} end)
    chains = Map.get(state.beams, key, [])

    case trailstate && trailstate.chain do
      ref when is_reference(ref) ->
        case Enum.split_with(chains, &(&1[:ref] == ref)) do
          {[chain], others} ->
            chain = %{chain | segments: chain.segments ++ segments}
            %{state | beams: Map.put(state.beams, key, [chain | others])}

          _ ->
            new_trail_chain(state, key, chains, segments, ts_key)
        end

      _ ->
        if trailstate,
          do: new_trail_chain(state, key, chains, segments, ts_key),
          else: %{
            state
            | beams: Map.put(state.beams, key, [%{segments: segments, open: false} | chains])
          }
    end
  end

  defp new_trail_chain(state, key, chains, segments, ts_key) do
    ref = make_ref()
    chain = %{segments: segments, open: true, ref: ref}

    trails =
      Map.update(state.trails, ts_key, %{new_trailstate() | chain: ref}, &%{&1 | chain: ref})

    %{state | beams: Map.put(state.beams, key, [chain | chains]), trails: trails}
  end

  defp run_types(state, s, frametime) do
    Enum.reduce(state.order, state, fn key, acc ->
      {acc, ptype} = type_of(acc, key)
      if ptype, do: run_type(acc, s, key, ptype, frametime), else: acc
    end)
    |> drop_idle()
  end

  defp drop_idle(state) do
    order =
      Enum.filter(state.order, fn key ->
        Map.get(state.live, key, []) != [] or Map.get(state.beams, key, []) != [] or
          Map.get(state.decals, key, []) != []
      end)

    %{state | order: order}
  end

  defp run_type(state, s, key, ptype, frametime) do
    time = state.time
    decals = state.decals |> Map.get(key, []) |> Enum.reject(&(&1.die < time))
    decals = Enum.map(decals, &age_decal(&1, ptype, time, frametime))
    state = %{state | decals: Map.put(state.decals, key, decals)}
    particles = Map.get(state.live, key, [])

    if ptype.die == 0 do
      state =
        if (ptype.emit && ptype.emitstart <= 0) and frametime != 0,
          do:
            Enum.reduce(
              particles,
              state,
              &run_effect(&2, s, ptype.emit, &1.org, &1.vel, frametime, nil)
            ),
          else: state

      state
      |> Map.put(:shown, Map.put(state.shown, key, particles))
      |> then(&%{&1 | live: Map.put(&1.live, key, [])})
      |> prune_beams(key, Map.new(particles, fn p -> {p.id, p} end))
    else
      alive = Enum.reject(particles, &(&1.die < time))
      grav = ptype.gravity * frametime
      {fx, fy, fz} = ptype.friction
      friction = {1 - fx * frametime, 1 - fy * frametime, 1 - fz * frametime}

      {moved, state} =
        Enum.map_reduce(alive, state, fn p, acc ->
          move_particle(acc, s, ptype, p, frametime, grav, friction)
        end)

      moved = Enum.reject(moved, &is_nil/1)
      lookup = Map.new(moved, &{&1.id, &1})

      state
      |> Map.put(:shown, Map.put(state.shown, key, moved))
      |> then(&%{&1 | live: Map.put(&1.live, key, moved)})
      |> prune_beams(key, lookup)
    end
  end

  defp prune_beams(state, key, lookup) do
    chains =
      state.beams
      |> Map.get(key, [])
      |> Enum.map(fn chain ->
        kept = Enum.filter(chain.segments, &Map.has_key?(lookup, &1.id))

        kept =
          if chain.open and kept == [] and chain.segments != [],
            do: [List.last(chain.segments)],
            else: kept

        %{chain | segments: kept}
      end)
      |> Enum.reject(&(&1.segments == [] or (not &1.open and length(&1.segments) < 2)))

    %{state | beams: Map.put(state.beams, key, chains)}
  end

  defp age_decal(decal, ptype, time, frametime) do
    if decal.die - time <= ptype.die,
      do: %{decal | rgba: aged_rgba(ptype, decal, time, frametime)},
      else: decal
  end

  defp aged_rgba(%{rampmode: :none} = ptype, decal, time, frametime) do
    {r, g, b, a} = decal.rgba
    {cr, cg, cb} = ptype.rgbchange

    {r, g, b} =
      if time < decal.die - ptype.die + ptype.rgbchangetime,
        do: {r + frametime * cr, g + frametime * cg, b + frametime * cb},
        else: {r, g, b}

    {r, g, b, a + frametime * ptype.alphachange}
  end

  defp aged_rgba(ptype, decal, time, frametime) do
    {ramp_rgb, ramp_alpha, _} = ramp_value(ptype, decal.die, time, decal.rgba, 0.0, frametime)
    {rr, rg, rb} = ramp_rgb
    {rr, rg, rb, ramp_alpha}
  end

  defp ramp_value(ptype, die, time, {r, g, b, a}, scale, frametime) do
    count = length(ptype.ramp)
    progress = count * (ptype.die - (die - time)) / ptype.die

    case ptype.rampmode do
      :nearest ->
        entry = Enum.at(ptype.ramp, min(trunc(progress), count - 1))
        {entry.rgb, entry.alpha, entry.scale}

      :lerp ->
        s1 = min(count - 1, trunc(progress))
        s2 = min(count - 1, s1 + 1)
        frac = progress - s1
        e1 = Enum.at(ptype.ramp, s1)
        e2 = Enum.at(ptype.ramp, s2)

        {lerp3(e1.rgb, e2.rgb, frac), e1.alpha + (e2.alpha - e1.alpha) * frac,
         e1.scale + (e2.scale - e1.scale) * frac}

      :delta ->
        entry = Enum.at(ptype.ramp, min(trunc(progress), count - 1))
        {er, eg, eb} = entry.rgb

        {{r + frametime * er, g + frametime * eg, b + frametime * eb},
         a - frametime * entry.alpha, scale + frametime * entry.scale}
    end
  end

  defp lerp3({ar, ag, ab}, {br, bg, bb}, t),
    do: {ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t}

  defp move_particle(state, s, ptype, p, frametime, grav, {frx, fry, frz}) do
    oldorg = p.org

    p =
      if MapSet.member?(ptype.flags, :velocity) do
        org = Vec.madd(p.org, p.vel, frametime)
        {vx, vy, vz} = p.vel

        {vx, vy, vz} =
          if MapSet.member?(ptype.flags, :friction),
            do: {vx * frx, vy * fry, vz * frz},
            else: {vx, vy, vz}

        {vx, vy} =
          if ptype.flurry != 0 and state.flurry?,
            do: {vx + crandom() * ptype.flurry, vy + crandom() * ptype.flurry},
            else: {vx, vy}

        %{p | org: org, vel: {vx, vy, vz - grav}}
      else
        p
      end

    p = %{p | angle: p.angle + p.rotationspeed * frametime}
    p = change(ptype, p, state.time, frametime)
    {state, p} = emit(state, s, ptype, p, oldorg, frametime)
    clip(state, s, ptype, p, frametime)
  end

  defp change(%{rampmode: :none} = ptype, p, time, frametime) do
    {r, g, b, a} = p.rgba
    {cr, cg, cb} = ptype.rgbchange

    {r, g, b} =
      if time < p.die - ptype.die + ptype.rgbchangetime,
        do: {r + frametime * cr, g + frametime * cg, b + frametime * cb},
        else: {r, g, b}

    %{
      p
      | rgba: {r, g, b, a + frametime * ptype.alphachange},
        scale: p.scale + frametime * ptype.scaledelta
    }
  end

  defp change(ptype, p, time, frametime) do
    {rgb, alpha, scale} = ramp_value(ptype, p.die, time, p.rgba, p.scale, frametime)
    {r, g, b} = rgb
    %{p | rgba: {r, g, b, alpha}, scale: scale}
  end

  defp emit(state, _s, %{emit: nil}, p, _oldorg, _frametime), do: {state, p}

  defp emit(state, s, ptype, p, oldorg, frametime) do
    cond do
      ptype.emittime < 0 ->
        {run_trail(state, s, ptype.emit, oldorg, p.org, frametime, {:particle, p.id}, 0), p}

      p.nextemit < state.time ->
        p = %{p | nextemit: state.time + ptype.emittime + random() * ptype.emitrand}
        {run_effect(state, s, ptype.emit, p.org, p.vel, 1.0, nil), p}

      true ->
        {state, p}
    end
  end

  defp clip(state, _s, %{cliptype: nil}, p, _frametime), do: {p, state}

  defp clip(state, s, ptype, p, frametime) do
    moved = Vec.sub(p.org, p.oldorg)

    if Vec.dot(moved, moved) > 100 do
      trace = world_trace(s, p.oldorg, p.org)

      if trace.fraction < 1,
        do: hit(state, s, ptype, p, trace, frametime),
        else: {%{p | oldorg: p.org}, state}
    else
      {p, state}
    end
  end

  defp hit(state, s, ptype, p, trace, frametime) do
    cond do
      ptype.clipbounce < 0 -> {nil, state}
      ptype.cliptype == {ptype.config, ptype.name} -> bounce(state, ptype, p, trace, frametime)
      true -> burst(state, s, ptype, p, trace)
    end
  end

  defp bounce(state, ptype, p, trace, frametime) do
    dist = Vec.dot(p.vel, trace.normal) * -ptype.clipbounce
    vel = Vec.madd(p.vel, trace.normal, dist)

    if ptype.texname == "" and Vec.length(vel) < 1000 * frametime and ptype.type == :normal,
      do: {nil, state},
      else: {%{p | vel: vel, org: trace.end_pos}, state}
  end

  defp burst(state, s, ptype, p, trace) do
    {state, clipped_type} = type_of(state, ptype.cliptype)

    clip_count =
      if clipped_type && clipped_type.count != 0,
        do: ptype.clipcount / clipped_type.count,
        else: ptype.clipcount

    dir =
      if ptype.clipbounce != 0,
        do: Vec.scale(trace.normal, ptype.clipbounce),
        else: Vec.normalize(p.vel)

    {nil, run_effect(state, s, ptype.cliptype, trace.end_pos, dir, clip_count, nil)}
  end

  defp world_trace(s, from, to) do
    case s.bsp.hulls do
      [hull | _] -> Cauldron3D.Hull.trace(hull, from, to)
      _ -> %Cauldron3D.Hull.Trace{fraction: 1.0, end_pos: to}
    end
  end

  defp run_sprites(state, s, frametime) do
    now = clock(s)

    {sprites, state} =
      Enum.flat_map_reduce(state.sprites, state, fn ex, acc ->
        update_sprite(acc, s, ex, now, frametime)
      end)

    %{state | sprites: sprites}
  end

  defp update_sprite(state, s, ex, now, frametime) do
    f = ex.framerate * (now - ex.start)
    frames = ex.sprite.frames |> tuple_size()
    numframes = if ex.numframes == 0, do: frames - ex.firstframe, else: ex.numframes
    whole = trunc(f)
    of = whole - 1
    {scale, f, alive?} = sprite_frame(ex.endalpha, f, whole, numframes)

    if alive?,
      do: shown_sprite(state, s, ex, {scale, f, of, numframes}, frametime),
      else: {[], state}
  end

  defp sprite_frame(endalpha, f, whole, numframes) do
    cond do
      endalpha != 0 and whole == numframes -> {1 - (f - whole), (whole - 1) / 1, true}
      whole >= numframes or whole < 0 -> {1.0, f, false}
      true -> {1.0, f, true}
    end
  end

  defp shown_sprite(state, s, ex, {scale, f, of, numframes}, frametime) do
    {origin, velocity} = sprite_motion(s, ex, f, frametime)
    angles = Vec.madd(ex.angles, ex.avel, frametime)
    shown_frame = max(of, 0) + ex.firstframe
    alpha = (1.0 - f / numframes) * (ex.startalpha - ex.endalpha) + ex.endalpha

    state =
      if ex.trail,
        do:
          run_trail(
            state,
            s,
            ex.trail,
            ex.oldorigin,
            origin,
            frametime,
            {:sprite, ex.start, ex.origin},
            0
          ),
        else: state

    shown = %{
      frame: shown_frame,
      origin: origin,
      angles: angles,
      alpha: alpha,
      scale: scale * ex.scale
    }

    {[
       %{
         ex
         | origin: if(ex.gravity != 0, do: origin, else: ex.origin),
           oldorigin: origin,
           velocity: velocity,
           angles: angles,
           shown: shown
       }
     ], state}
  end

  defp sprite_motion(_s, %{gravity: gravity} = ex, f, _frametime) when gravity == 0,
    do: {Vec.madd(ex.origin, ex.velocity, f), ex.velocity}

  defp sprite_motion(_s, %{velocity: {vx, vy, vz}} = ex, _f, _frametime)
       when vx == 0 and vy == 0 and vz == 0,
       do: {ex.origin, ex.velocity}

  defp sprite_motion(s, ex, _f, frametime) do
    {vx, vy, vz} = ex.velocity
    pos = Vec.madd(ex.origin, ex.velocity, frametime)
    trace = world_trace(s, ex.origin, pos)

    if trace.fraction < 1,
      do: bounced_sprite(ex, trace),
      else: {pos, {vx, vy, vz - ex.gravity * frametime}}
  end

  defp bounced_sprite(ex, trace) do
    sc = Vec.dot(ex.velocity, trace.normal) * -1.5
    vel = ex.velocity |> Vec.madd(trace.normal, sc) |> Vec.scale(0.9)
    {_, _, nz} = trace.normal
    vel = if nz > 0.7 and Vec.dot(vel, vel) < 100, do: {0.0, 0.0, 0.0}, else: vel
    {trace.end_pos, vel}
  end

  defp decay_lights(state, now, frametime) do
    lights =
      state.lights
      |> Enum.reject(&(&1.die != 0 and &1.die < now))
      |> Enum.map(fn light ->
        {r, g, b} = light.colour
        {fr, fg, fb} = light.fade

        %{
          light
          | radius: light.radius - frametime * light.decay,
            colour: {fade(r, fr, frametime), fade(g, fg, frametime), fade(b, fb, frametime)}
        }
      end)
      |> Enum.reject(&(&1.radius < 0))

    %{state | lights: lights}
  end

  defp fade(value, rate, _frametime) when rate == 0, do: value
  defp fade(value, rate, frametime), do: max(value - frametime * rate, 0.0)

  defp type_polygons(state, key, view) do
    ptype = Map.get(state.types, key)
    looks = Looks.looks(ptype)
    particles = state |> Map.get(:shown, %{}) |> Map.get(key, [])
    decals = Map.get(state.decals, key, [])

    decal_polygons(ptype, looks, decals) ++
      particle_polygons(ptype, looks, particles, view) ++
      beam_polygons(state, key, ptype, looks, view)
  end

  defp decal_polygons(ptype, looks, decals) do
    texture = looks.texture

    for decal <- decals do
      tint = vertex_colour(ptype, decal.rgba, looks)

      {looks.sort,
       %Polygon{
         points: Enum.map(decal.corners, fn {p, _, _} -> Vec.madd(p, decal.normal, -0.25) end),
         uvs:
           Enum.map(decal.corners, fn {_, {u, v}, _} ->
             {u * texture.width, v * texture.height}
           end),
         tints: Enum.map(decal.corners, fn {_, _, fade} -> scale_alpha(tint, fade) end),
         paint: {:texture, texture, nil},
         blend: looks.blend
       }}
    end
  end

  defp scale_alpha({r, g, b, a}, k), do: {r, g, b, a * k}

  defp vertex_colour(_ptype, _rgba, %{tinted?: false}), do: {1.0, 1.0, 1.0, 1.0}

  defp vertex_colour(%{premul: premul}, {r, g, b, a}, _looks) when premul > 0 do
    a = min(a, 1.0)
    {r * a, g * a, b * a, if(premul == 2, do: 0.0, else: a)}
  end

  defp vertex_colour(_ptype, rgba, _looks), do: rgba

  defp particle_polygons(%{type: type} = ptype, looks, particles, view)
       when type in [:normal, :texturedspark, :sparkfan, :spark, :udecal] do
    pright = Vec.scale(view.right, 1.5)
    pup = Vec.scale(view.up, 1.5)
    texture = looks.texture

    Enum.flat_map(particles, fn p ->
      points = shape(ptype, p, view, pright, pup)
      tint = vertex_colour(ptype, p.rgba, looks)
      uv = fn {s, t} -> {s * texture.width, t * texture.height} end

      uvs = particle_uvs(type, p, length(points)) |> Enum.map(uv)

      tints =
        if type == :spark,
          do:
            [tint, put_elem(tint, 3, 0.0)]
            |> Enum.flat_map(&[&1, &1]),
          else: List.duplicate(tint, length(points))

      [
        {looks.sort,
         %Polygon{
           points: points,
           uvs: uvs,
           tints: tints,
           paint: {:texture, texture, nil},
           blend: looks.blend
         }}
      ]
    end)
  end

  defp particle_polygons(_ptype, _looks, _particles, _view), do: []

  defp particle_uvs(:sparkfan, p, _count), do: [{p.s1, p.t1}, {p.s1, p.t2}, {p.s2, p.t1}]

  defp particle_uvs(:spark, p, _count),
    do: [{p.s1, p.t1}, {p.s1, p.t1}, {p.s2, p.t2}, {p.s2, p.t2}]

  defp particle_uvs(_type, p, _count),
    do: [{p.s1, p.t1}, {p.s1, p.t2}, {p.s2, p.t2}, {p.s2, p.t1}]

  defp shape(%{type: :normal} = ptype, p, view, pright, pup),
    do: quad(textured_scale(ptype, p, view), p, pright, pup)

  defp shape(%{type: :udecal}, p, _view, _pright, _pup),
    do: quad(p.scale, p, {1.0, 0.0, 0.0}, {0.0, 1.0, 0.0})

  defp shape(%{type: :texturedspark} = ptype, p, view, _pright, _pup) do
    halfscale = p.scale * 0.5
    speed = Vec.length(p.vel)
    movedir = if speed > 0, do: Vec.scale(p.vel, 1 / speed), else: {0.0, 0.0, 0.0}

    length = if ptype.stretch < 0, do: -ptype.stretch, else: speed * ptype.stretch

    length = max(length, halfscale * ptype.minstretch)
    o2 = Vec.madd(p.org, movedir, -length)
    cr = view.origin |> Vec.sub(o2) |> cross(p.vel) |> Vec.normalize()
    half = abs(p.scale)
    a = Vec.madd(o2, cr, -half / 2)
    b = Vec.madd(o2, cr, half / 2)
    o2 = Vec.madd(p.org, movedir, length)
    cr = view.origin |> Vec.sub(o2) |> cross(p.vel) |> Vec.normalize()
    [a, b, Vec.madd(o2, cr, p.scale * 0.5), Vec.madd(o2, cr, -p.scale * 0.5)]
  end

  defp shape(%{type: :sparkfan} = ptype, p, view, _pright, _pup) do
    scale = Vec.dot(Vec.sub(p.org, view.origin), view.forward)
    scale = scale * p.scale * ptype.invscalefactor + p.scale * (ptype.scalefactor * 250)
    scale = if scale < 20, do: 0.05, else: 0.05 + scale * 0.0001
    o2 = Vec.madd(p.org, p.vel, -scale)
    cr = view.origin |> Vec.sub(o2) |> cross(p.vel) |> Vec.normalize()
    [p.org, Vec.madd(o2, cr, -p.scale), Vec.madd(o2, cr, p.scale)]
  end

  defp shape(%{type: :spark}, p, view, _pright, _pup) do
    tail = Vec.madd(p.org, p.vel, -1.0 / 10)
    along = Vec.sub(tail, p.org)
    side = view.forward |> cross(along) |> Vec.normalize()
    depth = max(Vec.dot(Vec.sub(p.org, view.origin), view.forward), view.near)
    half = depth / view.scale_x / 2

    [
      Vec.madd(p.org, side, half),
      Vec.madd(p.org, side, -half),
      Vec.madd(tail, side, -half),
      Vec.madd(tail, side, half)
    ]
  end

  defp textured_scale(%{scalefactor: factor}, p, _view) when factor == 1, do: p.scale * 0.25

  defp textured_scale(ptype, p, view) do
    scale = Vec.dot(Vec.sub(p.org, view.origin), view.forward)
    scale = scale * p.scale * ptype.invscalefactor + p.scale * (ptype.scalefactor * 250)
    if scale < 20, do: 0.25, else: 0.25 + scale * 0.001
  end

  defp quad(scale, p, right, up) do
    if p.angle != 0 do
      x = :math.sin(p.angle) * scale
      y = :math.cos(p.angle) * scale

      [
        p.org |> Vec.madd(right, -x) |> Vec.madd(up, -y),
        p.org |> Vec.madd(right, -y) |> Vec.madd(up, x),
        p.org |> Vec.madd(right, x) |> Vec.madd(up, y),
        p.org |> Vec.madd(right, y) |> Vec.madd(up, -x)
      ]
    else
      [
        Vec.madd(p.org, up, -scale),
        Vec.madd(p.org, right, -scale),
        Vec.madd(p.org, up, scale),
        Vec.madd(p.org, right, scale)
      ]
    end
  end

  defp beam_polygons(state, key, ptype, looks, view) do
    shown = state |> Map.get(:shown, %{}) |> Map.get(key, [])
    lookup = Map.new(shown, &{&1.id, &1})
    texture = looks.texture
    time = state.time

    state.beams
    |> Map.get(key, [])
    |> Enum.flat_map(fn chain ->
      chain.segments
      |> Enum.flat_map(&shown_segment(&1, lookup))
      |> with_directions()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [near, far] -> beam_quad(ptype, looks, texture, view, near, far, time) end)
    end)
    |> Enum.sort_by(fn {_, _polygon, mid} -> -Vec.length(Vec.sub(mid, view.origin)) end)
    |> Enum.map(fn {sort, polygon, _} -> {sort, polygon} end)
  end

  defp with_directions([]), do: []

  defp with_directions([first | rest]) do
    {tail, _} =
      Enum.map_reduce(rest, first, fn {segment, p}, {_, previous} ->
        dir = p.org |> Vec.sub(previous.org) |> Vec.normalize()
        {{%{segment | dir: dir}, p}, {segment, p}}
      end)

    [first | tail]
  end

  defp shown_segment(segment, lookup) do
    case Map.get(lookup, segment.id) do
      nil -> []
      p -> [{segment, p}]
    end
  end

  defp beam_quad(ptype, looks, texture, view, {b, p}, {c, q}, time) do
    cq =
      view.origin
      |> Vec.sub(q.org)
      |> Vec.normalize()
      |> then(&cross(c.dir, &1))
      |> Vec.normalize()

    tsq = c.texture_s * q.angle + time * q.rotationspeed

    cp =
      view.origin
      |> Vec.sub(p.org)
      |> Vec.normalize()
      |> then(&cross(b.dir, &1))
      |> Vec.normalize()

    tsp = b.texture_s * p.angle + time * p.rotationspeed
    tq = vertex_colour(ptype, q.rgba, looks)
    tp = vertex_colour(ptype, p.rgba, looks)
    {w, h} = {texture.width, texture.height}

    polygon = %Polygon{
      points: [
        Vec.madd(q.org, cq, -q.scale),
        Vec.madd(q.org, cq, q.scale),
        Vec.madd(p.org, cp, p.scale),
        Vec.madd(p.org, cp, -p.scale)
      ],
      uvs: [{tsq * w, p.t1 * h}, {tsq * w, p.t2 * h}, {tsp * w, p.t2 * h}, {tsp * w, p.t1 * h}],
      tints: [tq, tq, tp, tp],
      paint: {:texture, texture, nil},
      blend: looks.blend
    }

    {looks.sort, polygon, Vec.scale(Vec.add(p.org, q.org), 0.5)}
  end

  defp sprite_polygons(state, view) do
    weapon = {view.origin, {view.forward, Vec.scale(view.right, -1.0), view.up}}

    Enum.flat_map(state.sprites, fn
      %{shown: nil} ->
        []

      ex ->
        %{frame: frame, origin: origin, angles: angles, alpha: alpha, scale: scale} = ex.shown
        {forward, right, up} = QuakeServer.Angles.vectors(angles)
        additive? = MapSet.member?(ex.flags, :additive)

        translucent? =
          MapSet.member?(ex.flags, :translucent) or ex.startalpha < 1 or ex.endalpha < 1

        thing = %{
          frame: frame,
          frame_time: 0.0,
          origin: origin,
          axes: {forward, Vec.scale(right, -1.0), up},
          scale: scale,
          colormod: ex.rgb,
          alpha: alpha,
          flags: 0
        }

        polygon = Sprites.polygon(thing, ex.name, ex.sprite, view, weapon)

        {blend, sort} =
          cond do
            additive? -> {{:add, 1.0}, 12}
            translucent? -> {{:alpha, 1.0}, 11}
            true -> {:none, 7}
          end

        [{sort, %{polygon | blend: blend}}]
    end)
  end

  defp decal_looks(s, shader) do
    texts = Map.get(s.ext, :shader_texts, %{})

    case Map.get(texts, shader) do
      text when is_binary(text) ->
        Looks.shader(text, ElixirHalfLife.Pictures.get(shader))

      _ ->
        Looks.shader(
          "{\npolygonOffset\nsurfaceparms nodlight\n{\nmap $diffuse\nrgbgen vertex\nalphagen vertex\nblendfunc gl_one gl_one_minus_src_alpha\n}\n}\n",
          ElixirHalfLife.Pictures.get(shader)
        )
    end
  end
end
