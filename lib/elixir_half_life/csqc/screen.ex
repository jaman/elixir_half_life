defmodule ElixirHalfLife.Csqc.Screen do
  @moduledoc """
  The client program's 2D drawing builtins: pictures, parts of pictures, filled boxes,
  lines, clip areas, pictures turned about a point, and sprite frames' picture names;
  the text builtins (characters, strings, string widths, fonts and text fields) are
  `ElixirHalfLife.Csqc.Text`'s.

  A picture named with no picture of a size (`ElixirHalfLife.Pictures.get/1`) is drawn
  as `ElixirHalfLife.Pictures.from_wad/1` gives it, as FTE's `drawpic` and `drawsubpic`
  fall back. A picture or part of one drawn with a width or height below zero is mirrored along
  that axis, over the box its size reaches back to. A sprite frame's picture
  (named as `ElixirHalfLife.Csqc.Sprites` names them) is cut away where its alpha is
  below 0.666 and otherwise, unless added, hides what is under it where its alpha times
  `alpha` is at least one half.

  Positions and sizes are in 2D units (FTE's virtual screen, `virtual`), each
  `ratio/1` pixels across and down; clip areas are kept in pixels.

  Drawing goes onto the host's `ext.screen`, `%{rows:, width:, height:, virtual:,
  clip:}`: `rows` a tuple of the picture's rows, each `width` RGBA pixels (`frame/1`
  gives them as a `Cauldron3D.Frame` and `put_frame/2` takes one back), `clip`
  `{x0, y0, x1, y1}`.
  Colours are tinted by `rgb` (each 0.0 to 1.0) and laid over by `alpha`, or added when
  the draw flag's low bits are 1.
  """

  import Bitwise

  alias Cauldron3D.Formats.Spr
  alias Cauldron3D.{Frame, Texture}
  alias ElixirHalfLife.Csqc.{Sprites, Text}
  alias ElixirHalfLife.Pictures
  alias QuakeServer.Args

  @text [320, 321, 326, 327, 356, 357, "drawtextfield"]

  @doc """
  A fresh screen of `width` by `height` pixels, black, drawn on in 2D units of which
  the whole screen is `virtual`, `{virtual_width, virtual_height}`; and the host holding it.
  """
  @spec begin(map(), pos_integer(), pos_integer(), {pos_integer(), pos_integer()}) :: map()
  def begin(s, width, height, virtual) do
    row = :binary.copy(<<0, 0, 0, 255>>, width)

    screen = %{
      rows: Tuple.duplicate(row, height),
      width: width,
      height: height,
      virtual: virtual,
      clip: {0, 0, width, height}
    }

    %{s | ext: Map.put(s.ext, :screen, screen)}
  end

  @doc "The screen's size in 2D units, `{width, height}`, or `nil` before `begin/4`."
  @spec virtual_size(map()) :: {pos_integer(), pos_integer()} | nil
  def virtual_size(s) do
    case Map.get(s.ext, :screen, %{}) do
      %{virtual: virtual} -> virtual
      _ -> nil
    end
  end

  @doc "Pixels per 2D unit across and down, `{1.0, 1.0}` before `begin/4`."
  @spec ratio(map()) :: {float(), float()}
  def ratio(s) do
    case Map.get(s.ext, :screen, %{}) do
      %{virtual: {vw, vh}, width: width, height: height} -> {width / vw, height / vh}
      _ -> {1.0, 1.0}
    end
  end

  @doc "The box `{x, y, w, h}` in 2D units as a box in pixels."
  @spec to_pixels(map(), {number(), number(), number(), number()}) ::
          {float(), float(), float(), float()}
  def to_pixels(s, {x, y, w, h}) do
    {rx, ry} = ratio(s)
    {x * rx, y * ry, w * rx, h * ry}
  end

  @doc "The screen's picture as a frame, or `nil` before `begin/4`."
  @spec frame(map()) :: Frame.t() | nil
  def frame(s) do
    case Map.get(s.ext, :screen, %{}) do
      %{rows: rows, width: width, height: height} ->
        %Frame{
          width: width,
          height: height,
          pixels: rows |> Tuple.to_list() |> IO.iodata_to_binary(),
          format: :rgba
        }

      _ ->
        nil
    end
  end

  @doc "The screen's size in pixels, `{width, height}`, or `nil` before `begin/4`."
  @spec size(map()) :: {pos_integer(), pos_integer()} | nil
  def size(s) do
    case Map.get(s.ext, :screen, %{}) do
      %{width: width, height: height} -> {width, height}
      _ -> nil
    end
  end

  @doc "The screen with its picture replaced by `frame`, an RGBA frame of the screen's size."
  @spec put_frame(map(), Frame.t()) :: map()
  def put_frame(s, %Frame{width: width, height: height, pixels: pixels}) do
    row_bytes = width * 4

    rows =
      for(y <- 0..(height - 1), do: binary_part(pixels, y * row_bytes, row_bytes))
      |> List.to_tuple()

    put_screen(s, :rows, rows)
  end

  @doc "Run screen builtin `builtin`."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, builtin, argc) when builtin in @text, do: Text.call(s, builtin, argc)

  def call(s, 317, _argc), do: Args.return(s, Args.str(s, 0))

  def call(s, 316, _argc), do: Args.return(s, if(picture(Args.str(s, 0)), do: 1.0, else: 0.0))

  def call(s, 319, _argc), do: s

  def call(s, 318, _argc) do
    case picture(Args.str(s, 0)) do
      {%Texture{width: w, height: h}, _kind} -> Args.return(s, {w / 1, h / 1, 0.0})
      nil -> Args.return(s, {0.0, 0.0, 0.0})
    end
  end

  def call(s, 322, argc) do
    {x, y, _} = Args.vec(s, 0)
    {w, h, _} = Args.vec(s, 2)

    {box, source} =
      if w < 0 != h < 0,
        do: {{x + w, y + h, -w, -h}, {1.0, 1.0, -1.0, -1.0}},
        else: {{x, y, w, h}, {0.0, 0.0, 1.0, 1.0}}

    {picture, kind} = drawn_picture(Args.str(s, 1))

    s
    |> draw(picture, to_pixels(s, box), source, sprite_tint(kind, tint(s, 3, 4, 5, argc, :given)))
    |> Args.return(1.0)
  end

  def call(s, 328, argc) do
    {x, y, _} = Args.vec(s, 0)
    {w, h, _} = Args.vec(s, 1)
    {sx, sy, _} = Args.vec(s, 3)
    {sw, sh, _} = Args.vec(s, 4)

    {box, source} =
      if w < 0 != h < 0,
        do: {{x + w, y + h, -w, -h}, {sx + sw, sy + sh, -sw, -sh}},
        else: {{x, y, w, h}, {sx, sy, sw, sh}}

    {picture, kind} = drawn_picture(Args.str(s, 2))

    s
    |> draw(picture, to_pixels(s, box), source, sprite_tint(kind, tint(s, 5, 6, 7, argc, :given)))
    |> Args.return(1.0)
  end

  def call(s, 315, argc) do
    {x0, y0, _} = Args.vec(s, 1)
    {x1, y1, _} = Args.vec(s, 2)
    {rgb, alpha, mode} = tint(s, 3, 4, 5, argc, :given)
    {rx, ry} = ratio(s)
    line(s, {x0 * rx, y0 * ry}, {x1 * rx, y1 * ry}, rgb, alpha, mode)
  end

  def call(s, 323, argc) do
    {x, y, _} = Args.vec(s, 0)
    {w, h, _} = Args.vec(s, 1)
    {r, g, b} = Args.vec(s, 2)
    flag = if argc > 4, do: trunc(Args.num(s, 4)), else: 0

    s
    |> fill(to_pixels(s, {x, y, w, h}), {r, g, b}, Args.num(s, 3), band(flag, 3))
    |> Args.return(1.0)
  end

  def call(s, 324, _argc) do
    {x, y, w, h} = to_pixels(s, {Args.num(s, 0), Args.num(s, 1), Args.num(s, 2), Args.num(s, 3)})
    %{width: width, height: height} = s.ext.screen

    clip =
      {clamp(trunc(x), width), clamp(trunc(y), height), clamp(trunc(x + w), width),
       clamp(trunc(y + h), height)}

    put_screen(s, :clip, clip)
  end

  def call(s, 325, _argc) do
    %{width: width, height: height} = s.ext.screen
    put_screen(s, :clip, {0, 0, width, height})
  end

  def call(s, "spriteframe", _argc) do
    model = Args.str(s, 0)
    Args.return(s, sprite_frame_name(model, Args.int(s, 1), Args.num(s, 2)))
  end

  def call(s, builtin, argc) when builtin in ["drawrotpic", "drawrotsubpic"] do
    {px, py, _} = Args.vec(s, 0)
    {mx, my, _} = Args.vec(s, 1)
    {w, h, _} = Args.vec(s, 3)

    {source, rgb_at, angle_at} =
      if builtin == "drawrotpic",
        do: {{0.0, 0.0, 1.0, 1.0}, 4, 6},
        else:
          {{elem(Args.vec(s, 4), 0), elem(Args.vec(s, 4), 1), elem(Args.vec(s, 5), 0),
            elem(Args.vec(s, 5), 1)}, 6, 8}

    angle = if argc > angle_at, do: Args.num(s, angle_at), else: 0.0

    case Pictures.get(Args.str(s, 2)) do
      nil ->
        s

      picture ->
        rotated(
          s,
          picture,
          {px, py},
          {mx, my, w, h},
          source,
          angle,
          tint(s, rgb_at, rgb_at + 1, rgb_at + 2, argc)
        )
    end
  end

  defp sprite_frame_name(model, frame, time) do
    with data when is_binary(data) <- ElixirHalfLife.Assets.read(model),
         {:ok, %Spr{frames: frames}} <- Spr.parse(data),
         true <- frame >= 0 and frame < tuple_size(frames) do
      case elem(frames, frame) do
        {:single, _} -> "#{model}_#{frame}.tga"
        {:group, pictures} -> "#{model}_#{frame}_#{within(pictures, time)}.tga"
      end
    else
      _ -> ""
    end
  end

  defp within(pictures, time) do
    {_, full} = List.last(pictures)
    time = if full > 0, do: time - trunc(time / full) * full, else: 0.0

    pictures |> Enum.drop(-1) |> Enum.find_index(fn {_, until} -> until > time end) ||
      length(pictures) - 1
  end

  defp drawn_picture(name), do: picture(name) || {Pictures.from_wad(name), :picture}

  defp picture(name) do
    case Sprites.picture(name) do
      nil ->
        case Pictures.get(name) do
          nil -> nil
          picture -> {picture, :picture}
        end

      texture ->
        {texture, :sprite}
    end
  end

  defp sprite_tint(:sprite, {rgb, alpha, mode}), do: {rgb, alpha, {:sprite, mode}}
  defp sprite_tint(:picture, tint), do: tint

  defp tint(s, rgb_at, alpha_at, flag_at, argc, :given) do
    rgb = Args.vec(s, rgb_at)
    alpha = if argc > alpha_at, do: Args.num(s, alpha_at), else: 0.0
    mode = if argc > flag_at, do: band(trunc(Args.num(s, flag_at)), 3), else: 0
    {rgb, alpha, mode}
  end

  defp line(s, {x0, y0}, {x1, y1}, rgb, alpha, mode) do
    steps = max(ceil(max(abs(x1 - x0), abs(y1 - y0))), 1)

    Enum.reduce(0..steps, s, fn i, acc ->
      t = i / steps
      fill(acc, {floor(x0 + (x1 - x0) * t), floor(y0 + (y1 - y0) * t), 1, 1}, rgb, alpha, mode)
    end)
  end

  defp tint(s, rgb_at, alpha_at, flag_at, argc) do
    rgb = if argc > rgb_at, do: Args.vec(s, rgb_at), else: {1.0, 1.0, 1.0}
    rgb = if rgb == {0.0, 0.0, 0.0} and argc <= rgb_at, do: {1.0, 1.0, 1.0}, else: rgb
    alpha = if argc > alpha_at, do: Args.num(s, alpha_at), else: 1.0
    mode = if argc > flag_at, do: band(trunc(Args.num(s, flag_at)), 3), else: 0
    {rgb, alpha, mode}
  end

  defp fill(s, {x, y, w, h}, {r, g, b}, alpha, mode) do
    colour = <<channel(r * 255), channel(g * 255), channel(b * 255), 255>>
    {x0, y0, x1, y1} = area(s, {x, y, w, h})

    if x1 <= x0 or y1 <= y0 or alpha <= 0 do
      s
    else
      rows(s, y0, y1, fn row, _y ->
        under = binary_part(row, x0 * 4, (x1 - x0) * 4)
        over = :binary.copy(colour, x1 - x0)
        splice(row, x0, x1, mix(under, over, alpha, mode))
      end)
    end
  end

  defp draw(s, %Texture{} = picture, {x, y, w, h}, source, {rgb, alpha, mode} = tint) do
    {x0, y0, x1, y1} = area = area(s, {x, y, w, h})

    if x1 <= x0 or y1 <= y0 or w == 0 or h == 0 or alpha <= 0 or adds_nothing?(rgb, mode),
      do: s,
      else: draw_rows(s, picture, {x, y, w, h}, area, source, tint)
  end

  defp adds_nothing?({r, g, b}, mode) when mode in [1, {:sprite, 1}],
    do: r <= 0 and g <= 0 and b <= 0

  defp adds_nothing?(_rgb, _mode), do: false

  defp draw_rows(
         s,
         picture,
         {x, y, w, h},
         {x0, y0, x1, y1},
         {sx, sy, sw, sh},
         {rgb, alpha, mode}
       ) do
    columns =
      for px <- x0..(x1 - 1) do
        u = (sx + (px + 0.5 - x) / w * sw) * picture.width
        (floor(u) |> max(0) |> min(picture.width - 1)) * 4
      end

    rows(s, y0, y1, fn row, py ->
      v = (sy + (py + 0.5 - y) / h * sh) * picture.height

      line =
        binary_part(
          picture.pixels,
          (floor(v) |> max(0) |> min(picture.height - 1)) * picture.width * 4,
          picture.width * 4
        )

      under = binary_part(row, x0 * 4, (x1 - x0) * 4)
      splice(row, x0, x1, over_row(under, columns, line, rgb, alpha, mode, []))
    end)
  end

  defp over_row(
         <<under_pixel::binary-4, under::binary>>,
         [c | columns],
         line,
         tint,
         alpha,
         mode,
         acc
       ) do
    <<_::binary-size(^c), over_pixel::binary-4, _::binary>> = line
    pixel = over_pixel(under_pixel, over_pixel, tint, alpha, mode)
    over_row(under, columns, line, tint, alpha, mode, [pixel | acc])
  end

  defp over_row(_under, _columns, _line, _tint, _alpha, _mode, acc), do: Enum.reverse(acc)

  defp over_pixel(under, <<_r, _g, _b, a>>, _tint, _alpha, {:sprite, _}) when a < 170, do: under

  defp over_pixel(under, over, tint, alpha, {:sprite, 1}),
    do: over_pixel(under, over, tint, alpha, 1)

  defp over_pixel(<<_, _, _, ua>> = under, <<r, g, b, a>>, {tr, tg, tb}, alpha, {:sprite, _}) do
    if alpha * a / 255 >= 0.5,
      do: <<channel(r * tr), channel(g * tg), channel(b * tb), ua>>,
      else: under
  end

  defp over_pixel(under, <<0, 0, 0, _a>>, _tint, _alpha, 1), do: under

  defp over_pixel(<<ur, ug, ub, ua>> = under, <<r, g, b, a>>, {tr, tg, tb}, alpha, 1) do
    k = alpha * a / 255

    if k <= 0,
      do: under,
      else: <<channel(ur + r * tr * k), channel(ug + g * tg * k), channel(ub + b * tb * k), ua>>
  end

  defp over_pixel(<<ur, ug, ub, ua>> = under, <<r, g, b, a>>, {tr, tg, tb}, alpha, _mode) do
    k = alpha * a / 255

    cond do
      k <= 0 ->
        under

      k >= 1 ->
        <<channel(r * tr), channel(g * tg), channel(b * tb), ua>>

      true ->
        <<channel(r * tr * k + ur * (1 - k)), channel(g * tg * k + ug * (1 - k)),
          channel(b * tb * k + ub * (1 - k)), ua>>
    end
  end

  defp rotated(s, picture, {px, py}, {mx, my, w, h}, {sx, sy, sw, sh}, angle, {rgb, alpha, mode}) do
    radians = angle * :math.pi() / 180
    {c, n} = {:math.cos(radians), :math.sin(radians)}
    reach = :math.sqrt((abs(mx) + abs(w)) ** 2 + (abs(my) + abs(h)) ** 2)
    {rx, ry} = ratio(s)
    box = to_pixels(s, {px - reach, py - reach, 2 * reach, 2 * reach})
    {x0, _y0, x1, _y1} = bounds = area(s, box)

    rows_within(s, bounds, fn row, y ->
      over =
        for x <- x0..(x1 - 1), into: <<>> do
          {dx, dy} = {(x + 0.5) / rx - px, (y + 0.5) / ry - py}
          local = {dx * c + dy * n - mx, -dx * n + dy * c - my}
          rotated_texel(picture, local, {w, h}, {sx, sy, sw, sh}, rgb)
        end

      splice(row, x0, x1, mix(binary_part(row, x0 * 4, (x1 - x0) * 4), over, alpha, mode))
    end)
  end

  defp rows_within(s, {x0, y0, x1, y1}, _row_fun) when x1 <= x0 or y1 <= y0, do: s
  defp rows_within(s, {_x0, y0, _x1, y1}, row_fun), do: rows(s, y0, y1, row_fun)

  defp rotated_texel(picture, {lx, ly}, {w, h}, {sx, sy, sw, sh}, rgb)
       when lx >= 0 and ly >= 0 and lx < w and ly < h do
    u = floor((sx + lx / w * sw) * picture.width) |> max(0) |> min(picture.width - 1)
    v = floor((sy + ly / h * sh) * picture.height) |> max(0) |> min(picture.height - 1)
    shade(binary_part(picture.pixels, (v * picture.width + u) * 4, 4), rgb)
  end

  defp rotated_texel(_picture, _local, _size, _source, _rgb), do: <<0, 0, 0, 0>>

  defp shade(<<r, g, b, a>>, {1.0, 1.0, 1.0}), do: <<r, g, b, a>>

  defp shade(<<r, g, b, a>>, {tr, tg, tb}),
    do: <<channel(r * tr), channel(g * tg), channel(b * tb), a>>

  defp mix(under, over, alpha, mode), do: mix(under, over, alpha, mode, [])

  defp mix(
         <<under_pixel::binary-4, under::binary>>,
         <<over_pixel::binary-4, over::binary>>,
         alpha,
         mode,
         acc
       ),
       do: mix(under, over, alpha, mode, [mixed(under_pixel, over_pixel, alpha, mode) | acc])

  defp mix(_under, _over, _alpha, _mode, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp mixed(under, <<_r, _g, _b, a>>, _alpha, {:sprite, _}) when a < 170, do: under

  defp mixed(under, <<_, _, _, a>> = over, alpha, {:sprite, 1}),
    do: added(under, over, alpha * a / 255)

  defp mixed(<<_, _, _, ua>> = under, <<r, g, b, a>>, alpha, {:sprite, _}) do
    if alpha * a / 255 >= 0.5, do: <<r, g, b, ua>>, else: under
  end

  defp mixed(under, <<_, _, _, a>> = over, alpha, 1), do: added(under, over, alpha * a / 255)

  defp mixed(<<ur, ug, ub, ua>> = under, <<r, g, b, a>>, alpha, _mode) do
    k = alpha * a / 255

    cond do
      k >= 1 ->
        <<r, g, b, ua>>

      k <= 0 ->
        under

      true ->
        <<channel(r * k + ur * (1 - k)), channel(g * k + ug * (1 - k)),
          channel(b * k + ub * (1 - k)), ua>>
    end
  end

  defp added(<<ur, ug, ub, ua>>, <<r, g, b, _a>>, k),
    do: <<channel(ur + r * k), channel(ug + g * k), channel(ub + b * k), ua>>

  defp area(s, {x, y, w, h}) do
    {cx0, cy0, cx1, cy1} = s.ext.screen.clip
    {left, right} = if w < 0, do: {x + w, x}, else: {x, x + w}
    {top, bottom} = if h < 0, do: {y + h, y}, else: {y, y + h}
    {max(floor(left), cx0), max(floor(top), cy0), min(ceil(right), cx1), min(ceil(bottom), cy1)}
  end

  defp rows(s, y0, y1, change) do
    rows = s.ext.screen.rows

    changed =
      if (y1 - y0) * s.ext.screen.width >= 8192 do
        y0..(y1 - 1)
        |> Enum.chunk_every(max(div(y1 - y0, System.schedulers_online()), 1))
        |> Task.async_stream(fn ys -> Enum.map(ys, &{&1, changed_row(change, rows, &1)}) end,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, done} -> done end)
      else
        for y <- y0..(y1 - 1), do: {y, changed_row(change, rows, y)}
      end

    put_screen(
      s,
      :rows,
      Enum.reduce(changed, rows, fn {y, row}, acc -> put_elem(acc, y, row) end)
    )
  end

  defp changed_row(change, rows, y), do: IO.iodata_to_binary(change.(elem(rows, y), y))

  defp splice(row, x0, x1, middle),
    do: [binary_part(row, 0, x0 * 4), middle, binary_part(row, x1 * 4, byte_size(row) - x1 * 4)]

  defp put_screen(s, key, value),
    do: %{s | ext: Map.update(s.ext, :screen, %{key => value}, &Map.put(&1, key, value))}

  defp clamp(value, limit), do: value |> max(0) |> min(limit)

  defp channel(value) when value >= 255, do: 255
  defp channel(value) when value <= 0, do: 0
  defp channel(value), do: trunc(value)
end
