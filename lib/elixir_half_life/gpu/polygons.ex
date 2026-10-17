defmodule ElixirHalfLife.Gpu.Polygons do
  @moduledoc """
  World-space polygons (sprites, particles, marks, beams, the program's own and studio
  models' chrome, `Cauldron3D.Polygon`s in map units) as one mesh, rebuilt each tick
  under one handle, with a part per run of polygons laid down alike, in the order given.

  A polygon is painted with its picture (`{:texture, texture, _}`), unlit and seen from
  both sides, each corner's tint its vertex colour (`CauldronGPU.Mesh`'s `colors`), by
  its blend (`ElixirHalfLife.Gpu.Looks`): `:none` cut away by its alpha test or clear
  colour, `{:alpha, k}` laid over, `{:add, k}` added, `{:premultiplied, k}` laid over a
  picture whose colours are already multiplied by its alpha (the corner's colour divided
  by its alpha), and `{:darken, k}` multiplying what is behind by one minus `k` times
  the picture's colour times the corner's grey level (the mean of its red, green and
  blue).

      {changes, instance, polygons, pictures} = ElixirHalfLife.Gpu.Polygons.changes(polygons, target, list, pictures)
  """

  alias Cauldron3D.Polygon
  alias CauldronGPU.{Instance, Mesh}
  alias ElixirHalfLife.Gpu.{Looks, Materials, Pictures, Space}

  @type t :: %{mesh: CauldronGPU.Handle.t() | nil, materials: Materials.t()}

  @doc "No polygons yet."
  @spec new() :: t()
  def new, do: %{mesh: nil, materials: Materials.new()}

  @doc """
  The changes and the instance (`nil` when there is nothing to draw) for `list`, with
  the polygons' state and `pictures` (`ElixirHalfLife.Gpu.Pictures`) after.
  """
  @spec changes(t(), CauldronGPU.Target.t(), [Polygon.t()], Pictures.t()) ::
          {[CauldronGPU.Stream.change()], Instance.t() | nil, t(), Pictures.t()}
  def changes(state, target, list, pictures) do
    {runs, pictures} = runs(list, target, pictures)

    case runs do
      [] ->
        {[], nil, %{state | materials: Materials.sweep(state.materials, target)}, pictures}

      _ ->
        {materials, changes, state} = materials(runs, target, state)
        {mesh_changes, state} = put_mesh(state, target, mesh(runs))

        instance = %Instance{
          mesh: state.mesh,
          materials: materials,
          transform:
            Space.transform(
              {0.0, 0.0, 0.0},
              {{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}},
              1.0
            ),
          shadows: false,
          snap: true
        }

        {changes ++ mesh_changes, instance, state, pictures}
    end
  end

  @doc "Releases the mesh and materials."
  @spec release(t(), CauldronGPU.Target.t()) :: :ok
  def release(state, target) do
    if state.mesh, do: CauldronGPU.Target.release(target, state.mesh)
    Materials.release(state.materials, target)
  end

  defp runs(list, target, pictures) do
    {looked, pictures} =
      Enum.flat_map_reduce(list, pictures, fn polygon, pictures ->
        case look(polygon, target, pictures) do
          {nil, pictures} -> {[], pictures}
          {looks, pictures} -> {[{looks, polygon}], pictures}
        end
      end)

    runs =
      looked
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map(fn [{looks, _} | _] = run -> {looks, Enum.map(run, &elem(&1, 1))} end)

    {runs, pictures}
  end

  defp look(
         %Polygon{paint: {:texture, texture, _}, points: [_, _, _ | _]} = polygon,
         target,
         pictures
       ) do
    cutoff = polygon.alpha_test || if(polygon.clear, do: 0.5, else: 0.0)
    {blend, form, k, corner} = blend(polygon.blend)
    {handle, pictures} = Pictures.get(pictures, target, texture, form, polygon.clear)

    material =
      Looks.material(handle, {1.0, 1.0, 1.0}, k, blend, cutoff: cutoff, double_sided: true)

    {%{material: material, size: {texture.width, texture.height}, corner: corner}, pictures}
  end

  defp look(_polygon, _target, pictures), do: {nil, pictures}

  defp blend(:none), do: {:none, :straight, 1.0, :tint}
  defp blend({:alpha, k}), do: {:alpha, :straight, k, :tint}
  defp blend({:add, k}), do: {:add, :straight, k, :tint}
  defp blend({:premultiplied, k}), do: {:premultiplied, :premultiplied, k, :unmultiplied}
  defp blend({:darken, k}), do: {:multiply, :inverted, k, :level}

  defp materials(runs, target, state) do
    {handles, {changes, materials}} =
      runs
      |> Enum.with_index()
      |> Enum.map_reduce({[], state.materials}, fn {{looks, _polygons}, index},
                                                   {changes, materials} ->
        {handle, changed, materials} =
          Materials.put(materials, target, {:polygons, index}, looks.material)

        {handle, {changes ++ changed, materials}}
      end)

    {handles, changes, %{state | materials: Materials.sweep(materials, target)}}
  end

  defp mesh(runs) do
    {vertices, colours, indices, parts, _count, _first} =
      Enum.reduce(runs, {[], [], [], [], 0, 0}, fn {looks, polygons},
                                                   {vertices, colours, indices, parts, count,
                                                    first} ->
        {run_vertices, run_colours, run_indices, count} = triangles(polygons, looks, count)
        added = div(IO.iodata_length(run_indices), 4)

        {[vertices, run_vertices], [colours, run_colours], [indices, run_indices],
         [{first, added} | parts], count, first + added}
      end)

    %Mesh{
      vertices: IO.iodata_to_binary(vertices),
      indices: IO.iodata_to_binary(indices),
      colors: IO.iodata_to_binary(colours),
      parts: Enum.reverse(parts)
    }
  end

  defp triangles(polygons, looks, count) do
    Enum.reduce(polygons, {[], [], [], count}, fn polygon, {vertices, colours, indices, base} ->
      corners = length(polygon.points)
      uvs = polygon.uvs || List.duplicate({0.0, 0.0}, corners)
      tints = polygon.tints || List.duplicate({1.0, 1.0, 1.0, 1.0}, corners)
      added = Enum.zip_with(polygon.points, uvs, &vertex(&1, &2, looks.size))
      tinted = Enum.map(tints, &colour(&1, looks.corner))

      fan =
        for corner <- 1..(corners - 2),
            index <- [base, base + corner, base + corner + 1],
            into: <<>>,
            do: <<index::little-32>>

      {[vertices, added], [colours, tinted], [indices, fan], base + corners}
    end)
  end

  defp colour({r, g, b, a}, :tint), do: bytes(r, g, b, a)

  defp colour({r, g, b, a}, :unmultiplied) when a > 0,
    do: bytes(r / a, g / a, b / a, a)

  defp colour({_r, _g, _b, _a}, :unmultiplied), do: bytes(0.0, 0.0, 0.0, 0.0)
  defp colour({r, g, b, _a}, :level), do: bytes(1.0, 1.0, 1.0, (r + g + b) / 3)

  defp bytes(r, g, b, a), do: <<byte(r), byte(g), byte(b), byte(a)>>

  defp byte(value), do: value |> Kernel.*(255) |> round() |> max(0) |> min(255)

  defp vertex({x, y, z}, {u, v}, {width, height}) do
    <<x::little-float-32, y::little-float-32, z::little-float-32, u / width::little-float-32,
      0.0::little-float-32, 0.0::little-float-32, 1.0::little-float-32,
      v / height::little-float-32, 0.0::little-float-32, 0.0::little-float-32,
      65_535.0::little-float-32, 65_535.0::little-float-32>>
  end

  defp put_mesh(%{mesh: nil} = state, target, mesh),
    do: {[], %{state | mesh: CauldronGPU.Target.mesh(target, mesh)}}

  defp put_mesh(%{mesh: handle} = state, _target, mesh), do: {[{:mesh, handle.id, mesh}], state}
end
