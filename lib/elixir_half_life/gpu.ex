defmodule ElixirHalfLife.Gpu do
  @moduledoc """
  Half-Life's picture described for a graphics card: the `:gpu` of
  `ElixirHalfLife.Client`'s scene (`Cauldron2D.Client.Game`).

      gpu = ElixirHalfLife.Gpu.scene(program, overlay)
      {changes, cache} = gpu.(target, nil, {1280, 720}, 1.0)

  Each call runs one client frame (`ElixirHalfLife.ClientProgram.gpu_picture/4`) and
  answers its `CauldronGPU.Stream` changes:

    * the 2D layer as `{:overlay, texture, :premultiplied}` (`ElixirHalfLife.Gpu.Overlay`),
      one texture put again each tick
    * the camera at the view's place and turn, drawn into the view's box on the screen
      (`viewport`) with the view's vertical field of view and its shape on screen
      (`aspect`, the tangents of the half fields of view across and down), placed
      without moving from the last tick (`snap`)
    * the world (`ElixirHalfLife.Gpu.World`) when the view draws it, brush entities
      (`ElixirHalfLife.Gpu.Brushes`), studio models with their poses
      (`ElixirHalfLife.Gpu.Studios`), and the sprites, particles, marks, polygons and
      studio models' chrome as one mesh for each depth rule (`ElixirHalfLife.Gpu.Polygons`):
      tested, held (`in_front`) and over everything (`depth_test: false`); each instance keeps its id while its key
      (entity, model and how many of those came before it) is in the scene, and is
      removed when it goes
    * the light styles 0 to 63 (`ElixirHalfLife.Gpu.Light.styles/1`), the dynamic lights
      (`ElixirHalfLife.Gpu.Lights`), and an environment lit in display colours
      (`light_space: :display`), with black sky shading, no ambient light, fog,
      reflections or bloom, colours clamped, the client's gamma ramp (`gamma` 1 over
      its `gamma`, its `contrast` and `brightness`) and the level's sky box
      (`ElixirHalfLife.Gpu.Sky`)

  A frame that describes no scene (the level loading, the client disconnected) changes
  only the overlay. The cache holds the level's uploads; when the map changes they are
  released and the new map's world is uploaded.
  """

  alias CauldronGPU.Environment
  alias ElixirHalfLife.ClientProgram

  alias ElixirHalfLife.Gpu.{
    Brushes,
    Light,
    Lights,
    Overlay,
    Pictures,
    Polygons,
    Sky,
    Space,
    Studios,
    World
  }

  @type cache :: map()

  @depths [:test, :near_third, :always]

  @doc "The scene's `:gpu` for client program `program`, with `overlay` drawn over each frame's 2D layer."
  @spec scene(pid(), (Cauldron3D.Frame.t() -> Cauldron3D.Frame.t()) | nil) ::
          (CauldronGPU.Target.t(), cache() | nil, {pos_integer(), pos_integer()}, number() ->
             {[CauldronGPU.Stream.change()], cache()})
  def scene(program, overlay) do
    fn target, cache, size, aspect ->
      picture = ClientProgram.gpu_picture(program, size, aspect, overlay)
      changes(target, cache || new(), picture)
    end
  end

  @doc "A cache with nothing uploaded."
  @spec new() :: cache()
  def new do
    %{
      map: nil,
      world: nil,
      sky: nil,
      brushes: Brushes.new(),
      studios: Studios.new(),
      layers: new_layers(),
      pictures: Pictures.new(),
      overlay: nil,
      ids: %{},
      next_id: 1,
      lights: 0
    }
  end

  defp new_layers, do: Map.new(@depths, &{&1, Polygons.new()})

  @doc "The changes for client frame `picture` (`ElixirHalfLife.ClientProgram.gpu_picture/4`) and the cache after."
  @spec changes(CauldronGPU.Target.t(), cache(), map()) ::
          {[CauldronGPU.Stream.change()], cache()}
  def changes(target, cache, %{overlay: layer, scene: scene, gamma: ramp, tone: tone}) do
    {overlay_changes, cache} = overlay(target, cache, Overlay.texture(layer, tone))
    {scene_changes, cache} = scene_changes(target, cache, scene, ramp)
    {scene_changes ++ overlay_changes, cache}
  end

  defp overlay(target, %{overlay: nil} = cache, texture) do
    handle = CauldronGPU.Target.texture(target, texture)
    {[{:overlay, handle, :premultiplied}], %{cache | overlay: handle}}
  end

  defp overlay(_target, %{overlay: handle} = cache, texture),
    do: {[{:texture, handle.id, texture}, {:overlay, handle, :premultiplied}], cache}

  defp scene_changes(_target, cache, nil, _ramp), do: {[], cache}

  defp scene_changes(target, cache, scene, ramp) do
    {level_changes, cache} = level(target, cache, scene.map)
    cache = sky(target, cache, scene.sky)

    {brush_changes, brushes, brush_state} =
      Brushes.changes(cache.brushes, target, cache.world.bsp, scene.brushes)

    {studio_changes, studios, studio_state} =
      Studios.changes(cache.studios, target, scene.studios)

    cache = %{cache | brushes: brush_state, studios: studio_state}
    polygons = Enum.flat_map(scene.studios, & &1.chrome) ++ scene.polygons
    {polygon_changes, layer_entries, cache} = layers(target, cache, polygons)
    entries = world_entry(cache.world, scene.world?) ++ brushes ++ studios ++ layer_entries
    {instance_changes, cache} = instances(cache, entries)
    {light_changes, cache} = lights(cache, Lights.lights(scene.lights))

    {level_changes ++
       [
         environment(cache.sky, ramp),
         camera(scene),
         {:light_styles, Light.styles(scene.styles)}
       ] ++
       brush_changes ++ studio_changes ++ polygon_changes ++ instance_changes ++ light_changes,
     cache}
  end

  defp layers(target, cache, polygons) do
    by_depth = Enum.group_by(polygons, & &1.depth)

    Enum.reduce(@depths, {[], [], cache}, fn depth, {changes, entries, cache} ->
      {changed, instance, state, pictures} =
        Polygons.changes(
          Map.fetch!(cache.layers, depth),
          target,
          Map.get(by_depth, depth, []),
          cache.pictures
        )

      cache = %{cache | layers: Map.put(cache.layers, depth, state), pictures: pictures}
      {changes ++ changed, entries ++ layer_entry(depth, instance), cache}
    end)
  end

  defp layer_entry(_depth, nil), do: []
  defp layer_entry(:test, instance), do: [{{:polygons, :test}, instance}]

  defp layer_entry(:near_third, instance),
    do: [{{:polygons, :near_third}, %{instance | in_front: true}}]

  defp layer_entry(:always, instance),
    do: [{{:polygons, :always}, %{instance | depth_test: false}}]

  defp lights(cache, lights) do
    placed = lights |> Enum.with_index(1) |> Enum.map(fn {light, id} -> {:light, id, light} end)
    removed = for id <- (length(lights) + 1)..cache.lights//1, do: {:remove_light, id}
    {placed ++ removed, %{cache | lights: length(lights)}}
  end

  defp camera(%{camera: camera, rect: {x, y, w, h}, screen: {width, height}}) do
    {fov_x, fov_y} = camera.fov

    %{
      Space.camera(camera.origin, camera.forward, camera.right, camera.up, fov_y, camera.near)
      | viewport: {x / width, y / height, w / width, h / height},
        aspect: :math.tan(fov_x * :math.pi() / 360) / :math.tan(fov_y * :math.pi() / 360)
    }
  end

  defp level(_target, %{map: map} = cache, map), do: {[], cache}

  defp level(target, cache, map) do
    removals = Enum.map(Map.values(cache.ids), &{:remove_instance, &1})
    if cache.world, do: World.release(target, cache.world)
    Brushes.release(cache.brushes, target)
    Studios.release(cache.studios, target)
    Enum.each(Map.values(cache.layers), &Polygons.release(&1, target))
    Pictures.release(cache.pictures, target)

    {removals,
     %{
       cache
       | map: map,
         world: World.upload(target, map),
         brushes: Brushes.new(),
         studios: Studios.new(),
         layers: new_layers(),
         pictures: Pictures.new(),
         ids: %{}
     }}
  end

  defp sky(_target, %{sky: %{name: name}} = cache, name), do: cache

  defp sky(target, cache, name) do
    if cache.sky, do: Sky.release(target, cache.sky)
    %{cache | sky: Sky.upload(target, name)}
  end

  defp environment(sky, {gamma, contrast, brightness}) do
    %Environment{
      light_space: :display,
      gamma: if(gamma > 0, do: 1 / gamma, else: 1.0),
      contrast: contrast,
      brightness: brightness,
      sky_top: {0.0, 0.0, 0.0},
      sky_horizon: {0.0, 0.0, 0.0},
      sky_ground: {0.0, 0.0, 0.0},
      ambient: {0.0, 0.0, 0.0},
      ambient_intensity: 0.0,
      fog_density: 0.0,
      exposure: 1.0,
      reflections: 0.0,
      bloom_strength: 0.0,
      render_scale: 1.0,
      tone_map: :clamp,
      sky_picture: Sky.picture(sky)
    }
  end

  defp world_entry(world, true) do
    case World.instance(world) do
      nil -> []
      instance -> [{:world, instance}]
    end
  end

  defp world_entry(_world, false), do: []

  defp instances(cache, entries) do
    {changes, poses, ids, next_id} =
      Enum.reduce(entries, {[], [], %{}, cache.next_id}, fn entry,
                                                            {changes, poses, ids, next_id} ->
        {key, instance, pose} = entry_parts(entry)
        {id, next_id} = id_for(cache.ids, key, next_id)
        poses = if pose, do: [pose.(id) | poses], else: poses
        {[{:instance, id, instance} | changes], poses, Map.put(ids, key, id), next_id}
      end)

    removals = for {key, id} <- cache.ids, not Map.has_key?(ids, key), do: {:remove_instance, id}

    {Enum.reverse(changes) ++ Enum.reverse(poses) ++ removals,
     %{cache | ids: ids, next_id: next_id}}
  end

  defp entry_parts({key, instance, pose}), do: {key, instance, pose}
  defp entry_parts({key, instance}), do: {key, instance, nil}

  defp id_for(ids, key, next_id) do
    case ids do
      %{^key => id} -> {id, next_id}
      _ -> {next_id, next_id + 1}
    end
  end
end
