defmodule ElixirHalfLife.Csqc.Polygons do
  @moduledoc """
  The client program's own polygons (`R_BeginPolygon`, `R_PolygonVertex`,
  `R_EndPolygon`, `R_EndPolygonRibbon`) as FTE draws them for FreeHL.

  A polygon is `%{shader:, flags:, two_d?:, vertices:}`, each vertex `{position, {s, t,
  _}, {r, g, b}, alpha}`. Three or more vertices are a fan of triangles from the first;
  two are a line one pixel wide. Flags `& 3` of 1 add the polygon to what is behind
  (by its alpha), of 2 lay it over by its alpha; otherwise it hides what is behind.

  The shader name picks how it is painted: a sprite frame's name
  (`ElixirHalfLife.Csqc.Sprites`) paints that frame times the vertex colour and alpha,
  cut away where the frame's alpha is below 0.666; any other picture paints its own
  colours at 0.75 and its own alpha, the vertex colours unused; an empty name paints the
  vertex colours, laid over by their alpha.

  `ribbon/4` widens a line of vertices into a strip facing the eye.
  """

  alias Cauldron3D.{Polygon, Texture, Vec, View}
  alias ElixirHalfLife.Csqc.Sprites
  alias ElixirHalfLife.Pictures

  @white Texture.rgba(1, 1, <<255, 255, 255, 255>>)

  @doc """
  The polygon's triangles for the scene, each with its shader sort: 11 laid over, 12
  added, the rest 7 for sprite frames and 5 otherwise.
  """
  @spec scene(map(), View.t()) :: [{non_neg_integer(), Polygon.t()}]
  def scene(%{vertices: vertices} = polygon, view) do
    {kind, texture} = shader(polygon.shader)
    blend = blend(polygon.flags, kind)
    sort = sort(polygon.flags, kind)

    vertices
    |> shapes(view)
    |> Enum.map(fn corners -> {sort, triangle(corners, kind, texture, blend)} end)
  end

  @doc """
  The polygon drawn straight onto `frame` (screen positions in pixels), painted with its
  shader's picture times its vertex colours and alpha, added by flags `& 3` of 1 and
  otherwise laid over.
  """
  @spec flat(map(), Cauldron3D.Frame.t()) :: Cauldron3D.Frame.t()
  def flat(%{vertices: vertices} = polygon, frame) when length(vertices) >= 3 do
    texture = Sprites.picture(polygon.shader) || Pictures.get(polygon.shader) || @white

    camera =
      Cauldron3D.Camera.new(
        projection: :orthographic,
        position: {frame.width / 2, frame.height / 2, 100.0},
        pitch: -:math.pi() / 2,
        yaw: :math.pi() / 2,
        extent: frame.width / 1
      )

    view = View.new(camera, {frame.width, frame.height})
    blend = if Bitwise.band(trunc(polygon.flags), 3) == 1, do: {:add, 1.0}, else: {:alpha, 1.0}

    triangles =
      for corners <- fan(vertices) do
        %Polygon{
          points: Enum.map(corners, fn {{x, y, _}, _, _, _} -> {x, frame.height - y, 0.0} end),
          uvs: Enum.map(corners, &uv(&1, texture)),
          tints: Enum.map(corners, fn {_, _, {r, g, b}, a} -> {r, g, b, a} end),
          paint: {:texture, texture, nil},
          blend: blend,
          depth: :always
        }
      end

    drawn = Cauldron3D.Render.draw(view, triangles, palette: grey(), backdrop: frame)
    %{frame | pixels: drawn.pixels}
  end

  def flat(_polygon, frame), do: frame

  @doc """
  Vertices widened into a strip `separation` either side of their line, facing `eye`:
  the line's vertices moved out one way with their `s` and `t` moved by `{ds, dt}`,
  copies moved the other way, joined two triangles to a step.
  """
  @spec ribbon([tuple()], number(), {number(), number()}, Vec.t()) :: [[tuple()]]
  def ribbon(vertices, separation, {ds, dt}, eye) when length(vertices) >= 2 do
    points = vertices |> Enum.map(&elem(&1, 0)) |> List.to_tuple()
    count = tuple_size(points)

    {outer, inner} =
      vertices
      |> Enum.with_index()
      |> Enum.map(fn {{position, {s, t, z}, rgb, a}, i} ->
        dir = ribbon_direction(points, i, count)
        eyedir = Vec.normalize(Vec.sub(position, eye))
        tang = cross(dir, eyedir)

        {{Vec.madd(position, tang, separation), {s + ds, t + dt, z}, rgb, a},
         {Vec.madd(position, tang, -separation), {s, t, z}, rgb, a}}
      end)
      |> Enum.unzip()

    {outer, inner} = {List.to_tuple(outer), List.to_tuple(inner)}

    Enum.flat_map(1..(count - 1), fn i ->
      [
        [elem(outer, i - 1), elem(outer, i), elem(inner, i)],
        [elem(inner, i), elem(inner, i - 1), elem(outer, i - 1)]
      ]
    end)
  end

  def ribbon(_vertices, _separation, _offset, _eye), do: []

  defp ribbon_direction(points, 0, _count),
    do: Vec.normalize(Vec.sub(elem(points, 1), elem(points, 0)))

  defp ribbon_direction(points, i, count) when i == count - 1,
    do: Vec.normalize(Vec.sub(elem(points, i), elem(points, i - 1)))

  defp ribbon_direction(points, i, _count),
    do: Vec.normalize(Vec.sub(elem(points, i + 1), elem(points, i - 1)))

  defp shader(""), do: {:fill, @white}

  defp shader(name) do
    case Sprites.picture(name) do
      nil -> {:skin, Pictures.get(name) || @white}
      texture -> {:sprite, texture}
    end
  end

  defp blend(flags, _kind) when Bitwise.band(trunc(flags), 3) == 1, do: {:add, 1.0}
  defp blend(flags, _kind) when Bitwise.band(trunc(flags), 3) == 2, do: {:alpha, 1.0}
  defp blend(_flags, :fill), do: {:alpha, 1.0}
  defp blend(_flags, _kind), do: :none

  defp sort(flags, _kind) when Bitwise.band(trunc(flags), 3) == 1, do: 12
  defp sort(flags, _kind) when Bitwise.band(trunc(flags), 3) == 2, do: 11
  defp sort(_flags, :fill), do: 11
  defp sort(_flags, :sprite), do: 7
  defp sort(_flags, _kind), do: 5

  defp shapes({:triangles, triangles}, _view), do: triangles
  defp shapes([a, b], view), do: [line(a, b, view)]
  defp shapes(vertices, _view) when length(vertices) >= 3, do: fan(vertices)
  defp shapes(_vertices, _view), do: []

  defp fan([first | rest]) do
    rest |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [b, c] -> [first, b, c] end)
  end

  defp line({pa, ta, ca, aa}, {pb, tb, cb, ab}, view) do
    da = max(Vec.dot(Vec.sub(pa, view.origin), view.forward), view.near)
    db = max(Vec.dot(Vec.sub(pb, view.origin), view.forward), view.near)
    along = Vec.sub(pb, pa)
    side = view.forward |> cross(along) |> Vec.normalize()
    half_a = da / view.scale_x / 2
    half_b = db / view.scale_x / 2

    [
      {Vec.madd(pa, side, half_a), ta, ca, aa},
      {Vec.madd(pb, side, half_b), tb, cb, ab},
      {Vec.madd(pb, side, -half_b), tb, cb, ab},
      {Vec.madd(pa, side, -half_a), ta, ca, aa}
    ]
  end

  defp triangle(corners, kind, texture, blend) do
    %Polygon{
      points: Enum.map(corners, &elem(&1, 0)),
      uvs: Enum.map(corners, &uv(&1, texture)),
      tints: Enum.map(corners, &tint(&1, kind)),
      paint: {:texture, texture, nil},
      blend: blend,
      alpha_test: if(kind == :sprite, do: 0.666)
    }
  end

  defp tint({_, _, {r, g, b}, a}, kind) when kind in [:sprite, :fill], do: {r, g, b, a}
  defp tint(_vertex, :skin), do: {0.75, 0.75, 0.75, 1.0}

  defp uv({_, {s, t, _}, _, _}, texture), do: {s * texture.width, t * texture.height}

  defp cross({ax, ay, az}, {bx, by, bz}),
    do: {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}

  defp grey, do: for(i <- 0..255, into: <<>>, do: <<i, i, i>>)
end
