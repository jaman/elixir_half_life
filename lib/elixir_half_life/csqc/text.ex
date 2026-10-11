defmodule ElixirHalfLife.Csqc.Text do
  @moduledoc """
  The client program's text builtins, as FTE runs them: `drawcharacter` (320),
  `drawrawstring` (321), `drawstring` (326, with markup, `ElixirHalfLife.Csqc.FunString`),
  `stringwidth` (327), `findfont` (356), `loadfont` (357) and `drawtextfield`.

  Positions and sizes are in 2D units (`ElixirHalfLife.Csqc.Screen.ratio/1` pixels
  each), and widths come back in them. Text is drawn in the font
  `ElixirHalfLife.Csqc.Fonts.choose/4` picks for the `drawfont` global and the size
  asked (times the `drawfontscale` global when that is not zero), made at the pixel
  height that size covers, starting at the whole pixel at or before the position asked.
  Each character is a quad
  of its picture, sampled smoothly, coloured by the colour and alpha asked times the
  font's tint times the markup's colour, and laid over the screen with premultiplied
  alpha, or added (draw flag 1). `drawtextfield` wraps text into a box, aligned by its
  flags: 1 left, 2 top, 4 right, 8 bottom, 16 on a dark plaque, 32 unwrapped.

  Drawing goes onto the rows of the host's `ext.screen` (`ElixirHalfLife.Csqc.Screen`),
  inside its clip area.
  """

  import Bitwise

  alias ElixirHalfLife.Csqc.{Fonts, FunString, Screen}
  alias ElixirHalfLife.Csqc.Fonts.Font
  alias QuakeServer.{Args, Server}

  @consolecolours {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.67}, {0.0, 0.67, 0.0}, {0.0, 0.67, 0.67},
                   {0.67, 0.0, 0.0}, {0.67, 0.0, 0.67}, {0.67, 0.33, 0.0}, {0.67, 0.67, 0.67},
                   {0.33, 0.33, 0.33}, {0.33, 0.33, 1.0}, {0.33, 1.0, 0.33}, {0.33, 1.0, 1.0},
                   {1.0, 0.33, 0.33}, {1.0, 0.33, 1.0}, {1.0, 1.0, 0.33}, {1.0, 1.0, 1.0}}

  @hidden 0x00080000
  @blink 0x00040000
  @alt 0x00020000
  @rich 0x00010000
  @nonclear 0x00800000
  @half 0x00400000
  @white 0x0F000000
  @fg_mask 0x0F000000
  @bg_mask 0xF0000000
  @rich_bits 0xFFF00000

  @left 1
  @top 2
  @right 4
  @bottom 8
  @plaque 16
  @nowrap 32
  @obituary 1 <<< 16
  @persist 1 <<< 17
  @typewriter 1 <<< 18

  @doc "Run text builtin `builtin` with `argc` arguments."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 320, argc) do
    code = Args.int(s, 1)

    if code == 0 do
      Args.return(s, -1.0)
    else
      flag = if argc >= 6, do: trunc(Args.num(s, 5)), else: 0
      code = quake_character(s, code, flag)
      {pen, x, y} = begin(s, Args.vec(s, 0), Args.vec(s, 2))
      pen = colours(pen, Args.vec(s, 3), Args.num(s, 4), additive?(flag))
      {pen, _x} = scaled_char(pen, x, y, @white, code)
      s |> flush(pen) |> Args.return(1.0)
    end
  end

  def call(s, 321, argc) do
    flag = if argc >= 6, do: trunc(Args.num(s, 5)), else: 0
    {pen, x, y} = begin(s, Args.vec(s, 0), Args.vec(s, 2))
    pen = colours(pen, Args.vec(s, 3), Args.num(s, 4), additive?(flag))
    pen = raw(Args.str(s, 1), pen, x, y)
    flush(s, pen)
  end

  def call(s, 326, argc) do
    {rgb, alpha, flag} =
      if argc >= 6,
        do: {Args.vec(s, 3), Args.num(s, 4), trunc(Args.num(s, 5))},
        else: {{1.0, 1.0, 1.0}, Args.num(s, 3), if(argc >= 5, do: trunc(Args.num(s, 4)), else: 0)}

    chars = FunString.parse(Args.str(s, 1), @white, utf8: utf8(s))
    {pen, x, y} = begin(s, Args.vec(s, 0), Args.vec(s, 2))
    pen = colours(pen, rgb, alpha, additive?(flag))
    flush(s, coloured(chars, pen, x, x, y))
  end

  def call(s, 327, argc) do
    keep = Args.num(s, 1) == 0
    size = if argc > 2, do: Args.vec(s, 2), else: {8.0, 8.0, 0.0}
    chars = FunString.parse(Args.str(s, 0), @white, keep_markup: keep, utf8: utf8(s))
    {pen, _x, _y} = begin(s, {0.0, 0.0, 0.0}, size)
    width = line_width(pen.font, chars) * pen.cw / elem(Screen.ratio(s), 0)
    Args.return(s, if(argc > 2, do: width, else: width / 8))
  end

  def call(s, 356, _argc), do: Args.return(s, Fonts.find(s, Args.str(s, 0)) / 1)

  def call(s, 357, argc) do
    slot = if argc > 3, do: trunc(Args.num(s, 3)), else: -1
    {s, slot} = Fonts.load(s, Args.str(s, 0), Args.str(s, 1), Args.str(s, 2), slot)
    Args.return(s, slot / 1)
  end

  def call(s, "drawtextfield", _argc) do
    {x, y, _} = Args.vec(s, 0)
    {w, h, _} = Args.vec(s, 1)
    flags = trunc(Args.num(s, 2))
    {sx, sy} = font_scale(s, 8.0, 8.0)
    font = Fonts.choose(s, drawfont(s), sx, sy)
    chars = FunString.parse(Args.str(s, 3), @white, utf8: utf8(s))
    {s, lines} = field(s, font, {trunc(x), trunc(y), trunc(w), trunc(h)}, chars, flags)
    Args.return(s, lines / 1)
  end

  @doc """
  Draw console lines into `box` (`{x, y, width, height}` in 2D units) in the `drawfont`
  font at `size` units high (times the `drawfontscale` global's height), wrapped to the
  box's width and stacked up from its bottom left, as FTE draws a console. Each line is
  `{text, markup?}`: with `markup?` false the text's `^` codes are shown as written.
  """
  @spec console(
          map(),
          [{String.t(), boolean()}],
          {number(), number(), number(), number()},
          number()
        ) ::
          map()
  def console(s, lines, {x, y, w, h}, size) do
    {_, size_y} = font_scale(s, size, size)
    font = Fonts.choose(s, drawfont(s), size_y, size_y)

    chars =
      lines
      |> Enum.map(fn {text, markup?} ->
        FunString.parse(text, @white, keep_markup: not markup?, utf8: utf8(s))
      end)
      |> Enum.intersperse([{@white, ?\n}])
      |> Enum.concat()

    {s, _count} =
      field(s, font, {trunc(x), trunc(y), trunc(w), trunc(h)}, chars, @left ||| @bottom)

    s
  end

  defp quake_character(s, code, flag) do
    cond do
      band(flag, 4) != 0 or utf8(s) != 0 -> code
      code >= 32 and code < 128 -> code
      true -> bor(code, 0xE000)
    end
  end

  defp utf8(s), do: trunc(cvar_number(s, "com_parseutf8", 1.0))

  defp cvar_number(s, name, default),
    do: if(Server.cvar?(s, name), do: Server.cvar(s, name), else: default)

  defp additive?(flag), do: band(flag, 3) == 1

  defp drawfont(s) do
    if QuakeC.global?(s.qc, "drawfont"),
      do: QuakeC.float(QuakeC.global(s.qc, "drawfont")),
      else: 0.0
  end

  defp font_scale(s, w, h) do
    case QuakeC.global?(s.qc, "drawfontscale") and QuakeC.global_vector(s.qc, "drawfontscale") do
      {fx, fy, _} when fx != 0 or fy != 0 -> {w * fx, h * fy}
      _ -> {w, h}
    end
  end

  defp begin(s, {vx, vy, _}, {w, h, _}) do
    {w, h} = font_scale(s, w, h)
    font = Fonts.choose(s, drawfont(s), w, h)
    {rx, ry} = Screen.ratio(s)
    cw = w * rx / font.charheight * font.scale
    ch = h * ry / font.charheight * font.scale
    {pen(font, cw, ch), trunc(vx * rx) / 1, trunc(vy * ry) / 1}
  end

  defp pen(font, cw, ch) do
    %{
      font: font,
      curfont: font,
      cw: cw,
      ch: ch,
      tint: {1.0, 1.0, 1.0, 1.0},
      mask: @white,
      fore: {255, 255, 255, 255},
      back: {0, 0, 0, 0},
      additive: false,
      quads: [],
      backs: [],
      flushed: []
    }
  end

  defp colours(pen, {r, g, b}, alpha, additive) do
    tint = {r * alpha, g * alpha, b * alpha, alpha}
    {tr, tg, tb, ta} = tint

    %{
      pen
      | tint: tint,
        mask: @white,
        fore: {byte(tr * 255), byte(tg * 255), byte(tb * 255), byte(ta * 255)},
        additive: additive
    }
  end

  defp byte(value) when value >= 255, do: 255
  defp byte(value) when value <= 0, do: 0
  defp byte(value), do: trunc(value)

  defp raw(<<>>, pen, _x, _y), do: pen

  defp raw(text, pen, x, y) do
    {code, _error, rest} = FunString.utf8(text)
    {pen, x} = scaled_char(pen, x, y, @white, code)
    raw(rest, pen, x, y)
  end

  defp coloured([], pen, _start, _x, _y), do: pen

  defp coloured([{flags, _code} | rest], pen, start, x, y) when band(flags, @hidden) != 0,
    do: coloured(rest, pen, start, x, y)

  defp coloured([{_flags, ?\n} | rest], pen, start, x, y),
    do: coloured(rest, pen, start, x, y + pen.curfont.charheight)

  defp coloured([{_flags, ?\r} | rest], pen, start, _x, y),
    do: coloured(rest, pen, start, start, y)

  defp coloured([{flags, code} | rest], pen, start, x, y) do
    {pen, x} = scaled_char(pen, x, y, flags, code)
    coloured(rest, pen, start, x, y)
  end

  defp scaled_char(pen, px, py, flags, code) do
    {font, flags} = alternate(pen.curfont, flags, code, true)

    case Font.char(font, code) do
      nil ->
        {pen, px}

      char ->
        nextx = px + char.advance * pen.cw

        cond do
          code == ?\s and band(flags, @rich ||| @nonclear) != @nonclear -> {pen, nextx}
          band(flags, @blink) != 0 and blink_off?(3) -> {pen, nextx}
          true -> {scaled_quad(scaled_colour(pen, font, flags), font, char, px, py, flags), nextx}
        end
    end
  end

  defp alternate(font, flags, code, clear) do
    cond do
      band(flags, @alt) == 0 -> {font, flags}
      font.alt != nil and clear -> {font.alt, band(flags, bnot(@alt))}
      font.alt != nil -> {font.alt, flags}
      code >= 0xE000 and code <= 0xE0FF -> {font, band(flags, bnot(@alt))}
      true -> {font, flags}
    end
  end

  defp blink_off?(rate) do
    seconds = System.monotonic_time(:millisecond) / 1000
    rem(trunc(seconds * rate), 2) == 1
  end

  defp scaled_colour(pen, font, flags) when band(flags, @rich) != 0 do
    col = band(flags, @alt ||| @rich ||| @rich_bits)

    if col == pen.mask do
      pen
    else
      pen = if elem(pen.back, 3) != 0, do: flush_batch(pen), else: pen
      rgba = rich_rgba(col)
      %{pen | mask: col, back: {0, 0, 0, 0}, fore: tinted(rgba, font, flags, pen.tint, 1.0)}
    end
  end

  defp scaled_colour(pen, font, flags) do
    col = band(flags, @alt ||| @nonclear ||| @bg_mask ||| @fg_mask ||| @half)

    if col == pen.mask do
      pen
    else
      wanted_back = if band(flags, @nonclear) != 0, do: 127, else: 0
      pen = if elem(pen.back, 3) != wanted_back, do: flush_batch(pen), else: pen
      back = back_colour(flags, 0xC0)
      %{pen | mask: col, back: back, fore: tinted(plain_rgba(flags), font, flags, pen.tint, 1.0)}
    end
  end

  defp rich_rgba(col) do
    {band(col >>> 28, 15) * 0x11, band(col >>> 24, 15) * 0x11, band(col >>> 20, 15) * 0x11, 255}
  end

  defp plain_rgba(flags) do
    {r, g, b} = elem(@consolecolours, band(flags, @fg_mask) >>> 24)

    if band(flags, @half) != 0,
      do: {r * 0x7F, g * 0x7F, b * 0x7F, 0x7F},
      else: {r * 255, g * 255, b * 255, 255}
  end

  defp back_colour(flags, scale) when band(flags, @nonclear) != 0 do
    {r, g, b} = elem(@consolecolours, band(flags, @bg_mask) >>> 28)
    {byte(r * scale), byte(g * scale), byte(b * scale), 0xC0}
  end

  defp back_colour(_flags, _scale), do: {0, 0, 0, 0}

  defp tinted({r, g, b, a}, font, flags, {fr, fg, fb, fa}, pulse) do
    {tr, tg, tb} = if band(flags, @alt) != 0, do: font.alttint, else: font.tint

    {byte(r * tr * fr * pulse), byte(g * tg * fg * pulse), byte(b * tb * fb * pulse),
     byte(a * fa * pulse)}
  end

  defp scaled_quad(pen, font, char, px, py, _flags) do
    {sw, sh} =
      if char.plane == :grid,
        do: {font.charheight * pen.cw, font.charheight * pen.ch},
        else: {char.bmw * pen.cw, char.bmh * pen.ch}

    quad = {:texture, char, {px + char.left * pen.cw, py + char.top * pen.ch, sw, sh}, pen.fore}
    pen = %{pen | quads: [quad | pen.quads]}

    if band(pen.mask, @nonclear) != 0,
      do: %{pen | backs: [{:fill, {px, py, char.advance, font.charheight}, pen.back} | pen.backs]},
      else: pen
  end

  defp flush_batch(pen) do
    backs =
      if band(pen.mask, @rich ||| @nonclear) == @nonclear, do: Enum.reverse(pen.backs), else: []

    %{pen | flushed: pen.flushed ++ backs ++ Enum.reverse(pen.quads), quads: [], backs: []}
  end

  defp flush(s, pen) do
    pen = flush_batch(pen)
    paint(s, pen.flushed, pen.additive)
  end

  defp line_width(font, chars),
    do: Enum.reduce(chars, 0, fn {flags, code}, x -> end_coord(font, x, flags, code) end)

  defp end_coord(_font, x, flags, _code) when band(flags, @hidden) != 0, do: x
  defp end_coord(font, x, _flags, ?\t), do: tab_width(font, x)

  defp end_coord(font, x, flags, code) do
    font = if band(flags, @alt) != 0 and font.alt != nil, do: font.alt, else: font

    case Font.char(font, code) do
      nil -> x
      char -> x + char.advance
    end
  end

  defp tab_width(font, x) do
    space =
      case Font.char(font, ?\s),
        do: (
          nil -> 0
          char -> char.advance
        )

    tab = if space == 0, do: font.charheight, else: space
    tab = tab * 8
    x = x + 1
    x + rem(tab - rem(x, tab), tab)
  end

  defp field(s, font, {x, y, w, h}, chars, flags) do
    chars = List.to_tuple(chars)
    {x, w} = plaque_rect(x, w, flags)

    if band(flags, @plaque) != 0 and w < 32 do
      {s, 0}
    else
      draw_field(s, font, {x, y, w, h}, chars, flags)
    end
  end

  defp plaque_rect(x, w, flags) when band(flags, @plaque) != 0 do
    {x, w} = if w > 320, do: {x + div(w, 2) - 160, 320}, else: {x, w}
    {x + 16, w - 32}
  end

  defp plaque_rect(x, w, _flags), do: {x, w}

  defp draw_field(s, font, {x, y, w, h}, chars, flags) do
    {rx, ry} = Screen.ratio(s)
    {left, top} = {trunc(x * rx), trunc(y * ry)}
    {right, bottom} = {trunc((x + w) * rx), trunc((y + h) * ry)}
    width = if band(flags, @nowrap) != 0, do: 0x7FFFFFFF, else: right - left
    lines = line_breaks(font, chars, width, 512)
    count = length(lines)
    ch = font.charheight
    remaining = if band(flags, @typewriter) != 0, do: 0, else: 9999

    start_y =
      cond do
        band(flags, @top) != 0 -> top
        band(flags, @bottom) != 0 -> bottom - ch * count
        band(flags, @obituary) != 0 -> trunc((bottom - top - ch * count) * 0.65 + top)
        count <= 5 -> trunc((bottom - top - ch * count) * 0.35 + top)
        true -> trunc((bottom - top - ch * count) * 0.5 + top)
      end

    s = if band(flags, @plaque) != 0, do: plaque(s, x, start_y / ry, w, count * ch / ry), else: s
    pen = %{pen(font, 1.0, 1.0) | tint: {1.0, 1.0, 1.0, 1.0}}

    pen =
      draw_lines(lines, %{
        pen: pen,
        font: font,
        chars: chars,
        y: start_y,
        bottom: bottom,
        left: left,
        right: right,
        flags: flags,
        remaining: remaining,
        last: count - 1,
        index: 0
      })

    {flush(s, pen), count}
  end

  defp draw_lines([], field), do: field.pen

  defp draw_lines(_lines, %{y: y, bottom: bottom} = field) when y >= bottom, do: field.pen

  defp draw_lines([{from, to} | rest], field) do
    line_width = span_width(field.font, field.chars, from, to)

    x =
      cond do
        band(field.flags, @right) != 0 -> field.right - line_width
        band(field.flags, @left) != 0 -> field.left
        true -> field.left + div(field.right - field.left - line_width, 2)
      end

    remaining = field.remaining - (to - from)
    to = if remaining <= 0, do: max(to + remaining, from), else: to
    pen = draw_span(field.pen, field.chars, from, to, x, field.y)

    if remaining <= 0 or field.index == field.last do
      typewriter_cursor(pen, field, x + span_width(field.font, field.chars, from, to))
    else
      draw_lines(rest, %{
        field
        | pen: pen,
          y: field.y + field.font.charheight,
          remaining: remaining,
          index: field.index + 1
      })
    end
  end

  defp typewriter_cursor(pen, field, x) do
    if band(field.flags, @typewriter ||| @persist) == @typewriter and blink_off?(4),
      do: pixel_char(pen, x, field.y, @white, 0xE00B),
      else: pen
  end

  defp span_width(font, chars, from, to) do
    Enum.reduce(from..(to - 1)//1, 0, fn i, x ->
      {flags, code} = elem(chars, i)
      end_coord(font, x, flags, code)
    end)
  end

  defp draw_span(pen, chars, from, to, x, y) do
    {pen, _lx} =
      Enum.reduce(from..(to - 1)//1, {pen, 0}, fn i, {acc, lx} ->
        {flags, code} = elem(chars, i)
        acc = pixel_char(acc, x + lx, y, flags, code)
        {acc, end_coord(acc.curfont, lx, flags, code)}
      end)

    pen
  end

  defp pixel_char(pen, _px, _py, flags, _code) when band(flags, @hidden) != 0, do: pen

  defp pixel_char(pen, px, py, flags, code) do
    {font, flags} = alternate(pen.curfont, flags, code, false)

    case Font.char(font, code) do
      nil ->
        pen

      _char when code == ?\t ->
        pen

      _char when code == ?\s and band(flags, @rich ||| @nonclear) != @nonclear ->
        pen

      char ->
        pen = pixel_colour(pen, font, flags)
        fore = if char.white, do: {255, 255, 255, 255}, else: pen.fore

        {sw, sh} =
          if char.plane == :grid, do: {char.advance, font.charheight}, else: {char.bmw, char.bmh}

        quad = {:texture, char, {px + char.left, py + char.top, sw, sh}, fore}
        pen = %{pen | quads: [quad | pen.quads]}

        if band(pen.mask, @nonclear) != 0,
          do: %{
            pen
            | backs: [{:fill, {px, py, char.advance, font.charheight}, pen.back} | pen.backs]
          },
          else: pen
    end
  end

  defp pixel_colour(pen, font, flags) when band(flags, @rich) != 0 do
    col = band(flags, @alt ||| @blink ||| @rich ||| @rich_bits)

    if col == pen.mask do
      pen
    else
      pen = if band(pen.mask, @nonclear) != 0, do: flush_batch(pen), else: pen

      %{
        pen
        | mask: col,
          back: {0, 0, 0, 0},
          fore: tinted(rich_rgba(col), font, flags, pen.tint, pulse(flags))
      }
    end
  end

  defp pixel_colour(pen, font, flags) do
    col = band(flags, @alt ||| @nonclear ||| @bg_mask ||| @fg_mask ||| @half ||| @blink)

    if col == pen.mask do
      pen
    else
      pen = if band(bxor(col, pen.mask), @nonclear) != 0, do: flush_batch(pen), else: pen
      back = back_colour(flags, 255)

      %{
        pen
        | mask: col,
          back: back,
          fore: tinted(plain_rgba(flags), font, flags, pen.tint, pulse(flags))
      }
    end
  end

  defp pulse(flags) when band(flags, @blink) != 0 do
    seconds = System.monotonic_time(:millisecond) / 1000
    (:math.sin(seconds * 3) + 1) * 0.4 + 0.2
  end

  defp pulse(_flags), do: 1.0

  defp line_breaks(font, chars, width, most),
    do: breaks(font, chars, 0, tuple_size(chars), width, most, [])

  defp breaks(_font, _chars, start, finish, _width, _most, acc) when start >= finish,
    do: Enum.reverse(acc)

  defp breaks(font, chars, start, finish, width, most, acc) do
    {l, px} = scan_line(font, chars, start, finish, width, start, 0)
    l = if px > width, do: back_to_space(chars, start, l), else: l
    acc = [{start, l} | acc]

    if length(acc) == most do
      Enum.reverse(acc)
    else
      next = skip_spaces(chars, l, finish)

      cond do
        next == finish -> Enum.reverse(acc)
        newline?(elem(chars, next)) -> breaks(font, chars, next + 1, finish, width, most, acc)
        true -> breaks(font, chars, next, finish, width, most, acc)
      end
    end
  end

  defp scan_line(_font, _chars, _start, finish, width, l, px) when px > width or l >= finish,
    do: {l, px}

  defp scan_line(font, chars, start, finish, width, l, px) do
    {flags, code} = elem(chars, l)

    if band(flags, @hidden) == 0 and code in [?\n, ?\v],
      do: {l, px},
      else: scan_line(font, chars, start, finish, width, l + 1, end_coord(font, px, flags, code))
  end

  defp back_to_space(chars, start, bt) do
    l = find_space(chars, start, bt)
    if l == start and bt > start, do: bt - 1, else: l
  end

  defp find_space(_chars, start, l) when l <= start, do: start

  defp find_space(chars, start, l) do
    {_flags, code} = elem(chars, l - 1)
    if code > ?\s, do: find_space(chars, start, l - 1), else: l - 1
  end

  defp skip_spaces(_chars, l, finish) when l >= finish, do: l

  defp skip_spaces(chars, l, finish) do
    {flags, code} = elem(chars, l)

    if band(flags, @hidden) == 0 and code != ?\s,
      do: l,
      else: skip_spaces(chars, l + 1, finish)
  end

  defp newline?({flags, code}), do: band(flags, @hidden) == 0 and code in [?\n, ?\v]

  defp plaque(s, x, y, w, h) do
    box = Screen.to_pixels(s, {x - 8, y - 8, w + 16, h + 16})
    paint(s, [{:straight, box, {0.1, 0.1, 0.1, 0.9}}], false)
  end

  defp paint(s, [], _additive), do: s

  defp paint(s, quads, additive) do
    %{rows: rows, clip: clip} = s.ext.screen
    placed = quads |> Enum.map(&place(&1, clip)) |> Enum.reject(&is_nil/1)

    case placed do
      [] ->
        s

      _ ->
        y0 = placed |> Enum.map(&elem(&1, 1)) |> Enum.min()
        y1 = placed |> Enum.map(&elem(&1, 3)) |> Enum.max()

        rows =
          Enum.reduce(y0..(y1 - 1)//1, rows, fn y, acc ->
            put_elem(acc, y, Enum.reduce(placed, elem(acc, y), &paint_row(&1, &2, y, additive)))
          end)

        %{s | ext: put_in(s.ext, [:screen, :rows], rows)}
    end
  end

  defp place({_kind, _char, {_x, _y, w, h}, _colour}, _clip) when w <= 0 or h <= 0, do: nil
  defp place({_kind, {_x, _y, w, h}, _colour}, _clip) when w <= 0 or h <= 0, do: nil

  defp place({:texture, %{texture: nil}, _rect, _colour}, _clip), do: nil

  defp place({:texture, char, {x, y, w, h} = rect, colour}, clip),
    do: bounded({:texture, char, rect, colour}, {x, y, w, h}, clip)

  defp place({kind, rect, colour}, clip), do: bounded({kind, nil, rect, colour}, rect, clip)

  defp bounded(quad, {x, y, w, h}, {cx0, cy0, cx1, cy1}) do
    px0 = max(ceil(x - 0.5), cx0)
    py0 = max(ceil(y - 0.5), cy0)
    px1 = min(ceil(x + w - 0.5), cx1)
    py1 = min(ceil(y + h - 0.5), cy1)
    if px1 <= px0 or py1 <= py0, do: nil, else: {px0, py0, px1, py1, quad}
  end

  defp paint_row({px0, py0, px1, py1, quad}, row, y, additive) when y >= py0 and y < py1 do
    under = binary_part(row, px0 * 4, (px1 - px0) * 4)

    over =
      for {<<r, g, b, a>>, x} <- Enum.zip(words(under), px0..(px1 - 1)),
          into: <<>>,
          do: blend(quad, x, y, {r, g, b, a}, additive)

    [binary_part(row, 0, px0 * 4), over, binary_part(row, px1 * 4, byte_size(row) - px1 * 4)]
    |> IO.iodata_to_binary()
  end

  defp paint_row(_placed, row, _y, _additive), do: row

  defp words(binary), do: for(<<word::binary-4 <- binary>>, do: word)

  defp blend({:straight, nil, _rect, {r, g, b, a}}, _x, _y, {dr, dg, db, da}, _additive) do
    <<out(r * a * 255 + dr * (1 - a)), out(g * a * 255 + dg * (1 - a)),
      out(b * a * 255 + db * (1 - a)), da>>
  end

  defp blend({:fill, nil, _rect, {r, g, b, a}}, _x, _y, destination, additive),
    do: combine({r / 255, g / 255, b / 255, a / 255}, destination, additive)

  defp blend({:texture, char, {sx, sy, sw, sh}, {r, g, b, a}}, x, y, destination, additive) do
    u = char.s0 + (x + 0.5 - sx) / sw * (char.s1 - char.s0)
    v = char.t0 + (y + 0.5 - sy) / sh * (char.t1 - char.t0)
    {tr, tg, tb, ta} = sample(char.texture, u, v)
    source = {tr * r / 255, tg * g / 255, tb * b / 255, ta * a / 255}
    combine(source, destination, additive)
  end

  defp combine({r, g, b, a}, {dr, dg, db, da}, false) do
    <<out(r * 255 + dr * (1 - a)), out(g * 255 + dg * (1 - a)), out(b * 255 + db * (1 - a)), da>>
  end

  defp combine({r, g, b, a}, {dr, dg, db, da}, true) do
    <<out(dr + r * a * 255), out(dg + g * a * 255), out(db + b * a * 255), da>>
  end

  defp out(value) when value >= 254.5, do: 255
  defp out(value) when value <= 0, do: 0
  defp out(value), do: round(value)

  defp sample(texture, u, v) do
    fx = u * texture.width - 0.5
    fy = v * texture.height - 0.5
    x0 = floor(fx)
    y0 = floor(fy)
    ax = fx - x0
    ay = fy - y0
    {r00, g00, b00, a00} = texel(texture, x0, y0)
    {r10, g10, b10, a10} = texel(texture, x0 + 1, y0)
    {r01, g01, b01, a01} = texel(texture, x0, y0 + 1)
    {r11, g11, b11, a11} = texel(texture, x0 + 1, y0 + 1)

    mix = fn c00, c10, c01, c11 ->
      ((c00 * (1 - ax) + c10 * ax) * (1 - ay) + (c01 * (1 - ax) + c11 * ax) * ay) / 255
    end

    {mix.(r00, r10, r01, r11), mix.(g00, g10, g01, g11), mix.(b00, b10, b01, b11),
     mix.(a00, a10, a01, a11)}
  end

  defp texel(texture, x, y) do
    x = x |> max(0) |> min(texture.width - 1)
    y = y |> max(0) |> min(texture.height - 1)
    <<r, g, b, a>> = binary_part(texture.pixels, (y * texture.width + x) * 4, 4)
    {r, g, b, a}
  end
end
