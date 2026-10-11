defmodule ElixirHalfLife.Csqc.Scene do
  @moduledoc """
  The client program's scene builtins: clearing the scene, adding its entities (all
  those matching a draw mask, each through its `predraw`, or one at a time), making an
  entity static (drawn every frame from then on, the entity itself removed), view
  properties, drawing the scene, projecting a point to the screen and back, polygons
  built vertex by vertex, dynamic lights and their fields, decals, shaders by name (their
  text kept in `ext.shader_texts` by name), particle effects at a point and along a
  trail (`ElixirHalfLife.Csqc.Particles`), and models by number.

  The scene lives in the host's `ext.scene`: `%{entities:, polygons:, lights:, view:}`,
  each entity a snapshot of the fields `ElixirHalfLife.Csqc.Render` draws by, the view a
  map from `VF_` property number to its value. A polygon keeps its shader and flags
  after `R_EndPolygon`, so more vertices make another polygon of the same shader, until
  the scene is drawn or cleared. A dynamic light is `%{origin:, radius:, colour:, style:,
  angles:, fov:}`, numbered from 0 in the order added; it lasts the frame. An entity
  added with a `frame1time` of its own is marked as timed by the program
  (`ElixirHalfLife.Csqc.Animation.note/2`).
  """

  import Bitwise

  alias ElixirHalfLife.Csqc.{Animation, Particles, Polygons, Render, Screen}
  alias QuakeC.Exec
  alias QuakeServer.{Args, Edicts}
  alias QuakeServer.Extensions.Strings
  alias QuakeServer.Models

  @vector_properties [1, 4, 8, 11, 15, 33, 204, 205]

  @doc "Run scene builtin `builtin`."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 300, _argc), do: clear(s)

  def call(s, 301, _argc) do
    mask = trunc(Args.num(s, 0))
    drawmask = QuakeC.field_offset(s.qc, "drawmask")
    predraw = QuakeC.field_offset(s.qc, "predraw")

    Enum.reduce(1..(s.count - 1)//1, s, fn entity, acc ->
      cond do
        drawmask == nil or Edicts.free?(acc, entity) -> acc
        band(trunc(QuakeC.float(QuakeC.field_slot(acc.qc, entity, drawmask))), mask) == 0 -> acc
        true -> through_predraw(acc, entity, predraw)
      end
    end)
  end

  def call(s, 302, _argc), do: add(s, Args.int(s, 0), nil)

  def call(s, "addentity_lighting", _argc),
    do: add(s, Args.int(s, 0), {Args.vec(s, 1), Args.vec(s, 2), Args.vec(s, 3)})

  def call(s, "removeentity", _argc) do
    entity = Args.int(s, 0)
    update(s, :entities, &Enum.reject(&1, fn e -> e.entity == entity end))
  end

  def call(s, 303, _argc) do
    property = trunc(Args.num(s, 0))
    value = if property in @vector_properties, do: Args.vec(s, 1), else: Args.slot(s, 1)
    s = put_view(s, property, value)

    s =
      if property == 7,
        do: s |> put_view(1, Args.vec(s, 1)) |> put_view(4, Args.vec(s, 2)),
        else: s

    Args.return(s, 1.0)
  end

  def call(s, 309, _argc) do
    property = trunc(Args.num(s, 0))
    Args.return(s, view_property(s, property))
  end

  def call(s, 304, _argc), do: s |> Render.scene() |> put(:polygon, nil)
  def call(s, 311, _argc), do: Args.return(s, Render.project(s, Args.vec(s, 0)))
  def call(s, 310, _argc), do: Args.return(s, Render.unproject(s, Args.vec(s, 0)))

  def call(s, 69, argc) do
    entity = Args.int(s, 0)

    s =
      case Render.snapshot(s, entity, nil) do
        nil -> s
        thing -> %{s | ext: Map.update(s.ext, :statics, [thing], &[thing | &1])}
      end

    QuakeServer.Extensions.call(s, 15, argc)
  end

  def call(s, 306, argc) do
    flags = trunc(Args.num(s, 1, argc, 0.0))
    two_d? = if argc > 2, do: Args.num(s, 2) != 0, else: band(flags, 4) != 0
    put(s, :polygon, %{shader: Args.str(s, 0), flags: flags, two_d?: two_d?, vertices: []})
  end

  def call(s, 307, _argc) do
    vertex = {Args.vec(s, 0), Args.vec(s, 1), Args.vec(s, 2), Args.num(s, 3)}

    update(s, :polygon, fn polygon ->
      polygon && %{polygon | vertices: [vertex | polygon.vertices]}
    end)
  end

  def call(s, 308, _argc) do
    case scene(s) |> Map.get(:polygon) do
      %{} = polygon -> finish(s, %{polygon | vertices: Enum.reverse(polygon.vertices)})
      nil -> s
    end
  end

  def call(s, "R_EndPolygonRibbon", _argc) do
    case scene(s) |> Map.get(:polygon) do
      %{} = polygon ->
        {ds, dt, _} = Args.vec(s, 1)
        eye = view_property(s, 11)
        vertices = Enum.reverse(polygon.vertices)
        triangles = Polygons.ribbon(vertices, Args.num(s, 0), {ds, dt}, eye)
        finish(s, %{polygon | vertices: {:triangles, triangles}})

      nil ->
        s
    end
  end

  def call(s, 305, argc) do
    light = %{
      origin: Args.vec(s, 0),
      radius: Args.num(s, 1),
      colour: Args.vec(s, 2),
      style: trunc(Args.num(s, 3, argc, 0.0)),
      angles: {0.0, 0.0, 0.0},
      fov: 0.0
    }

    index = length(scene(s).lights)
    s |> update(:lights, &(&1 ++ [light])) |> Args.return(index / 1)
  end

  def call(s, 373, _argc) do
    index = Args.int(s, 0)
    field = Args.int(s, 1)

    update(s, :lights, fn lights ->
      if index >= 0 and index < length(lights),
        do: List.update_at(lights, index, &set_light(&1, field, s)),
        else: lights
    end)
  end

  def call(s, "dynamiclight_spawnstatic", _argc), do: Args.return(s, 0.0)

  def call(s, 375, _argc),
    do:
      Particles.decal(
        s,
        Args.str(s, 0),
        Args.vec(s, 1),
        Args.vec(s, 2),
        Args.vec(s, 3),
        Args.vec(s, 4),
        Args.num(s, 5)
      )

  def call(s, 337, argc) do
    direction = if argc >= 3, do: Args.vec(s, 2), else: {0.0, 0.0, 0.0}
    count = if argc >= 4, do: Args.num(s, 3), else: 1.0
    Particles.point(s, effect_name(s, Args.int(s, 0)), Args.vec(s, 1), direction, count)
  end

  def call(s, 336, _argc) do
    {effect, entity} =
      case Args.slot(s, 1) do
        number when is_float(number) and number != 0 -> {trunc(number), Args.int(s, 0)}
        _ -> {Args.int(s, 0), Args.int(s, 1)}
      end

    Particles.trail(s, effect_name(s, effect), entity, Args.vec(s, 2), Args.vec(s, 3))
  end

  def call(s, 238, argc) do
    name = Args.str(s, 0)
    shaders = Map.get(s.ext, :shaders, %{})

    {s, number} =
      case Map.get(shaders, name) do
        nil ->
          number = map_size(shaders) + 1
          {%{s | ext: Map.put(s.ext, :shaders, Map.put(shaders, name, number))}, number}

        number ->
          {s, number}
      end

    s =
      if argc > 1 and not Map.has_key?(Map.get(s.ext, :shader_texts, %{}), name),
        do: %{
          s
          | ext:
              Map.update(
                s.ext,
                :shader_texts,
                %{name => Args.str(s, 1)},
                &Map.put(&1, name, Args.str(s, 1))
              )
        },
        else: s

    Args.return(s, number / 1)
  end

  def call(s, "remapshader", _argc),
    do: %{
      s
      | ext:
          Map.update(
            s.ext,
            :remaps,
            %{Args.str(s, 0) => Args.str(s, 1)},
            &Map.put(&1, Args.str(s, 0), Args.str(s, 1))
          )
    }

  def call(s, 333, _argc) do
    entity = Args.int(s, 0)
    index = Args.int(s, 1)
    name = Models.name(s, index)
    model = Models.get(s, index)

    s
    |> Edicts.put(entity, "model", name)
    |> Edicts.put(entity, "modelindex", index / 1)
    |> then(fn acc ->
      if model,
        do:
          acc |> Edicts.put(entity, "mins", model.mins) |> Edicts.put(entity, "maxs", model.maxs),
        else: acc
    end)
  end

  def call(s, 376, argc) do
    entity = Args.int(s, 0)
    text = if argc > 2, do: Args.str(s, 2), else: ElixirHalfLife.Assets.read(Args.str(s, 1)) || ""
    put_skin(s, entity, geomsets(text))
  end

  def call(s, 377, argc) do
    text = if argc > 1, do: Args.str(s, 1), else: ElixirHalfLife.Assets.read(Args.str(s, 0)) || ""
    skins = Map.get(s.ext, :skin_objects, %{})
    handle = map_size(skins) + 1

    %{s | ext: Map.put(s.ext, :skin_objects, Map.put(skins, handle, geomsets(text)))}
    |> Args.return(handle / 1)
  end

  def call(s, 378, _argc) do
    sets = s.ext |> Map.get(:skin_objects, %{}) |> Map.get(Args.int(s, 1), %{})
    put_skin(s, Args.int(s, 0), sets)
  end

  def call(s, 374, _argc) do
    number = Args.int(s, 0)

    name =
      s.ext
      |> Map.get(:effects, %{})
      |> Enum.find_value("", fn {name, n} -> if n == number, do: name end)

    Args.return(s, name)
  end

  def call(s, 355, argc) do
    {tokens, s} =
      if argc > 0 do
        text = Args.str(s, 0)
        text = if text == "", do: s.ext |> Map.get(:entity_text, ""), else: text
        {Strings.tokenize(text), s}
      else
        {Map.get(s.ext, :entity_tokens, :unset), s}
      end

    tokens =
      if tokens == :unset,
        do: Strings.tokenize(Map.get(s.ext, :entity_text, "")),
        else: tokens

    case tokens do
      [{token, _, _} | rest] ->
        %{s | ext: Map.put(s.ext, :entity_tokens, rest)} |> Args.return(token)

      [] ->
        %{s | ext: Map.put(s.ext, :entity_tokens, [])} |> Args.return(0)
    end
  end

  def call(s, 359, argc) do
    name = Args.str(s, 0)
    kinds = Args.str(s, 1)

    values =
      kinds
      |> String.graphemes()
      |> Enum.take(min(max(argc - 2, 0), 6))
      |> Enum.with_index(2)
      |> Enum.take_while(fn {kind, _} -> kind in ~w(s f i u v e) end)
      |> Enum.map(fn
        {"v", i} -> {"v", Args.vec(s, i)}
        {"e", i} -> {"e", trunc(QuakeC.float(QuakeC.field(s.qc, Args.int(s, i), "entnum")))}
        {"s", i} -> {"s", Args.str(s, i)}
        {kind, i} when kind in ["i", "u"] -> {kind, Args.int(s, i)}
        {kind, i} -> {kind, Args.num(s, i)}
      end)

    event = {name, values}
    %{s | ext: Map.update(s.ext, :sent_events, [event], &(&1 ++ [event]))}
  end

  @doc "The scene emptied and the view put back to the whole screen, a 90 degree view at the world's origin."
  @spec clear(map()) :: map()
  def clear(s) do
    {w, h} =
      case Screen.virtual_size(s) do
        {width, height} -> {width / 1, height / 1}
        nil -> {320.0, 200.0}
      end

    view = %{
      1 => {0.0, 0.0, 0.0},
      4 => {w, h, 0.0},
      8 => {0.0, 0.0, 0.0},
      11 => {0.0, 0.0, 0.0},
      15 => {0.0, 0.0, 0.0},
      19 => 1.0,
      200 => 1.0
    }

    s = Particles.clear_scene(s)

    %{
      s
      | ext:
          Map.put(s.ext, :scene, %{
            entities: [],
            polygons: [],
            lights: [],
            view: view,
            polygon: nil
          })
    }
  end

  defp effect_name(s, number) do
    s.ext
    |> Map.get(:effects, %{})
    |> Enum.find_value("", fn {name, n} -> if n == number, do: name end)
  end

  @doc "The scene, cleared when there is none yet."
  @spec scene(map()) :: map()
  def scene(s) do
    case Map.get(s.ext, :scene) do
      nil -> s |> clear() |> scene()
      scene -> scene
    end
  end

  defp set_light(light, 0, s), do: %{light | origin: Args.vec(s, 2)}
  defp set_light(light, 1, s), do: %{light | colour: Args.vec(s, 2)}
  defp set_light(light, 2, s), do: %{light | radius: Args.num(s, 2)}
  defp set_light(light, 4, s), do: %{light | style: Args.int(s, 2)}
  defp set_light(light, 5, s), do: %{light | angles: Args.vec(s, 2)}
  defp set_light(light, 6, s), do: %{light | fov: Args.num(s, 2)}
  defp set_light(light, _field, _s), do: light

  defp finish(s, %{two_d?: true, vertices: {:triangles, triangles}} = polygon) do
    triangles
    |> Enum.reduce(s, &Render.flat_polygon(&2, %{polygon | vertices: &1}))
    |> put(:polygon, %{polygon | vertices: []})
  end

  defp finish(s, %{two_d?: true} = polygon),
    do: s |> Render.flat_polygon(polygon) |> put(:polygon, %{polygon | vertices: []})

  defp finish(s, polygon),
    do:
      s
      |> update(:polygons, &[polygon | &1])
      |> put(:polygon, %{polygon | vertices: []})

  defp geomsets(text) do
    for line <- String.split(text, "\n"),
        ["geomset", part, model | _] <- [String.split(line)],
        {part, _} <- [Integer.parse(part)],
        {model, _} <- [Integer.parse(model)],
        into: %{},
        do: {part, model}
  end

  defp put_skin(s, entity, sets),
    do: %{s | ext: Map.update(s.ext, :geomsets, %{entity => sets}, &Map.put(&1, entity, sets))}

  defp through_predraw(s, entity, nil), do: add(s, entity, nil)

  defp through_predraw(s, entity, predraw) do
    case QuakeC.field_slot(s.qc, entity, predraw) do
      function when is_integer(function) and function > 0 ->
        s =
          QuakeServer.Server.keeping_self(s, fn s ->
            s
            |> QuakeServer.Server.set_globals(entity, 0)
            |> Exec.call(function, s.builtins, QuakeServer.Server.exec_opts(s))
          end)

        if Edicts.free?(s, entity) or QuakeC.float(QuakeC.slot(s.qc, 1)) != 0,
          do: s,
          else: add(s, entity, nil)

      _ ->
        add(s, entity, nil)
    end
  end

  defp add(s, entity, lighting) do
    s = Animation.note(s, entity)
    snapshot = Render.snapshot(s, entity, lighting)
    if snapshot, do: update(s, :entities, &[snapshot | &1]), else: s
  end

  defp view_property(s, 2), do: s |> view_property(1) |> elem(0)
  defp view_property(s, 3), do: s |> view_property(1) |> elem(1)
  defp view_property(s, 5), do: s |> view_property(4) |> elem(0)
  defp view_property(s, 6), do: s |> view_property(4) |> elem(1)
  defp view_property(s, n) when n in 12..14, do: s |> view_property(11) |> elem(n - 12)
  defp view_property(s, n) when n in 16..18, do: s |> view_property(15) |> elem(n - 16)

  defp view_property(s, 204), do: flat_size(Screen.virtual_size(s))
  defp view_property(s, 205), do: flat_size(Screen.size(s))

  defp view_property(s, n), do: Map.get(scene(s).view, n, 0.0)

  defp flat_size({width, height}), do: {width / 1, height / 1, 0.0}
  defp flat_size(nil), do: {0.0, 0.0, 0.0}

  defp put_view(s, property, value) when property in [2, 3] do
    {x, y, z} = view_property(s, 1)

    put_view(
      s,
      1,
      if(property == 2, do: {QuakeC.float(value), y, z}, else: {x, QuakeC.float(value), z})
    )
  end

  defp put_view(s, property, value) when property in [5, 6] do
    {x, y, z} = view_property(s, 4)

    put_view(
      s,
      4,
      if(property == 5, do: {QuakeC.float(value), y, z}, else: {x, QuakeC.float(value), z})
    )
  end

  defp put_view(s, property, value) when property in 12..14,
    do: put_view(s, 11, put_elem(view_property(s, 11), property - 12, QuakeC.float(value)))

  defp put_view(s, property, value) when property in 16..18,
    do: put_view(s, 15, put_elem(view_property(s, 15), property - 16, QuakeC.float(value)))

  defp put_view(s, 9, value),
    do: put_view(s, 8, put_elem(view_property(s, 8), 0, QuakeC.float(value)))

  defp put_view(s, 10, value),
    do: put_view(s, 8, put_elem(view_property(s, 8), 1, QuakeC.float(value)))

  defp put_view(s, 8, value) when is_number(value),
    do: put_view(s, 8, {value / 1, value / 1, 0.0})

  defp put_view(s, property, value),
    do: update(s, :view, &Map.put(&1, property, value))

  defp update(s, key, change),
    do: %{s | ext: Map.put(s.ext, :scene, Map.update!(scene(s), key, change))}

  defp put(s, key, value), do: %{s | ext: Map.put(s.ext, :scene, Map.put(scene(s), key, value))}
end
