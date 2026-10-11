defmodule ElixirHalfLife.Csqc.Fonts.Font do
  @moduledoc """
  A font at one height, loaded as FTE's `Font_LoadFont` loads it, and its characters as
  FTE's `Font_GetChar` finds them.

  A font name is `face[?params][:alternate]`. `face` is a comma-separated list of
  sources, each tried in turn: a KEX font (`fonts/<name>.kfont`), a horizontal strip
  picture (with `fmt=h`), a TrueType or OpenType file (`ElixirHalfLife.FontFile`, also
  tried with `.ttf` and `.otf` added), a picture of 16 by 16 characters, or a Half-Life
  font lump in `gfx.wad`. Params, `&`-separated: `col=r,g,b` (tint), `fmt=q|l|w|k|h`
  (character layout), `aspect=` (width of grid characters against their height). The
  alternate is another font name, used for the alternate character set, or `?col=r,g,b`
  to tint it. A font with no source becomes Half-Life's `conchars` lump; characters no
  source has come from FTE's built-in character set (`ElixirHalfLife.Csqc.Fonts.Charset`),
  which also gives U+E000–U+E0FF.

  A character is a map: `advance` (pixels the pen moves), `left` and `top` (where its
  picture goes from the pen), `bmw`/`bmh` (the picture's size), `plane` (`:glyph` drawn
  at its own size, or `:grid` drawn a whole character height square), the RGBA
  (premultiplied) `texture` it is cut from with `s0, t0, s1, t1` the part, and `white`
  (drawn untinted). Rendered glyphs are kept for the life of the system.

      font = ElixirHalfLife.Csqc.Fonts.Font.load("fonts/ibm/IBMPlexSansCondensed-Medium.otf", 20, %{})
      ElixirHalfLife.Csqc.Fonts.Font.char(font, ?A)
  """

  import Bitwise

  alias Cauldron3D.Formats.{Bmp, Tga, Wad3}
  alias Cauldron3D.Texture
  alias ElixirHalfLife.{Assets, FontFile, Pictures}
  alias ElixirHalfLife.Csqc.Fonts.Charset
  alias ElixirHalfLife.FontFile.Raster

  @type t :: map()
  @type char_info :: map()

  @iso88591 Enum.to_list(0x80..0x9F)
  @win1252 [
    0x20AC,
    0x81,
    0x201A,
    0x0192,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x02C6,
    0x2030,
    0x0160,
    0x2039,
    0x0152,
    0x8D,
    0x017D,
    0x8F,
    0x90,
    0x2018,
    0x2019,
    0x101C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x02DC,
    0x2122,
    0x0161,
    0x203A,
    0x0153,
    0x9D,
    0x017E,
    0x0178
  ]
  @koi8u [
    0x2500,
    0x2502,
    0x250C,
    0x2510,
    0x2514,
    0x2518,
    0x251C,
    0x2524,
    0x252C,
    0x2534,
    0x253C,
    0x2580,
    0x2584,
    0x2588,
    0x258C,
    0x2590,
    0x2591,
    0x2592,
    0x2593,
    0x2320,
    0x25A0,
    0x2219,
    0x221A,
    0x2248,
    0x2264,
    0x2265,
    0x00A0,
    0x2321,
    0x00B0,
    0x00B2,
    0x00B7,
    0x00F7,
    0x2550,
    0x2551,
    0x2552,
    0x0451,
    0x0454,
    0x2554,
    0x0456,
    0x0457,
    0x2557,
    0x2558,
    0x2559,
    0x255A,
    0x255B,
    0x0491,
    0x255D,
    0x255E,
    0x255F,
    0x2560,
    0x2561,
    0x0401,
    0x0404,
    0x2563,
    0x0406,
    0x0407,
    0x2566,
    0x2567,
    0x2568,
    0x2569,
    0x256A,
    0x0490,
    0x256C,
    0x00A9,
    0x044E,
    0x0430,
    0x0431,
    0x0446,
    0x0434,
    0x0435,
    0x0444,
    0x0433,
    0x0445,
    0x0438,
    0x0439,
    0x043A,
    0x043B,
    0x043C,
    0x043D,
    0x043E,
    0x043F,
    0x044F,
    0x0440,
    0x0441,
    0x0442,
    0x0443,
    0x0436,
    0x0432,
    0x044C,
    0x044B,
    0x0437,
    0x0448,
    0x044D,
    0x0449,
    0x0447,
    0x044A,
    0x042E,
    0x0410,
    0x0411,
    0x0426,
    0x0414,
    0x0415,
    0x0424,
    0x0413,
    0x0425,
    0x0418,
    0x0419,
    0x041A,
    0x041B,
    0x041C,
    0x041D,
    0x041E,
    0x041F,
    0x042F,
    0x0420,
    0x0421,
    0x0422,
    0x0423,
    0x0416,
    0x0412,
    0x042C,
    0x042B,
    0x0417,
    0x0428,
    0x042D,
    0x0429,
    0x0427,
    0x042A
  ]
  @koi_ascii "?3??4?67??????>?" <>
               "abwgdevzijklmnop" <>
               "rstufhc~{}/yx|`q" <>
               "ABWGDEVZIJKLMNOP" <> "RSTUFHC^[]_YX\\@Q" <> "?#??$?&'??????.?"
  @latin " ?c###|S?c?<??R?" <>
           "????'u?.,??>????" <>
           "AAAAAAECEEEEIIII" <>
           "DNOOOOO*OUUUUYYs" <>
           "aaaaaaeceeeeiiii" <>
           "onooooo/ouuuuyyy" <>
           "AaAaAaCcCcCcCcDd" <>
           "DdEeEeEeEeEeGgGg" <>
           "GgGgHhHhIiIiIiIi" <>
           "IiIiJjKkkLlLlLlL" <>
           "lllNnNnNnnNnOoOo" <>
           "OoEeRrRrRrSsSsSs" <> "SsTtTtTtUuUuUuUu" <> "UuUuWwYyYZzZzZzf"
  @hex {0o75557, 0o22222, 0o74717, 0o71317, 0o11755, 0o71747, 0o75744, 0o11117, 0o75757, 0o11757,
        0o55757, 0o65756, 0o75457, 0o65556, 0o74647, 0o44647}
  @white <<255, 255, 255, 255>>
  @red <<255, 0, 0, 255>>
  @clear <<0, 0, 0, 0>>

  @doc """
  The font `name` with rows `height` 2D units apart, made at `height` times `:pixels`
  pixels per unit (default 1.0) rounded to whole pixels, from 1 to 128; kept once made.
  The other `options`: `:scale` (default 1.0), `:outline` (pixels of dark border,
  default 0), `:linear` (glyphs sampled smoothly, given a clear border, default true).
  """
  @spec load(String.t(), number(), map()) :: t()
  def load(name, height, options) do
    scale = Map.get(options, :scale, 1.0)
    outline = Map.get(options, :outline, 0)
    linear = Map.get(options, :linear, true)
    height = height * Map.get(options, :pixels, 1.0)
    key = {__MODULE__, :font, name, height, scale, outline, linear}

    case :persistent_term.get(key, nil) do
      nil ->
        font = make(name, height, %{scale: scale, outline: outline, linear: linear})
        :persistent_term.put(key, font)
        font

      font ->
        font
    end
  end

  @doc "Character `codepoint` of `font`, as FTE's `Font_GetChar` finds it."
  @spec char(t(), non_neg_integer()) :: char_info() | nil
  def char(font, codepoint) do
    index = if codepoint > 0x110000, do: 0xFFFD, else: codepoint

    case loaded(font, index) do
      nil -> remember(font, index, fn -> find(font, index) end)
      char -> char
    end
  end

  defp make(name, vheight, options) do
    height = vheight |> Kernel.+(0.5) |> trunc() |> max(1) |> min(128)
    {face_part, alternate} = split_once(name, ":")
    {face_names, params} = split_once(face_part, "?")
    settings = params(params || "", %{tint: {1.0, 1.0, 1.0}, fmt: :auto, aspect: 1.0})

    font = %{
      name: name,
      key: {name, height, options},
      charheight: height,
      truecharheight: height,
      scale: options.scale,
      outline: options.outline,
      linear: options.linear,
      tint: settings.tint,
      alttint: {1.16, 0.54, 0.41},
      alt: nil,
      faces: [],
      single: nil,
      explicit: false,
      fixed: %{}
    }

    font
    |> alternate(alternate, vheight, options)
    |> sources(String.split(face_names, ","), settings.fmt)
    |> lump_fallback()
    |> grid(settings)
  end

  defp split_once(text, separator) do
    case String.split(text, separator, parts: 2) do
      [before, rest] -> {before, rest}
      [before] -> {before, nil}
    end
  end

  defp params("", settings), do: settings

  defp params(text, settings) do
    text
    |> String.split("&")
    |> Enum.reduce(settings, &param/2)
  end

  defp param("col=" <> value, settings), do: %{settings | tint: triple(value)}
  defp param("fmt=" <> value, settings), do: %{settings | fmt: fmt(value)}
  defp param("aspect=" <> value, settings), do: %{settings | aspect: leading_float(value)}
  defp param(_other, settings), do: settings

  defp fmt("q" <> _), do: :quake
  defp fmt("l" <> _), do: :iso88591
  defp fmt("w" <> _), do: :windows1252
  defp fmt("k" <> _), do: :koi8u
  defp fmt("h" <> _), do: :horizontal
  defp fmt(_other), do: :auto

  defp triple(text) do
    parts = text |> String.split(",") |> Enum.map(&leading_float(String.trim(&1)))
    [r, g, b] = Enum.take(parts ++ [0.0, 0.0, 0.0], 3)
    {r, g, b}
  end

  defp leading_float(text) do
    case Float.parse(text) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp alternate(font, nil, _vheight, _options), do: font

  defp alternate(font, "?col=" <> value, _vheight, _options), do: %{font | alttint: triple(value)}

  defp alternate(font, name, vheight, options) do
    alt = make(name, vheight, options)
    %{font | alt: %{alt | alttint: alt.tint}, alttint: alt.tint}
  end

  defp sources(font, names, fmt), do: Enum.reduce(names, font, &source(&2, &1, fmt))

  defp source(font, start, fmt) do
    case loaded_source(font, start, fmt) do
      {:ok, font} -> font
      :error -> image_or_lump(font, start)
    end
  end

  defp loaded_source(font, start, :auto) when start != "" do
    case kex(font, start) do
      {:ok, font} -> {:ok, %{font | explicit: true}}
      :error -> freetype(font, start)
    end
  end

  defp loaded_source(font, start, :horizontal), do: horizontal(font, start)
  defp loaded_source(font, start, :auto), do: freetype(font, start)
  defp loaded_source(_font, _start, _fmt), do: :error

  defp image_or_lump(%{single: single} = font, start) when single != nil or start == "",
    do: font

  defp image_or_lump(font, start) do
    if String.downcase(Path.extname(start)) in [".ttf", ".otf"] do
      font
    else
      case image(start) do
        nil -> lump(font, start)
        texture -> %{font | single: texture}
      end
    end
  end

  defp image(start) do
    [start, "fonts/" <> start, "charsets/" <> start]
    |> Enum.find_value(&Pictures.get/1)
    |> premultiply()
  end

  defp premultiply(nil), do: nil

  defp premultiply(%Texture{} = texture) do
    pixels =
      for <<r, g, b, a <- texture.pixels>>,
        into: <<>>,
        do: <<div(r * a, 255), div(g * a, 255), div(b * a, 255), a>>

    Texture.rgba(texture.width, texture.height, pixels)
  end

  defp lump(font, name) do
    case halflife_lump(name) do
      nil -> font
      face -> %{font | faces: font.faces ++ [{:halflife, face}]}
    end
  end

  defp lump_fallback(%{faces: [], single: nil, linear: true} = font), do: lump(font, "conchars")
  defp lump_fallback(font), do: font

  defp halflife_lump(name) do
    wanted = String.downcase(name)

    "gfx.wad"
    |> Assets.read()
    |> Wad3.lumps()
    |> Enum.find_value(fn
      {70, ^wanted, bytes} -> halflife_face(bytes)
      _ -> nil
    end)
  end

  defp halflife_face(
         <<height::little-32, image_height::little-32, _rows::little-32, _h2::little-32,
           table::binary-1024, rest::binary>>
       ) do
    data_size = 256 * image_height

    case rest do
      <<data::binary-size(^data_size), _count::binary-2, palette::binary-768, _::binary>> ->
        %{
          height: height,
          table: List.to_tuple(for(<<x, y, width, _pad <- table>>, do: {x, y, width})),
          data: data,
          palette: palette
        }

      _ ->
        nil
    end
  end

  defp halflife_face(_bytes), do: nil

  defp kex(font, start) do
    case Assets.read("fonts/#{start}.kfont") do
      nil -> :error
      text -> kex_lines(font, String.split(text, ["\r\n", "\n"]))
    end
  end

  defp kex_lines(font, lines) do
    font = Enum.reduce_while(lines, font, &kex_line/2)

    if font.single,
      do: {:ok, %{font | faces: font.faces ++ [{:kex, nil}]}},
      else: :error
  end

  defp kex_line(line, font) do
    case tokens(line) do
      ["texture", name | _] ->
        {:cont,
         if(font.single, do: font, else: %{font | single: premultiply(Pictures.get(name))})}

      [<<digit, _::binary>> = code, x, y, w, h, _u | _] when digit in ?0..?9 ->
        kex_char(font, Enum.map([code, x, y, w, h], &atoi/1))

      _ ->
        {:cont, font}
    end
  end

  defp kex_char(%{single: nil} = font, _values), do: {:halt, font}

  defp kex_char(font, [codepoint, _x, _y, _w, h]) when codepoint >= 0x110000 or h <= 0,
    do: {:cont, font}

  defp kex_char(font, [codepoint, x, y, w, h]) do
    {y, h} = if codepoint == ?\s, do: {y, h}, else: {y + 2, h - 4}
    texture = font.single
    bmw = div(w * 1024, texture.width)
    bmh = div(h * 1024, texture.height)
    bmx = div(x * 1024, texture.width)
    bmy = div(y * 1024, texture.height)

    char = %{
      advance: max(1, div(font.charheight * w, max(h, 1))),
      left: 0,
      top: 0,
      bmw: bmw,
      bmh: bmh,
      plane: :grid,
      texture: texture,
      s0: bmx / 1024,
      t0: bmy / 1024,
      s1: (bmx + bmw) / 1024,
      t1: (bmy + bmh) / 1024,
      white: false
    }

    {:cont, %{font | fixed: Map.put(font.fixed, codepoint, char)}}
  end

  defp tokens(line) do
    ~r/"([^"]*)"|(\S+)/
    |> Regex.scan(line)
    |> Enum.map(fn
      [_, quoted] -> quoted
      [_, "", plain] -> plain
    end)
  end

  defp atoi(text) do
    case Integer.parse(text) do
      {value, _} -> value
      :error -> 0
    end
  end

  defp horizontal(font, name) do
    with data when is_binary(data) <- Assets.read(name),
         {:ok, texture} <- decode_image(data) do
      face = %{pixels: texture.pixels, stride: texture.width, height: texture.height}
      {:ok, %{font | faces: font.faces ++ [{:horizontal, face}]}}
    else
      _ -> :error
    end
  end

  defp decode_image(data) do
    case Tga.parse(data) do
      {:ok, texture} -> {:ok, texture}
      _ -> Bmp.parse(data)
    end
  end

  defp freetype(_font, ""), do: :error

  defp freetype(font, start) do
    [start, start <> ".ttf", start <> ".otf"]
    |> Enum.find_value(&font_file/1)
    |> case do
      nil -> :error
      file -> {:ok, %{font | faces: font.faces ++ [{:freetype, file}]}}
    end
  end

  defp font_file(name) do
    key = {__MODULE__, :file, String.downcase(name)}

    case :persistent_term.get(key, :unread) do
      :unread ->
        file =
          with data when is_binary(data) <- Assets.read(name),
               {:ok, file} <- FontFile.parse(data),
               do: file,
               else: (_ -> nil)

        :persistent_term.put(key, file)
        file

      file ->
        file
    end
  end

  defp grid(font, settings) do
    plane = if not font.explicit and font.single, do: :bitmap, else: :default
    font = if font.single, do: font, else: %{font | single: charset()}
    fmt = if settings.fmt == :auto, do: :quake, else: settings.fmt
    font = if font.faces == [], do: grid_chars(font, fmt, settings.aspect, plane), else: font

    if fmt == :quake,
      do: quake_chars(font, settings.aspect, plane),
      else: font
  end

  defp grid_chars(font, fmt, aspect, plane) do
    c1 =
      case fmt do
        :windows1252 -> @win1252
        :koi8u -> @koi8u
        _ -> @iso88591
      end

    {first, last} = if fmt == :quake, do: {32, 127}, else: {0, 255}

    fixed =
      Enum.reduce(first..last, font.fixed, fn i, acc ->
        codepoint = if i >= 128 and i < 128 + length(c1), do: Enum.at(c1, i - 128), else: i
        Map.put(acc, codepoint, grid_char(font, i, aspect, plane))
      end)

    %{font | fixed: fixed}
  end

  defp quake_chars(font, aspect, plane) do
    fixed =
      Enum.reduce(0xE000..0xE0FF, font.fixed, fn i, acc ->
        Map.put(acc, i, grid_char(font, band(i, 0xFF), aspect, plane))
      end)

    %{font | fixed: fixed}
  end

  defp grid_char(font, i, aspect, plane) do
    column = band(i, 15)
    row = div(band(i, 0xF0), 16)
    texture = if plane == :bitmap, do: font.single, else: charset()

    %{
      advance: trunc(font.charheight * aspect),
      left: 0,
      top: 0,
      bmw: 64,
      bmh: 64,
      plane: :grid,
      texture: texture,
      s0: column / 16,
      t0: row / 16,
      s1: (column + 1) / 16,
      t1: (row + 1) / 16,
      white: false
    }
  end

  defp charset do
    key = {__MODULE__, :charset}

    case :persistent_term.get(key, nil) do
      nil ->
        texture = make_charset()
        :persistent_term.put(key, texture)
        texture

      texture ->
        texture
    end
  end

  defp make_charset do
    {:ok, texture} = Tga.parse(Charset.tga())

    pixels =
      for <<grey, _g, _b, _a <- texture.pixels>>, into: <<>>, do: <<grey, grey, grey, grey>>

    pixels =
      if texture.width == 256 and texture.height == 256,
        do:
          Enum.reduce(
            [{?[, 128}, {?-, 129}, {?], 130}, {?|, 131}, {?>, 13}],
            pixels,
            &copy_glyph/2
          ),
        else: pixels

    Texture.rgba(texture.width, texture.height, pixels)
  end

  defp copy_glyph({from, to}, pixels) do
    Enum.reduce(0..15, pixels, fn y, acc ->
      source = (band(from, 15) * 16 + (bsr(from, 4) * 16 + y) * 256) * 4
      target = (band(to, 15) * 16 + (bsr(to, 4) * 16 + y) * 256) * 4
      row = binary_part(acc, source, 64)
      <<head::binary-size(^target), _::binary-64, tail::binary>> = acc
      head <> row <> tail
    end)
  end

  defp loaded(font, index) do
    case Map.get(font.fixed, index) do
      nil -> :persistent_term.get({__MODULE__, :char, font.key, index}, nil)
      char -> char
    end
  end

  defp remember(font, index, make) do
    char = make.()
    :persistent_term.put({__MODULE__, :char, font.key, index}, char)
    char
  end

  defp find(font, index) when index >= 0xE200 and index < 0xE300, do: char(font, ??)

  defp find(font, 0xA0) do
    case loaded(font, ?\s) do
      nil -> fallbacks(font, 0xA0)
      char -> char
    end
  end

  defp find(font, index), do: fallbacks(font, index)

  defp fallbacks(font, index) do
    {char, index} = {try_load(font, index), index}
    {char, index} = remapped(char, font, index, 0x400..0x45F, @koi_ascii)
    {char, index} = remapped(char, font, index, 0xA0..0x17F, @latin)
    char = char || placeholder(font, index)
    char = char || loaded(font, 0xFFFD) || try_load(font, 0xFFFD)
    char || loaded(font, ??) || try_load(font, ??)
  end

  defp remapped(nil, font, index, first..last//_, table) when index >= first and index <= last do
    mapped = :binary.at(table, index - first)

    if mapped == ??,
      do: {nil, mapped},
      else: {loaded(font, mapped) || try_load(font, mapped), mapped}
  end

  defp remapped(char, _font, index, _range, _table), do: {char, index}

  defp try_load(font, index) when index in [?\t, ?\n] do
    %{
      advance: font.charheight,
      left: 0,
      top: 0,
      bmw: 0,
      bmh: 0,
      plane: :glyph,
      texture: nil,
      s0: 0.0,
      t0: 0.0,
      s1: 0.0,
      t1: 0.0,
      white: false
    }
  end

  defp try_load(font, index) do
    case Enum.find_value(font.faces, &face_glyph(&1, font, index)) do
      nil when index == ?\r -> loaded(font, bor(index, 0xE000))
      char -> char
    end
  end

  defp face_glyph({:freetype, file}, font, index) do
    glyph = FontFile.glyph_index(file, index)

    if index == 0xFFFE or glyph != 0 do
      scale = font.charheight / file.units_per_em
      bitmap = Raster.render(FontFile.outline(file, glyph), scale)
      advance = file |> FontFile.advance(glyph) |> Kernel.*(scale * 64) |> round()

      font
      |> glyph_data(:gray, bitmap.pixels, bitmap.width, bitmap.rows)
      |> Map.merge(%{
        advance: bsr(advance + 32, 6),
        left: bitmap.left,
        top: div(font.charheight * 3, 4) - bitmap.top
      })
    end
  end

  defp face_glyph({:halflife, face}, font, index) do
    glyph = if index > 0xE000, do: index - 0xE000, else: index
    if glyph < 0x100, do: halflife_glyph(face, font, glyph)
  end

  defp face_glyph({:horizontal, face}, font, index) do
    if index < 256, do: horizontal_glyph(face, font, index)
  end

  defp face_glyph({:kex, _}, _font, _index), do: nil

  defp halflife_glyph(face, font, glyph) do
    {x, y, width} = elem(face.table, glyph)
    height = face.height
    colours = for <<r, g, b <- face.palette>>, do: max(max(r, g), b)
    colours = List.to_tuple(colours)

    pixels =
      for row <- 0..(height - 1)//1, column <- 0..(width - 1)//1, into: <<>> do
        at = 256 * y + x + row * 256 + column

        case at < byte_size(face.data) and :binary.at(face.data, at) do
          false -> @clear
          255 -> @clear
          index -> <<elem(colours, index), elem(colours, index), elem(colours, index), 255>>
        end
      end

    {pixels, width, height} = fit_height(pixels, width, height, font.charheight)

    font
    |> glyph_data(:rgba, pixels, width, height)
    |> Map.merge(%{advance: width, left: 0, top: 0, white: false})
  end

  defp horizontal_glyph(face, font, glyph) do
    width = div(face.stride, 256)
    stride = face.stride
    height = face.height
    width = strip_columns(face.pixels, glyph * width, width, stride, height)

    pixels =
      for row <- 0..(height - 1)//1, column <- 0..(width - 1)//1, into: <<>> do
        binary_part(face.pixels, (row * stride + glyph * div(stride, 256) + column) * 4, 4)
      end

    {pixels, width, height} = fit_height(pixels, width, height, font.charheight)
    advance = if width == 0, do: div(height, 3), else: width

    font
    |> glyph_data(:rgba, pixels, width, height)
    |> Map.merge(%{advance: advance, left: 0, top: 0, white: false})
  end

  defp strip_columns(_pixels, _from, 0, _stride, _height), do: 0

  defp strip_columns(pixels, from, width, stride, height) do
    column = width - 1

    used =
      Enum.any?(0..(height - 1)//1, fn row ->
        <<r, g, b, _a>> = binary_part(pixels, (row * stride + from + column) * 4, 4)
        r != 0 or g != 0 or b != 0
      end)

    if used, do: width, else: strip_columns(pixels, from, column, stride, height)
  end

  defp fit_height(pixels, width, height, height), do: {pixels, width, height}

  defp fit_height(pixels, width, height, wanted) do
    new_width = div(width * wanted, max(height, 1))

    if new_width == 0 or wanted == 0,
      do: {<<>>, new_width, wanted},
      else: {resample(pixels, width, height, new_width, wanted), new_width, wanted}
  end

  defp resample(pixels, width, height, new_width, new_height) do
    step = div(width * 0x10000, new_width)

    for row <- 0..(new_height - 1), column <- 0..(new_width - 1), into: <<>> do
      source_row = div(row * height, new_height)
      source_column = bsr(column * step, 16)
      binary_part(pixels, (source_row * width + source_column) * 4, 4)
    end
  end

  defp placeholder(font, index) do
    {pixels, w, h, d} = placeholder_picture(font.charheight, index)

    font
    |> glyph_data(:rgba, pixels, w, h)
    |> Map.merge(%{advance: w + d, left: 0, top: div(font.charheight - h - 1, 2)})
  end

  defp placeholder_picture(height, index) when index in 0xE080..0xE083 do
    w = min(16, height)
    h = max(1, div(w, 8))

    rows =
      if index == 0xE083 do
        List.duplicate(:binary.copy(@white, w), h * 3)
      else
        middle = for _ <- 1..h, do: placeholder_middle(index, w, h)

        List.duplicate(:binary.copy(@white, w), h) ++
          middle ++ List.duplicate(:binary.copy(@white, w), h)
      end

    {IO.iodata_to_binary(rows), w, h * 3, 0}
  end

  defp placeholder_picture(height, index) when index in [0xE01D, 0xE01E, 0xE01F] do
    w = min(16, height)
    h = max(1, div(w, 8))
    {:binary.copy(@white, w * h), w, h, 0}
  end

  defp placeholder_picture(height, 0xE00B) do
    h = min(16, height)
    w = max(1, div(h, 8))
    {:binary.copy(@white, w * h), w, h, 1}
  end

  defp placeholder_picture(height, 0xE00D) do
    h = min(16, height)
    w = div(h + 1, 2)

    rows =
      for y <- 0..(h - 1) do
        reach = min(y, h - 1 - y)
        filled = min(w, reach + 1)
        :binary.copy(@white, filled) <> :binary.copy(@clear, w - filled)
      end

    {IO.iodata_to_binary(rows), w, h, 1}
  end

  defp placeholder_picture(height, index) do
    two_rows = height >= 11
    {n, w, h} = digits(two_rows, index)
    border = if h + 2 < height, do: 1, else: 0
    w = w + border * 2
    h = h + border * 2

    red =
      for i <- 0..(n - 1),
          point <- digit_points(i, n, w, border, two_rows, index),
          into: MapSet.new(),
          do: point

    pixels =
      for at <- 0..(w * h - 1),
          into: <<>>,
          do: if(MapSet.member?(red, at), do: @red, else: @white)

    {pixels, w, h, 1}
  end

  defp placeholder_middle(0xE080, w, h),
    do: :binary.copy(@white, h) <> :binary.copy(@clear, w - h)

  defp placeholder_middle(0xE082, w, h),
    do: :binary.copy(@clear, w - h) <> :binary.copy(@white, h)

  defp placeholder_middle(_index, w, _h), do: :binary.copy(@clear, w)

  defp digits(true, index) do
    n =
      cond do
        index > 0xFFFF -> 3
        index > 0xFF -> 2
        true -> 1
      end

    {n * 2, n * 4 - 1, 11}
  end

  defp digits(false, index) do
    n =
      cond do
        index > 0xFFFFF -> 6
        index > 0xFFFF -> 5
        index > 0xFFF -> 4
        index > 0xFF -> 3
        true -> 2
      end

    {n, n * 4 - 1, 5}
  end

  defp digit_points(i, n, w, border, two_rows, index) do
    shape = elem(@hex, band(bsr(index, i * 4), 0xF))
    origin = border + w * border
    half = div(n, 2)

    origin =
      cond do
        not two_rows -> origin + 4 * (n - i - 1)
        i >= half -> origin + 4 * (n - i - 1)
        true -> origin + 4 * (half - i - 1) + w * 6
      end

    shape_points(shape, origin, w, [])
  end

  defp shape_points(0, _at, _w, acc), do: acc

  defp shape_points(shape, at, w, acc) do
    acc = if band(shape, 4) != 0, do: [at | acc], else: acc
    acc = if band(shape, 2) != 0, do: [at + 1 | acc], else: acc
    acc = if band(shape, 1) != 0, do: [at + 2 | acc], else: acc
    shape_points(bsr(shape, 3), at + w, w, acc)
  end

  defp glyph_data(font, mode, data, bmw, bmh) do
    outline = if bmw == 0 or bmh == 0, do: 0, else: min(font.outline, 4)
    pad = outline + if(font.linear, do: 1, else: 0)
    width = bmw + pad * 2
    height = bmh + pad * 2
    blank = :binary.copy(@clear, width)
    side = :binary.copy(@clear, pad)

    rows =
      for y <- 0..(bmh - 1)//1 do
        [side, row_pixels(mode, data, y, bmw), side]
      end

    pixels = IO.iodata_to_binary([List.duplicate(blank, pad), rows, List.duplicate(blank, pad)])
    pixels = outlined(pixels, mode, data, bmw, bmh, outline, pad)
    texture = Texture.rgba(width, height, pixels)
    x0 = pad - outline
    y0 = pad - outline

    %{
      advance: 0,
      left: 0,
      top: 0,
      bmw: bmw + outline * 2,
      bmh: bmh + outline * 2,
      plane: :glyph,
      texture: texture,
      s0: x0 / width,
      t0: y0 / height,
      s1: (x0 + bmw + outline * 2) / width,
      t1: (y0 + bmh + outline * 2) / height,
      white: false
    }
  end

  defp row_pixels(:gray, data, y, bmw),
    do: for(<<v <- binary_part(data, y * bmw, bmw)>>, into: <<>>, do: <<v, v, v, v>>)

  defp row_pixels(:rgba, data, y, bmw), do: binary_part(data, y * bmw * 4, bmw * 4)

  defp outlined(pixels, _mode, _data, _bmw, _bmh, 0, _pad), do: pixels

  defp outlined(pixels, mode, data, bmw, bmh, outline, pad) do
    ring = %{
      width: bmw + pad * 2,
      pad: pad,
      bmw: bmw,
      bmh: bmh,
      outline: outline,
      source: fn x, y -> source_alpha(mode, data, bmw, x, y) end,
      filter: outline_filter(outline)
    }

    for y <- -outline..(bmh + outline - 1), x <- -outline..(bmw + outline - 1), reduce: pixels do
      acc -> outline_pixel(acc, x, y, ring)
    end
  end

  defp outline_filter(outline) do
    for y <- -outline..outline, x <- -outline..outline, into: %{} do
      {{x, y},
       (outline + 1 - :math.sqrt(x * x + y * y))
       |> Kernel.*(255)
       |> Kernel.+(0.5)
       |> trunc()
       |> max(0)
       |> min(255)}
    end
  end

  defp outline_pixel(pixels, x, y, ring) do
    at = ((y + ring.pad) * ring.width + x + ring.pad) * 4
    <<r, g, b, a>> = binary_part(pixels, at, 4)
    strongest = strongest_around(x, y, a, ring)
    <<head::binary-size(^at), _::binary-4, tail::binary>> = pixels
    head <> <<r, g, b, div(strongest, 255)>> <> tail
  end

  defp strongest_around(x, y, a, %{outline: outline} = ring) do
    for dy <- -outline..outline,
        dx <- -outline..outline,
        x + dx >= 0 and x + dx < ring.bmw and y + dy >= 0 and y + dy < ring.bmh,
        reduce: a * 255 do
      best -> max(best, Map.fetch!(ring.filter, {dx, dy}) * ring.source.(x + dx, y + dy))
    end
  end

  defp source_alpha(:gray, data, bmw, x, y), do: :binary.at(data, y * bmw + x)
  defp source_alpha(:rgba, data, bmw, x, y), do: :binary.at(data, (y * bmw + x) * 4 + 3)
end
