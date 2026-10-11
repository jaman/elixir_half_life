defmodule ElixirHalfLife.FontFile.Raster do
  @moduledoc """
  An outline drawn to a grey coverage bitmap, as FreeType renders a glyph in its normal
  (anti-aliased) mode.

  The outline (`ElixirHalfLife.FontFile.outline/2`, font units) is scaled by `scale`
  pixels per unit and each point kept to a 64th of a pixel. The bitmap covers the
  outline's control box widened to whole pixels; `left` is its left edge and `top` its
  top edge in pixels from the glyph origin (`y` upwards). Each byte is how much of its
  pixel the outline covers under the non-zero winding rule, 0 to 255, rows from the top.

      ElixirHalfLife.FontFile.Raster.render(outline, 20 / 1000)
  """

  @type bitmap :: %{
          width: non_neg_integer(),
          rows: non_neg_integer(),
          left: integer(),
          top: integer(),
          pixels: binary()
        }

  @tolerance 1 / 16

  @doc "Render `outline` at `scale` pixels per font unit."
  @spec render([[ElixirHalfLife.FontFile.segment()]], float()) :: bitmap()
  def render(outline, scale) do
    contours = Enum.map(outline, fn contour -> Enum.map(contour, &scale_segment(&1, scale)) end)

    case contours |> Enum.flat_map(&segment_points/1) do
      [] -> %{width: 0, rows: 0, left: 0, top: 0, pixels: <<>>}
      points -> draw(contours, points)
    end
  end

  defp draw(contours, points) do
    {xs, ys} = Enum.unzip(points)
    left = floor(Enum.min(xs))
    bottom = floor(Enum.min(ys))
    right = ceil(Enum.max(xs))
    top = ceil(Enum.max(ys))
    width = right - left
    rows = top - bottom
    place = fn {x, y} -> {x - left, top - y} end

    cells =
      contours
      |> Enum.flat_map(&lines(&1, place))
      |> Enum.reduce(%{}, &accumulate(&1, &2, width, rows))

    %{width: width, rows: rows, left: left, top: top, pixels: coverage(cells, width * rows)}
  end

  defp scale_segment({:move, p}, scale), do: {:move, snap(p, scale)}
  defp scale_segment({:line, p}, scale), do: {:line, snap(p, scale)}
  defp scale_segment({:quad, c, p}, scale), do: {:quad, snap(c, scale), snap(p, scale)}

  defp scale_segment({:cubic, c1, c2, p}, scale),
    do: {:cubic, snap(c1, scale), snap(c2, scale), snap(p, scale)}

  defp snap({x, y}, scale), do: {round(x * scale * 64) / 64, round(y * scale * 64) / 64}

  defp segment_points(contour) do
    Enum.flat_map(contour, fn
      {:move, p} -> [p]
      {:line, p} -> [p]
      {:quad, c, p} -> [c, p]
      {:cubic, c1, c2, p} -> [c1, c2, p]
    end)
  end

  defp lines([{:move, start} | rest], place) do
    start = place.(start)

    {lines, last} =
      Enum.reduce(rest, {[], start}, fn segment, {acc, from} ->
        points = flatten(segment, from, place)
        {pairs(from, points) ++ acc, List.last(points)}
      end)

    [{last, start} | lines]
  end

  defp lines(_contour, _place), do: []

  defp pairs(from, points) do
    {pairs, _} = Enum.reduce(points, {[], from}, fn p, {acc, a} -> {[{a, p} | acc], p} end)
    pairs
  end

  defp flatten({:line, p}, _from, place), do: [place.(p)]

  defp flatten({:quad, c, p}, from, place) do
    c = place.(c)
    p = place.(p)
    n = pieces(deviation(from, c, p))
    for i <- 1..n, do: quad_at(from, c, p, i / n)
  end

  defp flatten({:cubic, c1, c2, p}, from, place) do
    c1 = place.(c1)
    c2 = place.(c2)
    p = place.(p)
    n = pieces(0.75 * max(deviation(from, c1, c2), deviation(c1, c2, p)))
    for i <- 1..n, do: cubic_at(from, c1, c2, p, i / n)
  end

  defp deviation({x0, y0}, {x1, y1}, {x2, y2}) do
    dx = x0 - 2 * x1 + x2
    dy = y0 - 2 * y1 + y2
    :math.sqrt(dx * dx + dy * dy) / 4
  end

  defp pieces(deviation), do: max(1, ceil(:math.sqrt(deviation / @tolerance)))

  defp quad_at({x0, y0}, {x1, y1}, {x2, y2}, t) do
    u = 1 - t
    {u * u * x0 + 2 * u * t * x1 + t * t * x2, u * u * y0 + 2 * u * t * y1 + t * t * y2}
  end

  defp cubic_at({x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}, t) do
    u = 1 - t
    a = u * u * u
    b = 3 * u * u * t
    c = 3 * u * t * t
    d = t * t * t
    {a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3}
  end

  defp accumulate({{_x0, y0}, {_x1, y1}}, cells, _width, _rows) when y0 == y1, do: cells

  defp accumulate({{x0, y0}, {x1, y1}}, cells, width, rows) when y0 > y1,
    do: edge({x1, y1}, {x0, y0}, -1, cells, width, rows)

  defp accumulate({p0, p1}, cells, width, rows), do: edge(p0, p1, 1, cells, width, rows)

  defp edge({x0, y0}, {x1, y1}, direction, cells, width, rows) do
    slope = (x1 - x0) / (y1 - y0)
    x = if y0 < 0, do: x0 - y0 * slope, else: x0
    first = max(0, floor(y0))
    last = min(rows, ceil(y1)) - 1

    if last < first do
      cells
    else
      {cells, _x} =
        Enum.reduce(first..last, {cells, x}, fn row, {acc, cx} ->
          dy = min(row + 1, y1) - max(row, y0)
          next = cx + slope * dy
          {row_cells(acc, row * width, cx, next, dy * direction), next}
        end)

      cells
    end
  end

  defp row_cells(cells, start, xa, xb, d) do
    {x0, x1} = if xa < xb, do: {xa, xb}, else: {xb, xa}
    x0_floor = floor(x0)
    x1_ceil = ceil(x1)

    if x1_ceil <= x0_floor + 1 do
      middle = 0.5 * (xa + xb) - x0_floor

      cells
      |> add(start + x0_floor, d - d * middle)
      |> add(start + x0_floor + 1, d * middle)
    else
      spread(cells, start, x0, x1, x0_floor, x1_ceil, d)
    end
  end

  defp spread(cells, start, x0, x1, x0_floor, x1_ceil, d) do
    s = 1 / (x1 - x0)
    x0f = x0 - x0_floor
    a0 = 0.5 * s * (1 - x0f) * (1 - x0f)
    x1f = x1 - x1_ceil + 1
    am = 0.5 * s * x1f * x1f
    cells = add(cells, start + x0_floor, d * a0)

    cells =
      if x1_ceil == x0_floor + 2 do
        add(cells, start + x0_floor + 1, d * (1 - a0 - am))
      else
        a1 = s * (1.5 - x0f)
        cells = add(cells, start + x0_floor + 1, d * (a1 - a0))

        cells =
          Enum.reduce((x0_floor + 2)..(x1_ceil - 2)//1, cells, fn xi, acc ->
            add(acc, start + xi, d * s)
          end)

        a2 = a1 + (x1_ceil - x0_floor - 3) * s
        add(cells, start + x1_ceil - 1, d * (1 - a2 - am))
      end

    add(cells, start + x1_ceil, d * am)
  end

  defp add(cells, at, value), do: Map.update(cells, at, value, &(&1 + value))

  defp coverage(_cells, 0), do: <<>>

  defp coverage(cells, count) do
    {bytes, _} =
      Enum.map_reduce(0..(count - 1), 0.0, fn at, sum ->
        sum = sum + Map.get(cells, at, 0.0)
        {grey(sum), sum}
      end)

    :binary.list_to_bin(bytes)
  end

  defp grey(sum), do: sum |> abs() |> Kernel.*(256) |> trunc() |> min(255)
end
