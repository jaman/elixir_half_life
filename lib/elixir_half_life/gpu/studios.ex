defmodule ElixirHalfLife.Gpu.Studios do
  @moduledoc """
  Studio models on the graphics card (`ElixirHalfLife.Csqc.Described`'s `:studios`),
  through `CauldronGPU.StudioModel`: a model is uploaded once for each choice of body
  part models an entity shows, nearest-sampled, and posed each tick by the bones the
  software picture poses it by.

  An entity's materials (`ElixirHalfLife.Gpu.Looks`) are its own, one per mesh part:
  the skin family's texture times the entity's colour modulation, lit by the instance's
  `shading` (the entity's light, `ElixirHalfLife.Csqc.Described`); opaque and cut away
  at half alpha where the software picture cuts the texture out (masked or alpha-solid
  and not fullbright), laid over by the entity's alpha, or added. A part whose skin
  reference has no texture, and a chrome-textured part, are cut away entirely; chrome is
  drawn from the description's `:chrome` polygons (`ElixirHalfLife.Gpu`). A held model
  (depth `:near_third`) is drawn `in_front`, one drawn over everything (`:always`) with
  `depth_test: false`.

  An entity with a `:shell` is drawn as that shell instead: every part painted with the
  shell's picture, unlit, its colour and alpha, its coordinates from the view reflected
  in the surface (`uv_from: :reflection`) moving by the shell's scroll, pushed out by its
  bulge (`swell`), and seen from both sides when the shell culls back faces.

      {changes, entries, studios} = ElixirHalfLife.Gpu.Studios.changes(studios, target, described)
  """

  import Bitwise, only: [band: 2]

  alias Cauldron3D.Formats.Studio
  alias Cauldron3D.Skeleton
  alias CauldronGPU.{Instance, Material, Pose, StudioModel}
  alias ElixirHalfLife.Assets
  alias ElixirHalfLife.Gpu.{Light, Looks, Materials, Pictures, Space}

  @type t :: %{models: map(), materials: Materials.t(), shells: Pictures.t()}

  @doc "No studio models uploaded."
  @spec new() :: t()
  def new, do: %{models: %{}, materials: Materials.new(), shells: Pictures.new()}

  @doc """
  The changes, `{key, instance}` entries and the pose changes (to follow the instances)
  for studio entities `described`.
  """
  @spec changes(t(), CauldronGPU.Target.t(), [map()]) ::
          {[CauldronGPU.Stream.change()],
           [{term(), Instance.t(), (pos_integer() -> CauldronGPU.Stream.change())}], t()}
  def changes(state, target, described) do
    {changes, entries, state} =
      Enum.reduce(described, {[], [], state}, fn studio, {changes, entries, state} ->
        state = ensure_model(state, target, studio)

        case Map.fetch!(state.models, {studio.name, studio.bodies}) do
          nil ->
            {changes, entries, state}

          model ->
            {materials, changed, state} = entity_materials(state, target, model, studio)
            bones = bones(model, studio.bones)
            instance = instance(model, materials, studio)
            entry = {{:studio, studio.key}, instance, &{:pose, &1, %Pose{bones: bones}}}
            {changes ++ changed, [entry | entries], state}
        end
      end)

    {changes, Enum.reverse(entries),
     %{state | materials: Materials.sweep(state.materials, target)}}
  end

  @doc "Releases every handle."
  @spec release(t(), CauldronGPU.Target.t()) :: :ok
  def release(state, target) do
    for {_key, model} <- state.models, model != nil, handle <- StudioModel.handles(model) do
      CauldronGPU.Target.release(target, handle)
    end

    Materials.release(state.materials, target)
    Pictures.release(state.shells, target)
  end

  defp ensure_model(%{models: models} = state, target, %{name: name, bodies: bodies}) do
    key = {name, bodies}

    if Map.has_key?(models, key),
      do: state,
      else: %{state | models: Map.put(models, key, upload(target, name, bodies))}
  end

  defp upload(target, name, bodies) do
    case Assets.model(name) do
      %{kind: :studio, data: %Studio{} = studio} ->
        StudioModel.upload(target, studio, bodies: bodies, filter: :nearest)

      _ ->
        nil
    end
  end

  defp instance(model, materials, studio) do
    %Instance{
      mesh: model.mesh,
      materials: materials,
      transform: Space.transform(studio.origin, studio.axes, studio.scale),
      shading: shading(studio.shading),
      in_front: studio.depth == :near_third,
      depth_test: studio.depth != :always,
      swell: swell(studio.shell),
      shadows: false,
      snap: true
    }
  end

  defp bones(model, posed) do
    posed
    |> Enum.zip(Tuple.to_list(model.unbind))
    |> Enum.map(fn {bone, unbind} -> flatten(Skeleton.concat(bone, unbind)) end)
  end

  defp flatten({row0, row1, row2}),
    do: Tuple.to_list(row0) ++ Tuple.to_list(row1) ++ Tuple.to_list(row2)

  defp swell(%{bulge: {width, height, speed}}), do: {width, height, speed}
  defp swell(_shell), do: nil

  defp entity_materials(state, target, model, %{shell: %{} = shell} = studio) do
    {handle, shells} = Pictures.get(state.shells, target, shell.texture, :straight)
    {r, g, b, a} = shell.colour

    material =
      Looks.material(handle, Light.linear({r, g, b}), a, blend(studio.blend),
        uv_from: :reflection,
        scroll: shell.scroll,
        double_sided: shell.cull_back?
      )

    part_materials(%{state | shells: shells}, target, model, studio, fn _ref -> material end)
  end

  defp entity_materials(state, target, model, studio),
    do: part_materials(state, target, model, studio, &material(model, studio, &1))

  defp part_materials(state, target, model, studio, material_for) do
    {handles, {changes, materials}} =
      model.skin_refs
      |> Enum.with_index()
      |> Enum.map_reduce({[], state.materials}, fn {ref, part}, {changes, materials} ->
        material = material_for.(ref)

        {handle, changed, materials} =
          Materials.put(materials, target, {studio.key, part}, material)

        {handle, {changes ++ changed, materials}}
      end)

    {handles, changes, %{state | materials: materials}}
  end

  defp material(model, studio, ref) do
    case texture_index(model.studio, studio.skin, ref) do
      nil ->
        %Material{unlit: true, alpha_cutoff: 2.0}

      index ->
        studio_material(model, studio, index, elem(model.studio.texture_flags, index))
    end
  end

  defp studio_material(_model, _studio, _index, flags) when band(flags, 0x02) != 0,
    do: %Material{unlit: true, alpha_cutoff: 2.0}

  defp studio_material(model, studio, index, flags) do
    blend = blend(studio.blend)
    cutout? = blend == :none and band(flags, 0x04) == 0 and band(flags, 0x840) != 0

    Looks.material(elem(model.textures, index), Light.linear(studio.colour), studio.alpha, blend,
      cutoff: if(cutout?, do: 0.5, else: 0.0),
      shaded: true
    )
  end

  defp shading({ambient, directional, direction}),
    do: {ambient, directional, Space.direction(direction)}

  defp blend({:add, _amount}), do: :add
  defp blend({:alpha, _amount}), do: :alpha
  defp blend(:none), do: :none

  defp texture_index(studio, family, ref) do
    families = tuple_size(studio.skins)
    family = if family >= 0 and family < families, do: family, else: 0

    with true <- families > 0,
         skins = elem(studio.skins, family),
         true <- ref < tuple_size(skins),
         index = elem(skins, ref),
         true <- index >= 0 and index < tuple_size(studio.textures),
         true <- elem(studio.textures, index) != nil do
      index
    else
      _ -> nil
    end
  end
end
