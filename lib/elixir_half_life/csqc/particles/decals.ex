defmodule ElixirHalfLife.Csqc.Particles.Decals do
  @moduledoc """
  Marks laid on the world's faces, as FTE's `Mod_ClipDecal` cuts them: every face near
  the centre (walking the world's nodes within half the size of it) that faces against
  the mark's normal by more than half, wound the same way, is cut to the box `size`
  across along both tangents and the normal, and what is left is split into triangles
  from its first corner.

      triangles = ElixirHalfLife.Csqc.Particles.Decals.clip(bsp, center, normal, t1, t2, 16.0)
      #=> [{a, b, c}, ...]

  Sky and hidden faces take no marks.
  """

  alias Cauldron3D.{Bsp, Vec}

  @epsilon 1.0 / 32

  @doc "The world's faces cut to the mark at `center`, as triangles of three points."
  @spec clip(Bsp.t(), Vec.t(), Vec.t(), Vec.t(), Vec.t(), number()) :: [
          {Vec.t(), Vec.t(), Vec.t()}
        ]
  def clip(%Bsp{} = bsp, center, normal, tangent1, tangent2, size) do
    planes =
      [
        tangent1,
        Vec.scale(tangent1, -1.0),
        tangent2,
        Vec.scale(tangent2, -1.0),
        normal,
        Vec.scale(normal, -1.0)
      ]
      |> Enum.map(fn n ->
        n = Vec.normalize(n)
        {n, Vec.dot(center, n) - size / 2}
      end)

    decal = %{center: center, normal: Vec.normalize(normal), radius: size / 2, planes: planes}
    %{heads: [head | _]} = elem(bsp.models, 0)
    nodes(bsp, decal, head, [])
  end

  @doc """
  The triangles of an `adddecal` mark: `shader`'s picture laid at `origin` with `up`
  (pointing out of the surface, its length the depth) and `side` (its length the size),
  each corner `{point, {s, t}, alpha}` with the alpha fading with the distance from the
  centre along `up`. A mark whose `up` or `side` has no length has no triangles.
  """
  @spec project(Bsp.t(), Vec.t(), Vec.t(), Vec.t()) :: [[{Vec.t(), {float(), float()}, float()}]]
  def project(%Bsp{} = bsp, origin, up, side) do
    if Vec.dot(up, up) == 0 or Vec.dot(side, side) == 0,
      do: [],
      else: laid(bsp, origin, up, side)
  end

  defp laid(bsp, origin, up, side) do
    axis0 = Vec.scale(up, -1.0)
    vradius = 1 / :math.sqrt(Vec.dot(axis0, axis0))
    radius = 1 / :math.sqrt(Vec.dot(side, side))
    axis0 = Vec.scale(axis0, vradius)
    axis2 = Vec.scale(side, radius)
    axis1 = cross(axis0, axis2)
    offset2 = Vec.dot(origin, axis2) + 0.5 * radius
    offset1 = Vec.dot(origin, axis1) + 0.5 * radius
    offset0 = Vec.dot(origin, axis0)
    {scale2, scale1, scale0} = {1 / radius, 1 / radius, 2 / vradius}

    bsp
    |> clip(origin, axis0, axis1, axis2, max(radius, vradius))
    |> Enum.map(fn {a, b, c} ->
      for point <- [a, b, c] do
        s = 1 + (Vec.dot(point, axis1) - offset1) * scale1
        t = -(Vec.dot(point, axis2) - offset2) * scale2
        fade = 1 - abs(Vec.dot(point, axis0) - offset0) * scale0
        {point, {s, t}, fade}
      end
    end)
  end

  defp nodes(_bsp, _decal, node, acc) when node < 0, do: acc

  defp nodes(bsp, decal, node, acc) do
    info = elem(bsp.nodes, node)
    {normal, distance} = Bsp.plane(bsp, info.plane)
    dist = Vec.dot(decal.center, normal) - distance

    cond do
      dist > decal.radius ->
        nodes(bsp, decal, info.front, acc)

      dist < -decal.radius ->
        nodes(bsp, decal, info.back, acc)

      true ->
        acc = node_faces(bsp, decal, info, acc)
        acc = nodes(bsp, decal, info.front, acc)
        nodes(bsp, decal, info.back, acc)
    end
  end

  defp node_faces(_bsp, _decal, %{face_count: 0}, acc), do: acc

  defp node_faces(bsp, decal, %{first_face: first, face_count: count}, acc) do
    Enum.reduce(first..(first + count - 1), acc, fn index, acc ->
      face = elem(bsp.faces, index)
      {normal, _} = Bsp.plane(bsp, face.plane)

      facing =
        if face.back?, do: -Vec.dot(normal, decal.normal), else: Vec.dot(normal, decal.normal)

      kind = elem(bsp.textures, face.texture).kind

      if facing > -0.5 or kind in [:sky, :hidden],
        do: acc,
        else: fragment(decal, face.points, acc)
    end)
  end

  defp fragment(decal, [p0, p1 | rest] = points, acc) do
    d1 = Vec.sub(p1, p0)

    case Enum.find_value(rest, &winding(d1, Vec.sub(&1, p0))) do
      nil ->
        acc

      n ->
        if Vec.dot(Vec.normalize(n), decal.normal) < 0.1,
          do: acc,
          else: clipped(decal.planes, points, acc)
    end
  end

  defp fragment(_decal, _points, acc), do: acc

  defp winding(d1, d2) do
    n = cross(d1, d2)
    if Vec.dot(n, n) > 0.1, do: n
  end

  defp clipped(planes, points, acc) do
    case Enum.reduce_while(planes, points, &clip_plane/2) do
      [first | rest] when length(rest) >= 2 -> triangles(first, Enum.reverse(rest), acc)
      _ -> acc
    end
  end

  defp clip_plane(plane, points) do
    case clip_to_plane(points, plane) do
      kept when length(kept) >= 3 -> {:cont, kept}
      _ -> {:halt, []}
    end
  end

  defp triangles(first, [last, before | rest], acc),
    do: triangles(first, [before | rest], [{first, before, last} | acc])

  defp triangles(_first, _rest, acc), do: acc

  defp clip_to_plane(points, {normal, distance}) do
    dots = Enum.map(points, &(Vec.dot(&1, normal) - distance))
    keeps = Enum.map(dots, &keep/1)

    cond do
      Enum.all?(keeps, &(&1 == :kill)) -> []
      not Enum.any?(keeps, &(&1 == :kill)) -> points
      true -> cut(points, dots, keeps)
    end
  end

  defp keep(d) when d < -@epsilon, do: :kill
  defp keep(d) when d > @epsilon, do: :keep
  defp keep(_d), do: :border

  defp cut(points, dots, keeps) do
    count = length(points)
    {pt, dt, kt} = {List.to_tuple(points), List.to_tuple(dots), List.to_tuple(keeps)}

    Enum.flat_map(0..(count - 1), fn i ->
      j = rem(i + 1, count)

      edge_points(
        {elem(pt, i), elem(dt, i), elem(kt, i)},
        {elem(pt, j), elem(dt, j), elem(kt, j)}
      )
    end)
  end

  defp edge_points({p1, _d1, :border}, _next), do: [p1]

  defp edge_points({p1, d1, k1}, {p2, d2, k2}) do
    own = if k1 == :keep, do: [p1], else: []

    if k2 == :border or k1 == k2 do
      own
    else
      d = d1 - d2
      t = if d != 0, do: d1 / d, else: d
      own ++ [Vec.lerp(p1, p2, t)]
    end
  end

  defp cross({ax, ay, az}, {bx, by, bz}),
    do: {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}
end
