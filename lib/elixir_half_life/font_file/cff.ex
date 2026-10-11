defmodule ElixirHalfLife.FontFile.Cff do
  @moduledoc """
  Compact Font Format outlines (the `CFF ` table of an OpenType font): the first font's
  Type 2 charstrings, run with the global subroutines and the local subroutines of the
  glyph's private dictionary (for a CID-keyed font, the dictionary its `FDSelect` picks).

  Charstrings give cubic curves in font units. Hints are read past and not applied; the
  arithmetic, storage and conditional operators run; `endchar` with four further
  arguments draws the accent glyph over the base glyph, both found by their standard
  encoding codes through the font's charset.
  """

  import Bitwise

  alias ElixirHalfLife.FontFile.CffStandard

  @enforce_keys [:charstrings, :global, :privates, :select, :charset]
  defstruct [:charstrings, :global, :privates, :select, :charset]

  @type t :: %__MODULE__{
          charstrings: tuple(),
          global: tuple(),
          privates: tuple(),
          select: (non_neg_integer() -> non_neg_integer()),
          charset: %{non_neg_integer() => non_neg_integer()}
        }

  @doc "The outlines of a `CFF ` table."
  @spec parse(binary()) :: {:ok, t()} | :error
  def parse(<<_major, _minor, header, _offsize, _::binary>> = cff) do
    {_names, at} = index(cff, header)
    {[top | _], at} = index(cff, at)
    {_strings, at} = index(cff, at)
    {global, _at} = index(cff, at)
    top = dict(top)
    {charstrings, _} = index(cff, number(top, 17))
    glyphs = length(charstrings)

    {privates, select} =
      if Map.has_key?(top, {12, 30}),
        do: cid_privates(cff, top, glyphs),
        else: {[private(cff, Map.get(top, 18))], fn _glyph -> 0 end}

    {:ok,
     %__MODULE__{
       charstrings: List.to_tuple(charstrings),
       global: List.to_tuple(global),
       privates: List.to_tuple(privates),
       select: select,
       charset: charset(cff, Map.get(top, 15, [0]) |> hd(), glyphs)
     }}
  rescue
    _ in [MatchError, ArgumentError, FunctionClauseError] -> :error
  end

  def parse(_cff), do: :error

  @doc "Glyph `glyph`'s contours, as `ElixirHalfLife.FontFile.outline/2` gives them."
  @spec outline(t(), non_neg_integer()) :: [[ElixirHalfLife.FontFile.segment()]]
  def outline(%__MODULE__{charstrings: charstrings}, glyph) when glyph >= tuple_size(charstrings),
    do: []

  def outline(cff, glyph) do
    state = run(cff, glyph, {0.0, 0.0})
    Enum.reverse(close(state).contours)
  end

  defp run(cff, glyph, origin) do
    private = elem(cff.privates, cff.select.(glyph))

    state = %{
      stack: [],
      x: elem(origin, 0),
      y: elem(origin, 1),
      stems: 0,
      width: false,
      contour: [],
      contours: [],
      store: %{},
      cff: cff,
      local: private.subrs,
      ended: false,
      seed: 0
    }

    {state, _} = execute(elem(cff.charstrings, glyph), state, 0)
    state
  end

  defp execute(<<>>, state, _depth), do: {state, :return}
  defp execute(_code, state, depth) when depth > 10, do: {state, :endchar}

  defp execute(<<b0, rest::binary>>, state, depth) when b0 >= 32 and b0 <= 246,
    do: execute(rest, push(state, b0 - 139), depth)

  defp execute(<<b0, b1, rest::binary>>, state, depth) when b0 >= 247 and b0 <= 250,
    do: execute(rest, push(state, (b0 - 247) * 256 + b1 + 108), depth)

  defp execute(<<b0, b1, rest::binary>>, state, depth) when b0 >= 251 and b0 <= 254,
    do: execute(rest, push(state, -(b0 - 251) * 256 - b1 - 108), depth)

  defp execute(<<28, value::signed-16, rest::binary>>, state, depth),
    do: execute(rest, push(state, value), depth)

  defp execute(<<255, value::signed-32, rest::binary>>, state, depth),
    do: execute(rest, push(state, value / 65_536), depth)

  defp execute(<<op, rest::binary>>, state, depth) when op in [1, 3, 18, 23] do
    {args, state} = take_width(state, rem(length(state.stack), 2) == 1)
    execute(rest, %{state | stems: state.stems + div(length(args), 2), stack: []}, depth)
  end

  defp execute(<<op, rest::binary>>, state, depth) when op in [19, 20] do
    {args, state} = take_width(state, rem(length(state.stack), 2) == 1)
    stems = state.stems + div(length(args), 2)
    bytes = div(stems + 7, 8)
    <<_mask::binary-size(^bytes), rest::binary>> = rest
    execute(rest, %{state | stems: stems, stack: []}, depth)
  end

  defp execute(<<21, rest::binary>>, state, depth) do
    {[dx, dy], state} = take_width(state, length(state.stack) > 2)
    execute(rest, state |> close() |> move_to(state.x + dx, state.y + dy), depth)
  end

  defp execute(<<22, rest::binary>>, state, depth) do
    {[dx], state} = take_width(state, length(state.stack) > 1)
    execute(rest, state |> close() |> move_to(state.x + dx, state.y), depth)
  end

  defp execute(<<4, rest::binary>>, state, depth) do
    {[dy], state} = take_width(state, length(state.stack) > 1)
    execute(rest, state |> close() |> move_to(state.x, state.y + dy), depth)
  end

  defp execute(<<5, rest::binary>>, state, depth) do
    state =
      state.stack
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.reduce(state, fn [dx, dy], acc -> line(acc, acc.x + dx, acc.y + dy) end)

    execute(rest, %{state | stack: []}, depth)
  end

  defp execute(<<op, rest::binary>>, state, depth) when op in [6, 7] do
    {state, _} =
      Enum.reduce(state.stack, {state, op == 6}, fn delta, {acc, horizontal} ->
        acc =
          if horizontal,
            do: line(acc, acc.x + delta, acc.y),
            else: line(acc, acc.x, acc.y + delta)

        {acc, not horizontal}
      end)

    execute(rest, %{state | stack: []}, depth)
  end

  defp execute(<<8, rest::binary>>, state, depth) do
    state =
      state.stack
      |> Enum.chunk_every(6, 6, :discard)
      |> Enum.reduce(state, &rcurve/2)

    execute(rest, %{state | stack: []}, depth)
  end

  defp execute(<<24, rest::binary>>, state, depth) do
    {curves, [dx, dy]} = Enum.split(state.stack, length(state.stack) - 2)

    state =
      curves
      |> Enum.chunk_every(6, 6, :discard)
      |> Enum.reduce(state, &rcurve/2)

    execute(rest, %{line(state, state.x + dx, state.y + dy) | stack: []}, depth)
  end

  defp execute(<<25, rest::binary>>, state, depth) do
    {lines, curve} = Enum.split(state.stack, length(state.stack) - 6)

    state =
      lines
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.reduce(state, fn [dx, dy], acc -> line(acc, acc.x + dx, acc.y + dy) end)

    execute(rest, %{rcurve(curve, state) | stack: []}, depth)
  end

  defp execute(<<26, rest::binary>>, state, depth) do
    {first, args} =
      if rem(length(state.stack), 4) == 1,
        do: {hd(state.stack), tl(state.stack)},
        else: {0, state.stack}

    {state, _} =
      args
      |> Enum.chunk_every(4, 4, :discard)
      |> Enum.reduce({state, first}, fn [dya, dxb, dyb, dyc], {acc, dx1} ->
        {rcurve([dx1, dya, dxb, dyb, 0, dyc], acc), 0}
      end)

    execute(rest, %{state | stack: []}, depth)
  end

  defp execute(<<27, rest::binary>>, state, depth) do
    {first, args} =
      if rem(length(state.stack), 4) == 1,
        do: {hd(state.stack), tl(state.stack)},
        else: {0, state.stack}

    {state, _} =
      args
      |> Enum.chunk_every(4, 4, :discard)
      |> Enum.reduce({state, first}, fn [dxa, dxb, dyb, dxc], {acc, dy1} ->
        {rcurve([dxa, dy1, dxb, dyb, dxc, 0], acc), 0}
      end)

    execute(rest, %{state | stack: []}, depth)
  end

  defp execute(<<op, rest::binary>>, state, depth) when op in [30, 31] do
    execute(rest, %{alternating(state.stack, state, op == 31) | stack: []}, depth)
  end

  defp execute(<<op, rest::binary>>, state, depth) when op in [10, 29] do
    {stack, [number]} = Enum.split(state.stack, length(state.stack) - 1)
    subrs = if op == 10, do: state.local, else: state.cff.global
    index = trunc(number) + bias(tuple_size(subrs))

    if index < 0 or index >= tuple_size(subrs) do
      {state, :endchar}
    else
      case execute(elem(subrs, index), %{state | stack: stack}, depth + 1) do
        {state, :return} -> execute(rest, state, depth)
        {state, :endchar} -> {state, :endchar}
      end
    end
  end

  defp execute(<<11, _rest::binary>>, state, _depth), do: {state, :return}

  defp execute(<<14, _rest::binary>>, state, _depth) do
    {args, state} = take_width(state, length(state.stack) in [1, 5])

    case args do
      [adx, ady, bchar, achar] -> {accented(state, adx, ady, bchar, achar), :endchar}
      _ -> {close(state), :endchar}
    end
  end

  defp execute(<<12, op, rest::binary>>, state, depth) when op in [34, 35, 36, 37],
    do: execute(rest, %{flex(op, state.stack, state) | stack: []}, depth)

  defp execute(<<12, op, rest::binary>>, state, depth),
    do: execute(rest, arithmetic(op, state), depth)

  defp execute(<<_op, rest::binary>>, state, depth),
    do: execute(rest, %{state | stack: []}, depth)

  defp push(state, value), do: %{state | stack: state.stack ++ [value]}

  defp take_width(%{width: false} = state, true),
    do: {tl(state.stack), %{state | width: true, stack: []}}

  defp take_width(state, _extra), do: {state.stack, %{state | width: true, stack: []}}

  defp bias(count) when count < 1240, do: 107
  defp bias(count) when count < 33_900, do: 1131
  defp bias(_count), do: 32_768

  defp move_to(state, x, y), do: %{state | x: x, y: y, contour: [{:move, {x / 1, y / 1}}]}

  defp line(%{contour: []} = state, x, y), do: line(move_to(state, state.x, state.y), x, y)

  defp line(state, x, y),
    do: %{state | x: x, y: y, contour: [{:line, {x / 1, y / 1}} | state.contour]}

  defp curve(%{contour: []} = state, c1, c2, p),
    do: curve(move_to(state, state.x, state.y), c1, c2, p)

  defp curve(state, {x1, y1}, {x2, y2}, {x, y} = p) do
    segment = {:cubic, {x1 / 1, y1 / 1}, {x2 / 1, y2 / 1}, {x / 1, y / 1}}
    %{state | x: elem(p, 0), y: elem(p, 1), contour: [segment | state.contour]}
  end

  defp rcurve([dxa, dya, dxb, dyb, dxc, dyc], state) do
    c1 = {state.x + dxa, state.y + dya}
    c2 = {elem(c1, 0) + dxb, elem(c1, 1) + dyb}
    curve(state, c1, c2, {elem(c2, 0) + dxc, elem(c2, 1) + dyc})
  end

  defp alternating(args, state, horizontal) when length(args) >= 4 do
    [d1, d2, d3, d4 | rest] = args
    last = rest == [] or length(rest) == 1
    extra = if last and rest != [], do: hd(rest), else: 0

    state =
      if horizontal,
        do: rcurve([d1, 0, d2, d3, extra, d4], state),
        else: rcurve([0, d1, d2, d3, d4, extra], state)

    if last, do: state, else: alternating(rest, state, not horizontal)
  end

  defp alternating(_args, state, _horizontal), do: state

  defp flex(35, [dx1, dy1, dx2, dy2, dx3, dy3, dx4, dy4, dx5, dy5, dx6, dy6 | _], state) do
    state = rcurve([dx1, dy1, dx2, dy2, dx3, dy3], state)
    rcurve([dx4, dy4, dx5, dy5, dx6, dy6], state)
  end

  defp flex(34, [dx1, dx2, dy2, dx3, dx4, dx5, dx6 | _], state) do
    state = rcurve([dx1, 0, dx2, dy2, dx3, 0], state)
    rcurve([dx4, 0, dx5, -dy2, dx6, 0], state)
  end

  defp flex(36, [dx1, dy1, dx2, dy2, dx3, dx4, dx5, dy5, dx6 | _], state) do
    state = rcurve([dx1, dy1, dx2, dy2, dx3, 0], state)
    rcurve([dx4, 0, dx5, dy5, dx6, -(dy1 + dy2 + dy5)], state)
  end

  defp flex(37, [dx1, dy1, dx2, dy2, dx3, dy3, dx4, dy4, dx5, dy5, d6 | _], state) do
    dx = dx1 + dx2 + dx3 + dx4 + dx5
    dy = dy1 + dy2 + dy3 + dy4 + dy5

    {dx6, dy6} = if abs(dx) > abs(dy), do: {d6, -dy}, else: {-dx, d6}

    state
    |> then(&rcurve([dx1, dy1, dx2, dy2, dx3, dy3], &1))
    |> then(&rcurve([dx4, dy4, dx5, dy5, dx6, dy6], &1))
  end

  defp flex(_op, _args, state), do: state

  defp arithmetic(3, state),
    do: binary(state, fn a, b -> if a != 0 and b != 0, do: 1, else: 0 end)

  defp arithmetic(4, state), do: binary(state, fn a, b -> if a != 0 or b != 0, do: 1, else: 0 end)
  defp arithmetic(5, state), do: unary(state, fn a -> if a == 0, do: 1, else: 0 end)
  defp arithmetic(9, state), do: unary(state, &abs/1)
  defp arithmetic(10, state), do: binary(state, &(&1 + &2))
  defp arithmetic(11, state), do: binary(state, &(&1 - &2))
  defp arithmetic(12, state), do: binary(state, fn a, b -> if b == 0, do: 0, else: a / b end)
  defp arithmetic(14, state), do: unary(state, &(-&1))
  defp arithmetic(15, state), do: binary(state, fn a, b -> if a == b, do: 1, else: 0 end)
  defp arithmetic(18, state), do: %{state | stack: Enum.drop(state.stack, -1)}
  defp arithmetic(20, state), do: put(state)
  defp arithmetic(21, state), do: get(state)
  defp arithmetic(22, state), do: ifelse(state)
  defp arithmetic(23, state), do: random(state)
  defp arithmetic(24, state), do: binary(state, &(&1 * &2))
  defp arithmetic(26, state), do: unary(state, fn a -> :math.sqrt(abs(a)) end)
  defp arithmetic(27, state), do: %{state | stack: state.stack ++ [List.last(state.stack)]}
  defp arithmetic(28, state), do: exch(state)
  defp arithmetic(29, state), do: index_op(state)
  defp arithmetic(30, state), do: roll(state)
  defp arithmetic(_op, state), do: %{state | stack: []}

  defp unary(state, fun) do
    {rest, [a]} = Enum.split(state.stack, -1)
    %{state | stack: rest ++ [fun.(a)]}
  end

  defp binary(state, fun) do
    {rest, [a, b]} = Enum.split(state.stack, -2)
    %{state | stack: rest ++ [fun.(a, b)]}
  end

  defp put(state) do
    {rest, [value, at]} = Enum.split(state.stack, -2)
    %{state | stack: rest, store: Map.put(state.store, trunc(at), value)}
  end

  defp get(state) do
    {rest, [at]} = Enum.split(state.stack, -1)
    %{state | stack: rest ++ [Map.get(state.store, trunc(at), 0)]}
  end

  defp ifelse(state) do
    {rest, [s1, s2, v1, v2]} = Enum.split(state.stack, -4)
    %{state | stack: rest ++ [if(v1 <= v2, do: s1, else: s2)]}
  end

  defp random(state) do
    seed = rem(state.seed * 1_103_515_245 + 12_345, 2_147_483_648)
    %{state | seed: seed, stack: state.stack ++ [(seed + 1) / 2_147_483_649]}
  end

  defp exch(state) do
    {rest, [a, b]} = Enum.split(state.stack, -2)
    %{state | stack: rest ++ [b, a]}
  end

  defp index_op(state) do
    {rest, [i]} = Enum.split(state.stack, -1)
    i = if i < 0, do: 0, else: trunc(i)
    %{state | stack: rest ++ [Enum.at(rest, -1 - i, 0)]}
  end

  defp roll(state) do
    {rest, [n, j]} = Enum.split(state.stack, -2)
    n = trunc(n)

    if n <= 0 or n > length(rest) do
      %{state | stack: rest}
    else
      {keep, rolled} = Enum.split(rest, -n)
      shift = Integer.mod(trunc(j), n)
      {front, back} = Enum.split(rolled, n - shift)
      %{state | stack: keep ++ back ++ front}
    end
  end

  defp accented(state, adx, ady, bchar, achar) do
    base = state.cff |> standard_glyph(trunc(bchar))
    accent = state.cff |> standard_glyph(trunc(achar))
    state = close(state)

    with base when base != nil <- base,
         accent when accent != nil <- accent do
      base_state = state.cff |> run(base, {0.0, 0.0}) |> close()
      accent_state = state.cff |> run(accent, {adx / 1, ady / 1}) |> close()
      %{state | contours: accent_state.contours ++ base_state.contours ++ state.contours}
    else
      _ -> state
    end
  end

  defp standard_glyph(cff, code) do
    case CffStandard.encoding_sid(code) do
      0 -> nil
      sid -> Map.get(cff.charset, sid)
    end
  end

  defp close(%{contour: []} = state), do: state

  defp close(state),
    do: %{state | contour: [], contours: [Enum.reverse(state.contour) | state.contours]}

  defp cid_privates(cff, top, glyphs) do
    {fonts, _} = index(cff, number(top, {12, 36}))
    privates = Enum.map(fonts, fn font -> private(cff, font |> dict() |> Map.get(18)) end)
    selected = fd_select(cff, number(top, {12, 37}), glyphs)
    {privates, fn glyph -> Map.get(selected, glyph, 0) end}
  end

  defp fd_select(cff, at, glyphs) do
    case binary_part(cff, at, byte_size(cff) - at) do
      <<0, fds::binary>> ->
        fds
        |> binary_part(0, glyphs)
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Map.new(fn {fd, g} -> {g, fd} end)

      <<3, count::16, rest::binary>> ->
        ranges = for <<first::16, fd <- binary_part(rest, 0, count * 3)>>, do: {first, fd}
        <<sentinel::16, _::binary>> = binary_part(rest, count * 3, 2)
        fd_ranges(ranges, sentinel)
    end
  end

  defp fd_ranges(ranges, sentinel) do
    ranges
    |> Enum.zip(tl(Enum.map(ranges, &elem(&1, 0))) ++ [sentinel])
    |> Enum.flat_map(fn {{first, fd}, next} -> for g <- first..(next - 1)//1, do: {g, fd} end)
    |> Map.new()
  end

  defp private(_cff, nil), do: %{subrs: {}}

  defp private(cff, [size, at]) do
    private = dict(binary_part(cff, trunc(at), trunc(size)))

    subrs =
      case Map.get(private, 19) do
        [offset] -> cff |> index(trunc(at + offset)) |> elem(0) |> List.to_tuple()
        _ -> {}
      end

    %{subrs: subrs}
  end

  defp charset(_cff, at, _glyphs) when at in [0, 1, 2], do: %{}

  defp charset(cff, at, glyphs) do
    <<format, rest::binary>> = binary_part(cff, at, byte_size(cff) - at)

    format
    |> charset_sids(rest, glyphs - 1)
    |> Enum.with_index(1)
    |> Map.new()
  end

  defp charset_sids(0, rest, count),
    do: for(<<sid::16 <- binary_part(rest, 0, count * 2)>>, do: sid)

  defp charset_sids(1, rest, count), do: ranges(rest, count, 1, [])
  defp charset_sids(2, rest, count), do: ranges(rest, count, 2, [])

  defp ranges(_rest, count, _size, acc) when count <= 0,
    do: acc |> Enum.reverse() |> List.flatten()

  defp ranges(rest, count, size, acc) do
    bits = size * 8
    <<first::16, left::size(^bits), rest::binary>> = rest
    sids = Enum.to_list(first..(first + left))
    ranges(rest, count - length(sids), size, [sids | acc])
  end

  defp number(dict, key), do: dict |> Map.fetch!(key) |> hd() |> trunc()

  defp index(cff, at) do
    case binary_part(cff, at, byte_size(cff) - at) do
      <<0::16, _::binary>> ->
        {[], at + 2}

      <<count::16, size, rest::binary>> ->
        bits = size * 8

        offsets =
          for <<offset::size(^bits) <- binary_part(rest, 0, (count + 1) * size)>>, do: offset

        base = at + 3 + (count + 1) * size - 1

        items =
          offsets
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [from, to] -> binary_part(cff, base + from, to - from) end)

        {items, base + List.last(offsets)}
    end
  end

  defp dict(data), do: dict(data, [], %{})

  defp dict(<<>>, _operands, acc), do: acc

  defp dict(<<12, op, rest::binary>>, operands, acc),
    do: dict(rest, [], Map.put(acc, {12, op}, Enum.reverse(operands)))

  defp dict(<<op, rest::binary>>, operands, acc) when op <= 21,
    do: dict(rest, [], Map.put(acc, op, Enum.reverse(operands)))

  defp dict(<<28, value::signed-16, rest::binary>>, operands, acc),
    do: dict(rest, [value | operands], acc)

  defp dict(<<29, value::signed-32, rest::binary>>, operands, acc),
    do: dict(rest, [value | operands], acc)

  defp dict(<<30, rest::binary>>, operands, acc) do
    {value, rest} = real(rest, "")
    dict(rest, [value | operands], acc)
  end

  defp dict(<<b0, rest::binary>>, operands, acc) when b0 >= 32 and b0 <= 246,
    do: dict(rest, [b0 - 139 | operands], acc)

  defp dict(<<b0, b1, rest::binary>>, operands, acc) when b0 >= 247 and b0 <= 250,
    do: dict(rest, [(b0 - 247) * 256 + b1 + 108 | operands], acc)

  defp dict(<<b0, b1, rest::binary>>, operands, acc) when b0 >= 251 and b0 <= 254,
    do: dict(rest, [-(b0 - 251) * 256 - b1 - 108 | operands], acc)

  defp dict(<<_b0, rest::binary>>, operands, acc), do: dict(rest, operands, acc)

  defp real(<<byte, rest::binary>>, text) do
    high = byte >>> 4
    low = band(byte, 15)

    case {nibble(high), nibble(low)} do
      {:end, _} -> {parse_real(text), rest}
      {a, :end} -> {parse_real(text <> a), rest}
      {a, b} -> real(rest, text <> a <> b)
    end
  end

  defp nibble(n) when n <= 9, do: Integer.to_string(n)
  defp nibble(10), do: "."
  defp nibble(11), do: "E"
  defp nibble(12), do: "E-"
  defp nibble(14), do: "-"
  defp nibble(15), do: :end
  defp nibble(_), do: ""

  defp parse_real(text) do
    case Float.parse(text) do
      {value, _} ->
        value

      :error ->
        case Integer.parse(text) do
          {value, _} -> value / 1
          :error -> 0.0
        end
    end
  end
end
