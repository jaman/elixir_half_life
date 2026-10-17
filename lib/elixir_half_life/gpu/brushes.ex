defmodule ElixirHalfLife.Gpu.Brushes do
  @moduledoc """
  Brush entities (`*N` models) on the graphics card, each drawn as the software picture
  draws it (`ElixirHalfLife.Csqc.Described`'s `:brushes`).

  Each brush model is uploaded the first time an entity shows it: one mesh in map
  units, a part per texture and lightmap page, its faces' lightmaps (from the map as
  `ElixirHalfLife.Gpu.Light` gives them) packed into pages of its own
  (`CauldronGPU.Bsp.Atlas`). Its textures are uploaded once each, nearest-sampled, a `{`
  texture with colour 255 as its palette colour, or see-through for an entity cut away
  by alpha test.

  An entity's materials (`ElixirHalfLife.Gpu.Looks`) are its own: lit by the lightmaps,
  or unlit at its fixed level, and black where a face has no lightmap; tinted by its
  colour modulation; opaque, laid over by its alpha, or added; cut away at its alpha
  test; its textures moving by its scroll (`uv_scroll`, its texels a second over each
  texture's width). Sky faces show the sky and liquids ripple, unlit, as the world's do.
  A held entity is drawn `in_front`, one drawn over everything with `depth_test: false`.

      {changes, entries, brushes} = ElixirHalfLife.Gpu.Brushes.changes(brushes, target, bsp, described)
  """

  alias Cauldron3D.Bsp.Face
  alias CauldronGPU.Bsp.Atlas
  alias CauldronGPU.{Instance, Mesh, Texture}
  alias ElixirHalfLife.Gpu.{Light, Looks, Materials, Space}

  @page_size 1024

  @type t :: %{models: map(), pictures: map(), materials: Materials.t()}

  @doc "No brush models uploaded."
  @spec new() :: t()
  def new, do: %{models: %{}, pictures: %{}, materials: Materials.new()}

  @doc """
  The changes and `{key, instance}` entries for brush entities `described`, of map
  `bsp` (lit as `ElixirHalfLife.Gpu.Light.lightmaps/1` gives it).
  """
  @spec changes(t(), CauldronGPU.Target.t(), Cauldron3D.Bsp.t(), [map()]) ::
          {[CauldronGPU.Stream.change()], [{term(), Instance.t()}], t()}
  def changes(state, target, bsp, described) do
    {changes, entries, state} =
      described
      |> Enum.reduce({[], [], state}, fn brush, {changes, entries, state} ->
        state = ensure_model(state, target, bsp, brush.model)

        case Map.fetch!(state.models, brush.model) do
          nil ->
            {changes, entries, state}

          model ->
            {materials, changed, state} = entity_materials(state, target, bsp, model, brush)
            entry = {{:brush, brush.key}, instance(model, materials, brush)}
            {changes ++ changed, [entry | entries], state}
        end
      end)

    {changes, Enum.reverse(entries),
     %{state | materials: Materials.sweep(state.materials, target)}}
  end

  @doc "Releases every handle."
  @spec release(t(), CauldronGPU.Target.t()) :: :ok
  def release(state, target) do
    for {_number, %{mesh: mesh, pages: pages}} <- state.models, handle <- [mesh | pages] do
      CauldronGPU.Target.release(target, handle)
    end

    Enum.each(Map.values(state.pictures), &CauldronGPU.Target.release(target, &1))
    Materials.release(state.materials, target)
  end

  defp instance(model, materials, brush) do
    %Instance{
      mesh: model.mesh,
      materials: materials,
      transform: Space.transform(brush.origin, brush.axes, brush.scale),
      in_front: brush.depth == :near_third,
      depth_test: brush.depth != :always,
      shadows: false,
      snap: true
    }
  end

  defp ensure_model(%{models: models} = state, _target, _bsp, number)
       when is_map_key(models, number),
       do: state

  defp ensure_model(state, target, bsp, number),
    do: %{state | models: Map.put(state.models, number, upload_model(target, bsp, number))}

  defp upload_model(target, bsp, number) when number < tuple_size(bsp.models) do
    model = elem(bsp.models, number)

    faces =
      for index <- model.first_face..(model.first_face + model.face_count - 1)//1,
          face = elem(bsp.faces, index),
          elem(bsp.textures, face.texture).kind != :hidden,
          length(face.points) >= 3,
          do: {index, face}

    if faces == [], do: nil, else: upload_faces(target, bsp, faces)
  end

  defp upload_model(_target, _bsp, _number), do: nil

  defp upload_faces(target, bsp, faces) do
    atlas_bsp = only_faces(bsp, faces)
    atlas = Atlas.pack(atlas_bsp, @page_size)
    pages = Enum.map(Atlas.textures(atlas, atlas_bsp), &CauldronGPU.Target.texture(target, &1))

    groups =
      faces
      |> Enum.group_by(fn {index, face} -> {face.texture, Atlas.page(atlas, index)} end)
      |> Enum.sort_by(fn {key, _} -> key end)

    %{
      mesh: CauldronGPU.Target.mesh(target, mesh(bsp, groups, atlas)),
      parts: Enum.map(groups, fn {key, _} -> key end),
      pages: pages,
      slots: atlas.slots
    }
  end

  defp only_faces(bsp, faces) do
    kept = MapSet.new(faces, &elem(&1, 0))

    lit =
      bsp.faces
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {face, index} ->
        if MapSet.member?(kept, index), do: face, else: %{face | lightmap: nil}
      end)
      |> List.to_tuple()

    %{bsp | faces: lit}
  end

  defp mesh(bsp, groups, atlas) do
    {vertices, indices, parts, _count, _first} =
      Enum.reduce(groups, {[], [], [], 0, 0}, fn {_key, group},
                                                 {vertices, indices, parts, count, first} ->
        {group_vertices, group_indices, count} = triangles(bsp, group, atlas, count)
        added = div(byte_size(group_indices), 4)

        {[vertices, group_vertices], [indices, group_indices], [{first, added} | parts], count,
         first + added}
      end)

    %Mesh{
      vertices: IO.iodata_to_binary(vertices),
      indices: IO.iodata_to_binary(indices),
      parts: Enum.reverse(parts)
    }
  end

  defp triangles(bsp, group, atlas, count) do
    Enum.reduce(group, {[], <<>>, count}, fn {index, face}, {vertices, indices, base} ->
      corners = Enum.map(face.points, &vertex(bsp, face, index, atlas, &1))

      fan =
        for corner <- 1..(length(corners) - 2),
            at <- [base, base + corner + 1, base + corner],
            into: <<>>,
            do: <<at::little-32>>

      {[vertices, corners], indices <> fan, base + length(corners)}
    end)
  end

  defp vertex(bsp, %Face{} = face, index, atlas, {x, y, z} = point) do
    {normal, _distance} = elem(bsp.planes, face.plane)
    {nx, ny, nz} = if face.back?, do: negate(normal), else: normal
    {s, t} = Face.st(face, point)
    %{mips: [first | _]} = elem(bsp.textures, face.texture)
    {lu, lv} = Atlas.uv(atlas, index, face, s, t)
    [s0, s1, s2, s3] = Atlas.styles(face)

    <<x::little-float-32, y::little-float-32, z::little-float-32,
      s / first.width::little-float-32, nx::little-float-32, ny::little-float-32,
      nz::little-float-32, t / first.height::little-float-32, lu::little-float-32,
      lv::little-float-32, s0 + 256 * s1::little-float-32, s2 + 256 * s3::little-float-32>>
  end

  defp negate({x, y, z}), do: {-x, -y, -z}

  defp entity_materials(state, target, bsp, model, brush) do
    {handles, {changes, state}} =
      model.parts
      |> Enum.with_index()
      |> Enum.map_reduce({[], state}, fn {{texture, page}, part}, {changes, state} ->
        {material, state} = material(state, target, bsp, model, brush, texture, page)

        {handle, changed, materials} =
          Materials.put(state.materials, target, {brush.key, part}, material)

        {handle, {changes ++ changed, %{state | materials: materials}}}
      end)

    {handles, changes, state}
  end

  defp material(state, target, bsp, model, brush, texture, page) do
    kind = elem(bsp.textures, texture).kind
    cut? = brush.alpha_test != nil and kind == :masked
    {picture, state} = picture(state, target, bsp, texture, cut?)
    {r, g, b, alpha} = brush.tint

    material =
      kind
      |> look(brush, picture, {r, g, b}, alpha, page && Enum.at(model.pages, page), model.slots)
      |> Map.put(:alpha_cutoff, if(cut?, do: brush.alpha_test, else: 0.0))
      |> Map.put(:uv_scroll, scroll(brush.scroll, elem(bsp.textures, texture)))

    {material, state}
  end

  defp look(:sky, _brush, picture, _tint, _alpha, _page, _slots),
    do: %{Looks.material(picture, {1.0, 1.0, 1.0}, 1.0, :none) | sky: true}

  defp look(:liquid, brush, picture, tint, alpha, _page, _slots),
    do: %{Looks.material(picture, Light.linear(tint), alpha, blend(brush.blend)) | warp: true}

  defp look(_kind, %{fixed: {fr, fg, fb}} = brush, picture, {r, g, b}, alpha, _page, _slots),
    do: Looks.material(picture, Light.linear({r * fr, g * fg, b * fb}), alpha, blend(brush.blend))

  defp look(_kind, brush, picture, _tint, alpha, nil, _slots),
    do: Looks.material(picture, {0.0, 0.0, 0.0}, alpha, blend(brush.blend))

  defp look(_kind, brush, picture, tint, alpha, page, slots),
    do:
      Looks.material(picture, Light.linear(tint), alpha, blend(brush.blend),
        lightmap: page,
        lightmap_styles: slots
      )

  defp scroll(nil, _texture), do: {0.0, 0.0}
  defp scroll(texels, %{mips: [first | _]}), do: {texels / first.width, 0.0}

  defp blend({:add, _amount}), do: :add
  defp blend({:alpha, _amount}), do: :alpha
  defp blend(:none), do: :none

  defp picture(state, target, bsp, texture, cut?) do
    key = {texture, cut?}

    case state.pictures do
      %{^key => handle} ->
        {handle, state}

      _ ->
        handle =
          CauldronGPU.Target.texture(target, texture_picture(elem(bsp.textures, texture), cut?))

        {handle, %{state | pictures: Map.put(state.pictures, key, handle)}}
    end
  end

  defp texture_picture(%{mips: [%{format: :rgba} = first | _]}, _cut?),
    do: %Texture{width: first.width, height: first.height, pixels: first.pixels, filter: :nearest}

  defp texture_picture(%{mips: [first | _]}, cut?) do
    colours =
      for <<r, g, b <- first.palette || grey()>>, do: <<r, g, b, 255>>

    colours =
      colours
      |> List.to_tuple()
      |> then(&if(cut?, do: put_elem(&1, 255, <<0, 0, 0, 0>>), else: &1))

    pixels = for <<index <- first.pixels>>, into: <<>>, do: elem(colours, index)
    %Texture{width: first.width, height: first.height, pixels: pixels, filter: :nearest}
  end

  defp grey, do: for(level <- 0..255, into: <<>>, do: <<level, level, level>>)
end
