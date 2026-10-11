defmodule ElixirHalfLife.FontFile.Glyf do
  @moduledoc """
  TrueType outlines: the `glyf` table found through the `loca` table (`loca_format` 0
  for 16-bit offsets in words, 1 for 32-bit offsets in bytes).

  A simple glyph's points are on or off the curve; two off-curve points in a row have an
  on-curve point between them, and a contour with no on-curve point starts midway
  between its first two. A composite glyph is its components' outlines, each moved by
  its offset (or by matching one of its points to one already placed) and transformed
  by its scale, its x and y scales or its two-by-two matrix.
  """

  import Bitwise

  @enforce_keys [:glyf, :offsets]
  defstruct [:glyf, :offsets]

  @type t :: %__MODULE__{glyf: binary(), offsets: tuple()}

  @arg_words 0x0001
  @args_xy 0x0002
  @have_scale 0x0008
  @more 0x0020
  @xy_scale 0x0040
  @two_by_two 0x0080

  @doc "The outlines of a `glyf` table with its `loca` table."
  @spec parse(binary(), binary(), integer()) :: {:ok, t()}
  def parse(glyf, loca, 0) do
    offsets = for <<word::16 <- loca>>, do: word * 2
    {:ok, %__MODULE__{glyf: glyf, offsets: List.to_tuple(offsets)}}
  end

  def parse(glyf, loca, _format) do
    offsets = for <<offset::32 <- loca>>, do: offset
    {:ok, %__MODULE__{glyf: glyf, offsets: List.to_tuple(offsets)}}
  end

  @doc "Glyph `glyph`'s contours, as `ElixirHalfLife.FontFile.outline/2` gives them."
  @spec outline(t(), non_neg_integer()) :: [[ElixirHalfLife.FontFile.segment()]]
  def outline(glyf, glyph), do: glyf |> points(glyph, 0) |> Enum.map(&segments/1)

  defp points(%__MODULE__{offsets: offsets}, glyph, _depth)
       when glyph + 1 >= tuple_size(offsets),
       do: []

  defp points(_glyf, _glyph, depth) when depth > 16, do: []

  defp points(%__MODULE__{glyf: data, offsets: offsets} = glyf, glyph, depth) do
    from = elem(offsets, glyph)
    to = elem(offsets, glyph + 1)

    if to <= from or to > byte_size(data),
      do: [],
      else: glyph_points(glyf, binary_part(data, from, to - from), depth)
  end

  defp glyph_points(glyf, <<contours::signed-16, _box::binary-8, rest::binary>>, depth)
       when contours < 0,
       do: components(glyf, rest, [], depth)

  defp glyph_points(_glyf, <<contours::signed-16, _box::binary-8, rest::binary>>, _depth),
    do: simple(contours, rest)

  defp glyph_points(_glyf, _data, _depth), do: []

  defp simple(0, _rest), do: []

  defp simple(contours, rest) do
    <<ends::binary-size(^contours * 2), length::16, _code::binary-size(length), rest::binary>> =
      rest

    ends = for <<last::16 <- ends>>, do: last
    count = List.last(ends) + 1
    {flags, rest} = flags(rest, count, [])
    {xs, rest} = coordinates(rest, flags, 0x02, 0x10, 0, [])
    {ys, _rest} = coordinates(rest, flags, 0x04, 0x20, 0, [])

    points =
      [xs, ys, flags]
      |> Enum.zip()
      |> Enum.map(fn {x, y, flag} -> {x / 1, y / 1, band(flag, 1) == 1} end)

    split(points, ends, 0, [])
  end

  defp flags(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp flags(<<flag, rest::binary>>, left, acc) when band(flag, 0x08) != 0 do
    <<repeat, rest::binary>> = rest
    times = min(repeat + 1, left)
    flags(rest, left - times, List.duplicate(flag, times) ++ acc)
  end

  defp flags(<<flag, rest::binary>>, left, acc), do: flags(rest, left - 1, [flag | acc])

  defp coordinates(rest, [], _short, _same, _at, acc), do: {Enum.reverse(acc), rest}

  defp coordinates(rest, [flag | flags], short, same, at, acc) do
    {delta, rest} = delta(rest, band(flag, short) != 0, band(flag, same) != 0)
    coordinates(rest, flags, short, same, at + delta, [at + delta | acc])
  end

  defp delta(<<value, rest::binary>>, true, true), do: {value, rest}
  defp delta(<<value, rest::binary>>, true, false), do: {-value, rest}
  defp delta(rest, false, true), do: {0, rest}
  defp delta(<<value::signed-16, rest::binary>>, false, false), do: {value, rest}

  defp split(_points, [], _from, acc), do: Enum.reverse(acc)

  defp split(points, [last | ends], from, acc) do
    contour = Enum.slice(points, from, last - from + 1)
    split(points, ends, last + 1, [contour | acc])
  end

  defp components(glyf, <<flags::16, glyph::16, rest::binary>>, placed, depth) do
    {{arg1, arg2}, rest} =
      arguments(rest, band(flags, @arg_words) != 0, band(flags, @args_xy) != 0)

    {matrix, rest} = transform(rest, flags)
    contours = glyf |> points(glyph, depth + 1) |> Enum.map(&apply_matrix(&1, matrix))
    offset = offset(flags, {arg1, arg2}, List.flatten(placed), List.flatten(contours))
    placed = placed ++ Enum.map(contours, &move(&1, offset))

    if band(flags, @more) != 0,
      do: components(glyf, rest, placed, depth),
      else: placed
  end

  defp components(_glyf, _rest, placed, _depth), do: placed

  defp arguments(<<a::signed-16, b::signed-16, rest::binary>>, true, true), do: {{a, b}, rest}
  defp arguments(<<a::16, b::16, rest::binary>>, true, false), do: {{a, b}, rest}
  defp arguments(<<a::signed-8, b::signed-8, rest::binary>>, false, true), do: {{a, b}, rest}
  defp arguments(<<a, b, rest::binary>>, false, false), do: {{a, b}, rest}

  defp transform(<<scale::signed-16, rest::binary>>, flags) when band(flags, @have_scale) != 0,
    do: {{f2dot14(scale), 0.0, 0.0, f2dot14(scale)}, rest}

  defp transform(<<sx::signed-16, sy::signed-16, rest::binary>>, flags)
       when band(flags, @xy_scale) != 0,
       do: {{f2dot14(sx), 0.0, 0.0, f2dot14(sy)}, rest}

  defp transform(<<a::signed-16, b::signed-16, c::signed-16, d::signed-16, rest::binary>>, flags)
       when band(flags, @two_by_two) != 0,
       do: {{f2dot14(a), f2dot14(b), f2dot14(c), f2dot14(d)}, rest}

  defp transform(rest, _flags), do: {{1.0, 0.0, 0.0, 1.0}, rest}

  defp f2dot14(value), do: value / 16_384

  defp apply_matrix(contour, {a, b, c, d}),
    do: Enum.map(contour, fn {x, y, on} -> {x * a + y * c, x * b + y * d, on} end)

  defp offset(flags, {dx, dy}, _placed, _contours) when band(flags, @args_xy) != 0,
    do: {dx / 1, dy / 1}

  defp offset(_flags, {placed_point, own_point}, placed, contours) do
    with {px, py, _} <- Enum.at(placed, placed_point),
         {ox, oy, _} <- Enum.at(contours, own_point) do
      {px - ox, py - oy}
    else
      _ -> {0.0, 0.0}
    end
  end

  defp move(contour, {dx, dy}), do: Enum.map(contour, fn {x, y, on} -> {x + dx, y + dy, on} end)

  defp segments([]), do: []

  defp segments(points) do
    {start, rest} = start(points)
    [{:move, start} | walk(rest ++ [{elem(start, 0), elem(start, 1), true}], nil)]
  end

  defp start([{x, y, true} | rest]), do: {{x, y}, rest}

  defp start([first | _] = points) do
    case Enum.find_index(points, fn {_x, _y, on} -> on end) do
      nil ->
        {x0, y0, _} = first
        {x1, y1, _} = Enum.at(points, 1, first)
        {{(x0 + x1) / 2, (y0 + y1) / 2}, tl(points) ++ [first]}

      index ->
        {before, [{x, y, true} | after_on]} = Enum.split(points, index)
        {{x, y}, after_on ++ before}
    end
  end

  defp walk([], _control), do: []
  defp walk([{x, y, true} | rest], nil), do: [{:line, {x, y}} | walk(rest, nil)]
  defp walk([{x, y, true} | rest], control), do: [{:quad, control, {x, y}} | walk(rest, nil)]
  defp walk([{x, y, false} | rest], nil), do: walk(rest, {x, y})

  defp walk([{x, y, false} | rest], {cx, cy} = control),
    do: [{:quad, control, {(cx + x) / 2, (cy + y) / 2}} | walk(rest, {x, y})]
end
