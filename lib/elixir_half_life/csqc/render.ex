defmodule ElixirHalfLife.Csqc.Render do
  @moduledoc """
  The client program's scene drawn as FTE draws it for FreeHL, into the view's box on
  the screen.

  An entity is drawn by `snapshot/3` of its fields when it is added (FTE's
  `CopyCSQCEdictToEntity`): its model, origin, angles (or with `RF_USEAXIS` the
  `v_forward`, `v_right` and `v_up` globals, at scale 1), scale (0 is 1), frame and
  frame time (`frame1time`, or `time - frame1time` with `RF_FRAMETIMESARESTARTTIMES`; an
  entity the client program does not time is posed by GoldSrc's client rule from the
  server's animation, `ElixirHalfLife.Csqc.Animation`),
  base frame below bone `basebone - 1`, skin, the five bone controllers, both sub-blends,
  geomsets, skeleton, colour modulation (unset when black), alpha (translucent when
  neither 0 nor 1), glow modulation, effects, render flags, fatness, draw flags,
  `abslight` and colormap.

  `RF_VIEWMODEL` places the entity relative to the view and keeps its depth in the
  nearest third (as `RF_DEPTHHACK` alone does); `RF_EXTERNALMODEL` keeps it out of the
  view. `EF_ADDITIVE` and `RF_ADDITIVE` add it, a translucent alpha lays it over,
  `EF_NODEPTHTEST` draws it over everything and `EF_FULLBRIGHT` lights it evenly.
  `EF_NODRAW` does not apply to entities the program adds. Entities outside the leaves
  the view's leaf can see are not drawn, held ones always are.

  Brush entities are tinted by their colour modulation and alpha; with a glow
  modulation red of 0.5 their `{` faces are cut away where see-through, with a green of
  0.5 their textures scroll by `-time * blue * 1024 / 100` of their width, and draw flags
  7 light them at `abslight`. The world's `{` faces are opaque. Liquids ripple as
  FreeHL's warp shader moves them: each place moved an eighth of the texture's size
  along each axis by the sine of the other axis's place over the texture's size plus
  the time.

  Blended things are drawn in FTE's order: by shader sort, then the program's polygons,
  the particles (`ElixirHalfLife.Csqc.Particles`, run on to now first) and sprites in
  the order made, then models in the reverse of the order added.

  A studio entity with a `forceshader` whose text (see `ElixirHalfLife.Csqc.Shaders`)
  maps a picture is drawn as that shell instead: bulged, reflecting the eye, scrolled,
  tinted by its colour modulation with `rgbGen entity`, its back faces kept with
  `cull back`.

  The program's dynamic lights are drawn as FTE draws its realtime lights over the
  world's and unblended brush entities' faces (`Cauldron3D.Paint.Rgba`'s `{:lit, ...}`),
  each light's colour times its style's colour and value over 255, without shadows.
  """

  import Bitwise

  alias Cauldron3D.{Bsp, Camera, Frame, Polygon, Render, Skeleton, Vec, View}
  alias Cauldron3D.Bsp.Draw
  alias Cauldron3D.Formats.{Spr, Studio}

  alias ElixirHalfLife.Csqc.{
    Animation,
    Described,
    Lighting,
    Particles,
    Polygons,
    Scene,
    Screen,
    Shaders,
    Sprites
  }

  alias ElixirHalfLife.Pictures
  alias QuakeServer.{Angles, Edicts, Models}

  @grey for(i <- 0..255, into: <<>>, do: <<i, i, i>>)

  @doc "A snapshot of `entity` for drawing, or `nil` when it has no model."
  @spec snapshot(map(), non_neg_integer(), tuple() | nil) :: map() | nil
  def snapshot(s, entity, lighting) do
    case Edicts.int(s, entity, "modelindex") do
      0 -> nil
      index -> fields(s, entity, index, lighting)
    end
  end

  @doc """
  Draw the scene into its view's box on the screen; with the host's `ext.gpu` set,
  describe it instead (`ElixirHalfLife.Csqc.Described.put/2`).
  """
  @spec scene(map()) :: map()
  def scene(s) do
    s = Particles.advance(s)
    gathered = gather(s)

    if Map.get(s.ext, :gpu, false),
      do: Described.put(s, gathered),
      else: draw(s, gathered)
  end

  @doc """
  What the scene shows now, as `scene/1` draws it: `%{view:, rect:, area:, fov:, world?:,
  styles:, world_light:, weapon:, brushes:, others:, lights:, polygons:}`. `view` is the
  `Cauldron3D.View`, `rect` its box on the screen in pixels, `fov` `{x, y}` in degrees;
  `brushes` the brush entities and `others` the rest, each a snapshot (`snapshot/3`)
  shown from the view's leaf, with `:weapon` the view's place and axes; `lights` the
  dynamic lights as drawn; `polygons` the program's own polygons and the particles as
  `{shader sort, polygon}`.
  """
  @spec gather(map()) :: map()
  def gather(s) do
    scene = Scene.scene(s)
    %{view: view} = placed = setup(s, scene.view)
    styles = Lighting.styles(s)
    visible = visible_leaves(s, view, scene.view)
    weapon = {view.origin, {view.forward, Vec.scale(view.right, -1.0), view.up}}

    things =
      (scene.entities ++ statics(s))
      |> Enum.filter(&shown?(s, &1, visible))
      |> Enum.map(&Map.put(&1, :weapon, weapon))

    {brushes, others} = Enum.split_with(things, &brush?(s, &1))
    made = Enum.flat_map(Enum.reverse(scene.polygons), &Polygons.scene(&1, view))

    Map.merge(placed, %{
      world?: QuakeC.float(Map.get(scene.view, 19, 1.0)) != 0,
      styles: styles,
      world_light: Lighting.world(styles),
      weapon: weapon,
      brushes: brushes,
      others: others,
      lights: rtlights(scene.lights, styles) ++ Particles.lights(s),
      polygons: made ++ Particles.polygons(s, view)
    })
  end

  defp draw(s, %{view: view, rect: {x, y, _w, _h}} = gathered) do
    world =
      if gathered.world?,
        do:
          Draw.polygons(s.bsp, view,
            surfaces: Map.fetch!(s.ext, :surfaces),
            light: gathered.world_light,
            skybox: skybox(s),
            time: s.time,
            liquid: &liquid/1,
            models: Enum.map(gathered.brushes, &brush_model(s, &1, gathered.world_light)),
            rtlights: gathered.lights
          ),
        else: []

    modelled = model_polygons(s, gathered.others, view, gathered.styles, gathered.weapon)

    blended =
      order(
        Enum.map(gathered.polygons, fn {sort, polygon} -> {{sort, 0}, polygon} end) ++ modelled
      )

    frame = Render.draw(view, world ++ blended, palette: @grey, background: {0, 0, 0})
    put_frame(s, Frame.blit(Screen.frame(s), frame, {trunc(x), trunc(y)}))
  end

  @doc "Keyed polygons `{key, polygon}` in the order they are drawn: by key, then as given."
  @spec order([{term(), Polygon.t()}]) :: [Polygon.t()]
  def order(keyed) do
    keyed
    |> Enum.with_index()
    |> Enum.sort_by(fn {{key, _polygon}, index} -> {key, index} end)
    |> Enum.map(fn {{_key, polygon}, _index} -> polygon end)
  end

  @doc """
  The sprites among `things` as `{{shader sort, 0}, polygon}`, as `scene/1` draws them
  for `view`.
  """
  @spec sprite_polygons(map(), [map()], View.t(), tuple()) :: [{tuple(), Polygon.t()}]
  def sprite_polygons(s, things, view, weapon) do
    for thing <- things,
        %{kind: :sprite, data: %Spr{} = sprite, name: name} <- [Models.get(s, thing.model)] do
      {{sprite_sort(thing), 0}, dress(Sprites.polygon(thing, name, sprite, view, weapon), thing)}
    end
  end

  @doc """
  Each bone of `studio` posed for snapshot `thing`, in the model's own space (its place,
  axes and scale left out): the program's skeleton when it set one, else the sequence,
  frame, controllers, blends and base frame `scene/1` poses it by.
  """
  @spec studio_bones(Studio.t(), map()) :: tuple()
  def studio_bones(studio, %{skeleton: nil} = thing),
    do: Skeleton.pose(studio.parents, locals(studio, thing))

  def studio_bones(_studio, %{skeleton: bones}), do: bones

  @doc "Where snapshot `thing` stands: `{origin, {forward, left, up}}`, a held one placed by the view."
  @spec placement(map()) :: {Vec.t(), {Vec.t(), Vec.t(), Vec.t()}}
  def placement(thing), do: {placed_origin(thing), placed_axes(thing)}

  @doc """
  Where world point `point` falls on the screen in 2D units, as FTE's `project` gives it: `{x, y,
  z}` with `z` `1 - 2 * near / depth`, negated when the point is behind the view. A point
  level with the view (depth 0, where FTE's division gives infinities) is taken at depth
  `1.0e-30`, giving numbers of the same signs as large as a float holds.
  """
  @spec project(map(), Vec.t()) :: Vec.t()
  def project(s, point) do
    %{view: view, area: {x, y, w, h}, fov: {fov_x, fov_y}} = setup(s, Scene.scene(s).view)
    {right, up, depth} = View.to_camera(view, point)
    depth = if depth == 0, do: 1.0e-30, else: depth
    ndc_x = right / (depth * :math.tan(fov_x * :math.pi() / 360))
    ndc_y = up / (depth * :math.tan(fov_y * :math.pi() / 360))
    z = (depth - 2 * view.near) / depth
    z = if depth < 0, do: -z, else: z
    {(1 + ndc_x) / 2 * w + x, (1 - (1 + ndc_y) / 2) * h + y, z}
  end

  @doc "The world point at screen point `{x, y, z}`, `z` as `project/2` gives it, as FTE's `unproject` finds it."
  @spec unproject(map(), Vec.t()) :: Vec.t()
  def unproject(s, {sx, sy, sz}) do
    %{view: view, area: {x, y, w, h}, fov: {fov_x, fov_y}} = setup(s, Scene.scene(s).view)
    ndc_x = (sx - x) / w * 2 - 1
    ndc_y = (1 - (sy - y) / h) * 2 - 1
    ndc_z = min(sz * 2 - 1, 0.999999)
    depth = 2 * view.near / (1 - ndc_z)
    right = ndc_x * depth * :math.tan(fov_x * :math.pi() / 360)
    up = ndc_y * depth * :math.tan(fov_y * :math.pi() / 360)

    view.origin
    |> Vec.madd(view.forward, depth)
    |> Vec.madd(view.right, right)
    |> Vec.madd(view.up, up)
  end

  @doc "A polygon built with `R_BeginPolygon` and the 2D flag, drawn straight onto the screen inside its clip area."
  @spec flat_polygon(map(), map()) :: map()
  def flat_polygon(s, polygon) do
    frame = Screen.frame(s)
    {rx, ry} = Screen.ratio(s)

    vertices =
      Enum.map(polygon.vertices, fn {{x, y, z}, st, rgb, a} ->
        {{x * rx, y * ry, z}, st, rgb, a}
      end)

    drawn =
      if Map.get(s.ext, :gpu, false),
        do: Polygons.flat_over(%{polygon | vertices: vertices}, frame),
        else: Polygons.flat(%{polygon | vertices: vertices}, frame)

    put_frame(s, clipped(frame, drawn, s.ext.screen.clip))
  end

  defp clipped(frame, drawn, {x0, y0, x1, y1}) do
    row_bytes = frame.width * 4

    pixels =
      for y <- 0..(frame.height - 1), into: <<>> do
        old = binary_part(frame.pixels, y * row_bytes, row_bytes)
        new = binary_part(drawn.pixels, y * row_bytes, row_bytes)

        if y < y0 or y >= y1 or x1 <= x0,
          do: old,
          else:
            binary_part(old, 0, x0 * 4) <>
              binary_part(new, x0 * 4, (x1 - x0) * 4) <>
              binary_part(old, x1 * 4, row_bytes - x1 * 4)
      end

    %{frame | pixels: pixels}
  end

  defp fields(s, entity, index, lighting) do
    rflags = Edicts.int(s, entity, "renderflags")
    time = QuakeC.float(QuakeC.global(s.qc, "time"))
    angles = Edicts.vector(s, entity, "angles")
    useaxis? = band(rflags, 16) != 0
    {axes, scale} = axes(s, entity, angles, useaxis?)
    alpha = Edicts.float(s, entity, "alpha")
    basebone = Edicts.int(s, entity, "basebone")

    %{
      entity: entity,
      model: index,
      origin: Edicts.vector(s, entity, "origin"),
      angles: angles,
      axes: axes,
      scale: scale,
      frame: band(Edicts.int(s, entity, "frame"), bnot(0x8000)),
      frame_time: frame_time(rflags, time, Edicts.float(s, entity, "frame1time")),
      carried: Animation.seconds(s, entity, time),
      base: base(s, entity, basebone, rflags, time),
      skin: Edicts.int(s, entity, "skin"),
      alpha: if(alpha == 0 or alpha == 1, do: 1.0, else: alpha),
      translucent?: alpha != 0 and alpha != 1,
      effects: Edicts.int(s, entity, "effects"),
      flags: rflags,
      colormod: unset_black(Edicts.vector(s, entity, "colormod")),
      glowmod: unset_black(Edicts.vector(s, entity, "glowmod")) || {1.0, 1.0, 1.0},
      fatness: Edicts.float(s, entity, "fatness"),
      forceshader: Edicts.int(s, entity, "forceshader"),
      drawflags: Edicts.int(s, entity, "drawflags"),
      abslight: Edicts.float(s, entity, "abslight"),
      colormap: Edicts.int(s, entity, "colormap"),
      bonecontrols: for(i <- 1..5, do: Edicts.float(s, entity, "bonecontrol#{i}")),
      subblend:
        {Edicts.float(s, entity, "subblendfrac"), Edicts.float(s, entity, "subblend2frac")},
      geomsets: s.ext |> Map.get(:geomsets, %{}) |> Map.get(entity, %{}),
      skeleton:
        QuakeServer.Extensions.Models.skeleton_transforms(
          s,
          Edicts.int(s, entity, "skeletonindex")
        ),
      absmin: Edicts.vector(s, entity, "absmin"),
      absmax: Edicts.vector(s, entity, "absmax"),
      lighting: lighting
    }
  end

  defp axes(s, _entity, _angles, true) do
    {forward, right, up} =
      {global_vector(s, "v_forward"), global_vector(s, "v_right"), global_vector(s, "v_up")}

    {{forward, Vec.scale(right, -1.0), up}, 1.0}
  end

  defp axes(s, entity, angles, false) do
    {forward, right, up} = Angles.vectors(angles)
    scale = Edicts.float(s, entity, "scale")
    {{forward, Vec.scale(right, -1.0), up}, if(scale == 0, do: 1.0, else: scale)}
  end

  defp global_vector(s, name) do
    if QuakeC.global?(s.qc, name),
      do: QuakeC.global_vector(s.qc, name),
      else: {0.0, 0.0, 0.0}
  end

  defp frame_time(rflags, time, frame1time) when band(rflags, 64) != 0, do: time - frame1time
  defp frame_time(_rflags, _time, frame1time), do: frame1time

  defp base(_s, _entity, 0, _rflags, _time), do: nil

  defp base(s, entity, basebone, rflags, time),
    do:
      {Edicts.int(s, entity, "baseframe"),
       frame_time(rflags, time, Edicts.float(s, entity, "baseframe1time")), basebone - 1}

  defp unset_black({+0.0, +0.0, +0.0}), do: nil
  defp unset_black({r, g, b}) when r == 0 and g == 0 and b == 0, do: nil
  defp unset_black(rgb), do: rgb

  defp statics(s) do
    time = QuakeC.float(QuakeC.global(s.qc, "time"))

    s.ext
    |> Map.get(:statics, [])
    |> Enum.reverse()
    |> Enum.map(&%{&1 | frame_time: time, carried: nil})
  end

  defp setup(s, properties) do
    {vx, vy, _} = Map.get(properties, 1, {0.0, 0.0, 0.0})
    {vw, vh, _} = Map.get(properties, 4, {320.0, 200.0, 0.0})
    {x, y, pw, ph} = Screen.to_pixels(s, {vx, vy, vw, vh})
    {w, h} = {max(trunc(pw), 1), max(trunc(ph), 1)}
    {fov_x, fov_y} = fov(properties, {max(vw, 1.0), max(vh, 1.0)})
    {pitch, yaw, roll} = Map.get(properties, 15, {0.0, 0.0, 0.0})
    origin = Map.get(properties, 11, {0.0, 0.0, 0.0})
    near = near(properties)

    camera =
      Camera.first_person(origin, yaw * :math.pi() / 180, -pitch * :math.pi() / 180,
        roll: roll * :math.pi() / 180,
        fov: fov_x * :math.pi() / 180,
        near: near
      )

    %{
      view: View.new(camera, {w, h}, pixel_aspect: pixel_aspect({w, h}, {fov_x, fov_y})),
      rect: {x, y, w / 1, h / 1},
      area: {vx, vy, max(vw, 1.0), max(vh, 1.0)},
      fov: {fov_x, fov_y}
    }
  end

  defp pixel_aspect({w, h}, {fov_x, fov_y}),
    do: w / :math.tan(fov_x * :math.pi() / 360) / (h / :math.tan(fov_y * :math.pi() / 360))

  defp near(properties) do
    case Map.get(properties, 23) do
      value when is_number(value) and value > 0 -> value / 1
      _ -> 4.0
    end
  end

  defp fov(properties, size) do
    case {Map.get(properties, 8), Map.get(properties, 203)} do
      {{fx, fy, _}, _} when fx > 0 and fy > 0 -> {fx, fy}
      {_, afov} when is_number(afov) and afov > 0 -> afov(afov, size)
      _ -> afov(90.0, size)
    end
  end

  defp afov(afov, {w, h}) do
    afov = afov |> max(0.001) |> min(170.0)

    if w / 4 < h / 3 do
      y = afov
      x = calc_fov(afov, h, w)
      if x > 170, do: {170.0, calc_fov(afov, w, h)}, else: {x, y}
    else
      ty = :math.tan(afov * :math.pi() / 360.0) * (3.0 / 4.0)
      tx = ty * w / h
      {:math.atan(tx) * (360.0 / :math.pi()), :math.atan(ty) * (360.0 / :math.pi())}
    end
  end

  defp calc_fov(fov_x, width, height) do
    x = width / :math.tan(fov_x / 360 * :math.pi())
    :math.atan(height / x) * 360 / :math.pi()
  end

  defp visible_leaves(s, view, properties) do
    if QuakeC.float(Map.get(properties, 19, 1.0)) != 0 do
      s.bsp |> Bsp.visible_leaves(Bsp.leaf_at(s.bsp, view.origin)) |> MapSet.new()
    end
  end

  defp shown?(_s, %{flags: flags}, _visible) when band(flags, 2) != 0, do: false
  defp shown?(_s, _thing, nil), do: true
  defp shown?(_s, %{flags: flags}, _visible) when band(flags, 1 ||| 4) != 0, do: true

  defp shown?(s, %{absmin: mins, absmax: maxs} = thing, visible) do
    {mins, maxs} = if mins == maxs, do: {thing.origin, thing.origin}, else: {mins, maxs}
    s.bsp |> Bsp.leaves_touching(mins, maxs) |> Enum.any?(&MapSet.member?(visible, &1))
  end

  defp brush?(s, thing), do: match?(%{name: "*" <> _}, Models.get(s, thing.model))

  defp liquid(%Cauldron3D.Texture{width: w, height: h}),
    do: [
      amplitude: {0.125 * w, 0.125 * h},
      wavelength: {2 * :math.pi() * h, 2 * :math.pi() * w},
      speed: 1 / (2 * :math.pi())
    ]

  defp rtlights(lights, styles) do
    for %{radius: radius} = light <- lights, radius > 0 do
      {value, {sr, sg, sb}} = Map.get(styles, light.style, {264, {1.0, 1.0, 1.0}})
      {r, g, b} = light.colour
      k = value / 255
      {forward, right, up} = Angles.vectors(light.angles)

      %{
        origin: light.origin,
        radius: radius,
        colour: {r * sr * k, g * sg * k, b * sb * k},
        fov: light.fov,
        axes: {forward, right, up}
      }
    end
    |> Enum.reject(fn %{colour: {r, g, b}} -> r < 0.001 and g < 0.001 and b < 0.001 end)
  end

  @doc """
  Brush entity `thing` as `Cauldron3D.Bsp.Draw` draws it: `%{model:, origin:, axes:,
  scale:, tint:, blend:, depth:, alpha_test:, light:}`, `light` the world's light map,
  fixed (`:fixed`) for draw flags 7 and scrolling (`:scroll`) for a glow modulation
  green of 0.5.
  """
  @spec brush_model(map(), map(), map()) :: map()
  def brush_model(s, thing, world_light) do
    %{name: "*" <> number} = Models.get(s, thing.model)
    {r, g, b} = thing.colormod || {1.0, 1.0, 1.0}
    {gr, gg, gb} = thing.glowmod

    light =
      if band(thing.drawflags, 7) == 7,
        do: Lighting.absolute(world_light, thing.abslight),
        else: world_light

    light = if gg == 0.5, do: Map.put(light, :scroll, s.time * (gb * 1024) * -0.01), else: light

    %{
      model: String.to_integer(number),
      origin: placed_origin(thing),
      axes: placed_axes(thing),
      scale: thing.scale,
      tint: {r, g, b, thing.alpha},
      blend: blend(thing),
      depth: depth(thing),
      alpha_test: if(gr == 0.5, do: 0.6),
      light: light
    }
  end

  defp placed_origin(%{flags: flags, origin: {x, y, z}} = thing) when band(flags, 1) != 0,
    do: thing |> Map.fetch!(:weapon) |> weapon_point({x, y, z})

  defp placed_origin(%{origin: origin}), do: origin

  defp placed_axes(%{flags: flags, axes: axes} = thing) when band(flags, 1) != 0,
    do: thing |> Map.fetch!(:weapon) |> weapon_axes(axes)

  defp placed_axes(%{axes: axes}), do: axes

  defp weapon_point({origin, {forward, left, up}}, {x, y, z}),
    do: origin |> Vec.madd(forward, x) |> Vec.madd(left, y) |> Vec.madd(up, z)

  defp weapon_axes({_origin, {forward, left, up}}, {a, b, c}) do
    turn = fn {x, y, z} -> Vec.scale(forward, x) |> Vec.madd(left, y) |> Vec.madd(up, z) end
    {turn.(a), turn.(b), turn.(c)}
  end

  defp model_polygons(s, things, view, styles, weapon) do
    count = length(things)

    things
    |> Enum.with_index()
    |> Enum.flat_map(fn {thing, index} ->
      case Models.get(s, thing.model) do
        %{kind: :studio, data: %Studio{} = studio} ->
          sort = model_sort(thing, 5)
          key = {sort, 1 + count - index}
          s |> studio_polygons(studio, thing, view, styles) |> Enum.map(&{key, &1})

        %{kind: :sprite, data: %Spr{} = sprite, name: name} ->
          sort = sprite_sort(thing)
          polygon = Sprites.polygon(thing, name, sprite, view, weapon)
          [{{sort, 0}, dress(polygon, thing)}]

        _ ->
          []
      end
    end)
  end

  @doc """
  Studio model `studio` of snapshot `thing` as `scene/1` draws it for `view`, lit by
  light styles `styles`: world-space polygons (`Cauldron3D.Formats.Studio.polygons/3`).
  """
  @spec studio_polygons(map(), Studio.t(), map(), View.t(), map()) :: [Polygon.t()]
  def studio_polygons(s, studio, thing, view, styles) do
    scale = thing.scale
    root = root(thing, scale)

    transforms =
      case thing.skeleton do
        nil ->
          Skeleton.pose(studio.parents, locals(studio, thing), root)

        bones ->
          bones |> Tuple.to_list() |> Enum.map(&Skeleton.concat(root, &1)) |> List.to_tuple()
      end

    {r, g, b} = thing.colormod || {1.0, 1.0, 1.0}
    shell = shell(s, thing)

    Studio.polygons(studio, transforms,
      shell: shell,
      geomsets: thing.geomsets,
      skin: thing.skin,
      light: Lighting.model(s, thing, styles, view.origin),
      ldr: true,
      colour: {r, g, b, thing.alpha},
      fatness: thing.fatness,
      scale: scale,
      eye: view.origin,
      view_right: view.right,
      blend: blend(thing),
      depth: depth(thing),
      cull: if(shell && shell.cull_back?, do: :clockwise, else: :counter_clockwise)
    )
  end

  @doc """
  The shell studio model snapshot `thing` is drawn as instead of its own skins (its
  `forceshader` names a shader whose text maps a picture, `ElixirHalfLife.Csqc.Shaders`),
  as `Cauldron3D.Formats.Studio.polygons/3` takes it, or `nil`.
  """
  @spec shell(map(), map()) :: map() | nil
  def shell(_s, %{forceshader: 0}), do: nil

  def shell(s, thing) do
    with name when is_binary(name) <- shader_name(s, thing.forceshader),
         text when is_binary(text) <- s.ext |> Map.get(:shader_texts, %{}) |> Map.get(name),
         %{map: map} = shader when is_binary(map) <- Shaders.read(text),
         %Cauldron3D.Texture{} = texture <- Pictures.get(map) do
      {r, g, b} = if shader.entity?, do: thing.colormod || {1.0, 1.0, 1.0}, else: {1.0, 1.0, 1.0}
      alpha = if thing.translucent?, do: thing.alpha, else: 1.0

      %{
        texture: texture,
        colour: {r, g, b, alpha},
        axes: placed_axes(thing),
        time: s.time,
        bulge: shader.bulge,
        scroll: shader.scroll,
        cull_back?: shader.cull_back?
      }
    else
      _ -> nil
    end
  end

  defp locals(studio, thing) do
    Studio.locals(studio, thing.frame, shown_frame(studio, thing),
      bonecontrols: thing.bonecontrols,
      subblend: thing.subblend,
      base:
        case thing.base do
          nil -> nil
          {sequence, time, last} -> {sequence, frame_count(studio, sequence, time), last}
        end
    )
  end

  defp shown_frame(studio, %{carried: nil} = thing),
    do: frame_count(studio, thing.frame, thing.frame_time)

  defp shown_frame(studio, thing),
    do: Animation.frame(sequence(studio, thing.frame), thing.carried)

  defp frame_count(studio, sequence, time), do: time * sequence(studio, sequence).fps

  defp sequence(studio, sequence) when sequence >= 0 and sequence < tuple_size(studio.sequences),
    do: elem(studio.sequences, sequence)

  defp sequence(studio, _sequence), do: elem(studio.sequences, 0)

  defp root(thing, scale) do
    {forward, left, up} = placed_axes(thing)
    {ox, oy, oz} = placed_origin(thing)
    {fx, fy, fz} = Vec.scale(forward, scale)
    {lx, ly, lz} = Vec.scale(left, scale)
    {ux, uy, uz} = Vec.scale(up, scale)
    {{fx, lx, ux, ox}, {fy, ly, uy, oy}, {fz, lz, uz, oz}}
  end

  defp dress(%Polygon{} = polygon, thing),
    do: %{polygon | blend: blend(thing), depth: depth(thing)}

  @doc "How snapshot `thing` is blended: `{:add, 1.0}`, `{:alpha, 1.0}` or `:none`."
  @spec blend(map()) :: Polygon.blend()
  def blend(thing) do
    cond do
      band(thing.effects, 32) != 0 or band(thing.flags, 8) != 0 -> {:add, 1.0}
      thing.translucent? -> {:alpha, 1.0}
      true -> :none
    end
  end

  @doc "How snapshot `thing` is depth tested: `:always`, `:near_third` or `:test`."
  @spec depth(map()) :: :always | :near_third | :test
  def depth(thing) do
    cond do
      band(thing.effects, 8192) != 0 -> :always
      band(thing.flags, 1 ||| 4) != 0 -> :near_third
      true -> :test
    end
  end

  defp model_sort(thing, sort) do
    sort =
      if band(thing.effects, 32) != 0 or band(thing.flags, 8) != 0, do: max(sort, 12), else: sort

    sort = if thing.translucent? and sort > 3 and sort < 11, do: 11, else: sort
    if band(thing.effects, 8192) != 0, do: max(sort, 13), else: sort
  end

  defp sprite_sort(thing) do
    sort = if band(thing.effects, 32) != 0 or band(thing.flags, 8) != 0, do: 12, else: 7
    sort = if thing.translucent? and sort > 3 and sort < 11, do: 11, else: sort
    if band(thing.effects, 8192) != 0, do: max(sort, 9), else: sort
  end

  defp skybox(s) do
    name = Map.get(s.ext, :sky, "desert")
    key = {__MODULE__, :sky, name}

    case :persistent_term.get(key, :unread) do
      :unread ->
        faces =
          for {face, suffix} <- [
                front: "ft",
                back: "bk",
                left: "lf",
                right: "rt",
                up: "up",
                down: "dn"
              ],
              picture = Pictures.get("gfx/env/#{name}#{suffix}"),
              into: %{},
              do: {face, picture}

        faces = if map_size(faces) == 6, do: faces, else: nil
        :persistent_term.put(key, faces)
        faces

      faces ->
        faces
    end
  end

  defp shader_name(s, number) do
    s.ext
    |> Map.get(:shaders, %{})
    |> Enum.find_value(fn {name, n} -> if n == number, do: name end)
  end

  defp put_frame(s, frame), do: Screen.put_frame(s, frame)
end
