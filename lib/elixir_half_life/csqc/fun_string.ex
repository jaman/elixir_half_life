defmodule ElixirHalfLife.Csqc.FunString do
  @moduledoc """
  Text with FTE's markup turned into characters with flags, as FTE's
  `COM_ParseFunString` and `Font_Decode` do.

  Each character comes out as `{flags, codepoint}`. `flags` carries a CGA colour in bits
  24 to 27 (`fg`) and 28 to 31 (`bg`), or with `rich/0` set a 4-bit red, green and blue in
  bits 28, 24 and 20; and the `hidden/0`, `blink/0`, `alt/0`, `half_alpha/0` and
  `nonclear_bg/0` bits.

  Markup: `^0`–`^9` Quake 3 colours (`^8` half-alpha white, `^9` grey); `^xRGB` a hex
  colour; `^&FB` a foreground and background colour (`-` for the default); `^b` blink;
  `^a`/`^m` the alternate character set; `^h` half alpha; `^d` the default colour; `^s`
  and `^r` save and restore (four deep); `^Uxxxx` and `^{x…}` a character by number;
  `^[text\\info^]` a link whose info is hidden; `` ^`u8:…`= `` UTF-8 text; `^^` a
  caret; with ezQuake markup, `&cRGB` and `&r`, and `` =`k8:…`= `` KOI8 text. A first
  byte of 1 or 2 starts in the alternate set. Bytes are read as UTF-8 until one is not
  valid, and from there on as Quake's character set: control characters as the private
  characters U+E000–U+E01F, high characters as the alternate set.

      ElixirHalfLife.Csqc.FunString.parse("^3Vote: ^7yes", ElixirHalfLife.Csqc.FunString.white(), [])
  """

  import Bitwise

  @nonclear_bg 0x00800000
  @half_alpha 0x00400000
  @link_special 0x00200000
  @hidden 0x00080000
  @blink 0x00040000
  @alt 0x00020000
  @rich 0x00010000
  @white 0x0F000000
  @fg_mask 0x0F000000
  @bg_mask 0xF0000000
  @rich_mask 0xFFF00000
  @char_mask 0x0000FFFF
  @long_char 0x00100000
  @flags_mask 0xFFFF0000

  @q3 {0 <<< 24, 12 <<< 24, 10 <<< 24, 14 <<< 24, 9 <<< 24, 11 <<< 24, 13 <<< 24, 15 <<< 24,
       15 <<< 24 ||| @half_alpha, 7 <<< 24}

  @koi {0x4E, 0x30, 0x31, 0x46, 0x34, 0x35, 0x44, 0x33, 0x45, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D,
        0x3E, 0x3F, 0x4F, 0x40, 0x41, 0x42, 0x43, 0x36, 0x32, 0x4C, 0x4B, 0x37, 0x48, 0x4D, 0x49,
        0x47, 0x4A, 0x2E, 0x10, 0x11, 0x26, 0x14, 0x15, 0x24, 0x13, 0x25, 0x18, 0x19, 0x1A, 0x1B,
        0x1C, 0x1D, 0x1E, 0x1F, 0x2F, 0x20, 0x21, 0x22, 0x23, 0x16, 0x12, 0x2C, 0x2B, 0x17, 0x28,
        0x2D, 0x29, 0x27, 0x2A}

  @koi_high %{
    (?# + 128) => 0x0451,
    (?3 + 128) => 0x0401,
    (?4 + 128) => 0x0404,
    (?$ + 128) => 0x0454,
    (?6 + 128) => 0x0406,
    (?& + 128) => 0x0456,
    (?7 + 128) => 0x0407,
    (?' + 128) => 0x0457,
    (?> + 128) => 0x040E,
    (?. + 128) => 0x045E,
    (?/ + 128) => 0x042A
  }

  @type char_flags :: non_neg_integer()
  @type option :: {:keep_markup, boolean()} | {:limit, pos_integer()} | {:utf8, 0..2}

  @doc "The flags of white text, FTE's `CON_WHITEMASK`."
  @spec white() :: char_flags()
  def white, do: @white

  @doc "The hidden flag."
  @spec hidden() :: char_flags()
  def hidden, do: @hidden

  @doc "The blink flag."
  @spec blink() :: char_flags()
  def blink, do: @blink

  @doc "The alternate character set flag."
  @spec alt() :: char_flags()
  def alt, do: @alt

  @doc "The rich (hex) colour flag."
  @spec rich() :: char_flags()
  def rich, do: @rich

  @doc "The half-alpha flag."
  @spec half_alpha() :: char_flags()
  def half_alpha, do: @half_alpha

  @doc "The background colour flag."
  @spec nonclear_bg() :: char_flags()
  def nonclear_bg, do: @nonclear_bg

  @doc """
  The characters of `text` with their flags, starting from `flags`. Options:
  `:keep_markup` leaves the markup in as characters (still parsed for colour);
  `:limit` is the size of FTE's buffer, of which one place is the terminator (default
  2048); `:utf8` is FTE's `com_parseutf8` (default 1: UTF-8 until a byte is not valid;
  2: UTF-8 throughout; 0: Quake's character set).
  """
  @spec parse(binary(), char_flags(), [option()]) :: [{char_flags(), non_neg_integer()}]
  def parse(text, flags, opts) do
    text |> conchars(flags, opts) |> decode()
  end

  @doc "UTF-8 characters of `text` as FTE's `utf8_decode` reads them: `{codepoint, error, rest}`."
  @spec utf8(binary()) :: {non_neg_integer(), 0..4, binary()}
  def utf8(<<b0, b1, rest::binary>>) when band(b0, 0xE0) == 0xC0 and band(b1, 0xC0) == 0x80 do
    code = bsl(band(b0, 0x1F), 6) ||| band(b1, 0x3F)
    checked(code, if(code == 0 or code >= 0x80, do: 0, else: 2), rest)
  end

  def utf8(<<b0, b1, b2, rest::binary>>)
      when band(b0, 0xF0) == 0xE0 and band(b1, 0xC0) == 0x80 and band(b2, 0xC0) == 0x80 do
    code = bsl(band(b0, 0x0F), 12) ||| bsl(band(b1, 0x3F), 6) ||| band(b2, 0x3F)
    checked(code, if(code >= 0x800, do: 0, else: 2), rest)
  end

  def utf8(<<b0, b1, b2, b3, rest::binary>>)
      when band(b0, 0xF8) == 0xF0 and band(b1, 0xC0) == 0x80 and band(b2, 0xC0) == 0x80 and
             band(b3, 0xC0) == 0x80 do
    code =
      bsl(band(b0, 0x07), 18) ||| bsl(band(b1, 0x3F), 12) ||| bsl(band(b2, 0x3F), 6) |||
        band(b3, 0x3F)

    checked(code, if(code >= 0x10000, do: 0, else: 2), rest)
  end

  def utf8(<<b0, b1, b2, b3, b4, rest::binary>>)
      when band(b0, 0xFC) == 0xF8 and band(b1, 0xC0) == 0x80 and band(b2, 0xC0) == 0x80 and
             band(b3, 0xC0) == 0x80 and band(b4, 0xC0) == 0x80 do
    code =
      bsl(band(b0, 0x03), 24) ||| bsl(band(b1, 0x3F), 18) ||| bsl(band(b2, 0x3F), 12) |||
        bsl(band(b3, 0x3F), 6) ||| band(b4, 0x3F)

    checked(code, if(code >= 0x200000, do: 0, else: 2), rest)
  end

  def utf8(<<b0, b1, b2, b3, b4, b5, rest::binary>>)
      when band(b0, 0xFE) == 0xFC and band(b1, 0xC0) == 0x80 and band(b2, 0xC0) == 0x80 and
             band(b3, 0xC0) == 0x80 and band(b4, 0xC0) == 0x80 do
    code =
      bsl(band(b0, 0x01), 30) ||| bsl(band(b1, 0x3F), 24) ||| bsl(band(b2, 0x3F), 18) |||
        bsl(band(b3, 0x3F), 12) ||| bsl(band(b4, 0x3F), 6) ||| band(b5, 0x3F)

    checked(code, if(code >= 0x4000000, do: 0, else: 2), rest)
  end

  def utf8(<<b0, rest::binary>>) when b0 in 0xC0..0xFD,
    do: {0xFFFD, 1, rest}

  def utf8(<<b0, rest::binary>>) when b0 >= 0x80, do: {0xE000 + b0, 1, rest}
  def utf8(<<b0, rest::binary>>), do: {b0, 0, rest}

  defp checked(code, 0, rest) when code >= 0xD800 and code < 0xDC00 do
    case utf8(rest) do
      {low, 4, after_low} ->
        {(bsl(band(code, 0x3FF), 10) ||| band(low, 0x3FF)) + 0x10000, 0, after_low}

      _ ->
        {code, 3, rest}
    end
  end

  defp checked(code, 0, rest) when code >= 0xDC00 and code < 0xE000, do: {code, 4, rest}

  defp checked(code, 0, rest) when code in [0xFFFE, 0xFFFF] or code > 0x10FFFF,
    do: {code, 2, rest}

  defp checked(code, error, rest), do: {code, error, rest}

  defp decode([]), do: []

  defp decode([high, low | rest]) when band(high, @long_char) != 0 and band(high, @rich) == 0,
    do: [
      {band(low, @flags_mask), bsl(band(high, @char_mask), 16) ||| band(low, @char_mask)}
      | decode(rest)
    ]

  defp decode([char | rest]),
    do: [{band(char, @flags_mask), band(char, @char_mask)} | decode(rest)]

  defp conchars(text, flags, opts) do
    {flags, text} = alternate_start(text, flags)

    state = %{
      ext: flags,
      default: flags,
      utf8: 1,
      keep: Keyword.get(opts, :keep_markup, false),
      link_keep: Keyword.get(opts, :keep_markup, false),
      link_start: nil,
      link_flags: @white,
      stack: [],
      out: [],
      left: Keyword.get(opts, :limit, 2048) - 1
    }

    state = run(text, %{state | utf8: Keyword.get(opts, :utf8, 1)})
    Enum.reverse(state.out)
  end

  defp alternate_start(<<first, rest::binary>>, flags) when first in [1, 2],
    do: {bxor(flags, @alt), rest}

  defp alternate_start(text, flags), do: {flags, text}

  defp run(<<>>, state), do: state
  defp run(_text, %{left: left} = state) when left <= 0, do: state

  defp run(<<byte, _::binary>> = text, %{utf8: utf8} = state) when byte >= 0x80 and utf8 > 0 do
    case utf8(text) do
      {_code, error, _rest} when error != 0 and band(utf8, 2) == 0 ->
        messed_up(text, %{state | utf8: band(utf8, bnot(1))})

      {code, _error, rest} ->
        code = if code > 0x10FFFF, do: 0xFFFD, else: code
        run(rest, emit_code(state, code))
    end
  end

  defp run(<<"^", _::binary>> = text, state), do: markup(text, state)

  defp run(<<"&c", r, g, b, rest::binary>>, state)
       when r in ~c"0123456789ABCDEFabcdef" and g in ~c"0123456789ABCDEFabcdef" and
              b in ~c"0123456789ABCDEFabcdef" do
    state = %{state | ext: rich_colour(state.ext, r, g, b)}
    if state.keep, do: messed_up(<<"&c", r, g, b, rest::binary>>, state), else: run(rest, state)
  end

  defp run(<<"&r", rest::binary>>, state) do
    state = %{state | ext: plain_white(state.ext)}
    if state.keep, do: messed_up(<<"&r", rest::binary>>, state), else: run(rest, state)
  end

  defp run(<<"=`k8:", rest::binary>>, %{keep: false} = state), do: koi8(rest, state)

  defp run(text, state), do: messed_up(text, state)

  defp markup(<<"^", digit, _::binary>> = text, state) when digit in ?0..?9 do
    ext = if band(state.ext, @rich) != 0, do: plain_white(state.ext), else: state.ext
    ext = elem(@q3, digit - ?0) ||| band(ext, bnot(@white ||| @half_alpha))
    two(text, %{state | ext: band(ext, 0xFFFFFFFF)})
  end

  defp markup(<<"^&", fg, bg, rest::binary>> = text, state) do
    if extended?(fg) and extended?(bg) do
      ext = if band(state.ext, @rich) != 0, do: plain_white(state.ext), else: state.ext
      ext = ext |> foreground(fg) |> background(bg)
      state = %{state | ext: ext}
      if state.keep, do: messed_up(text, state), else: run(rest, state)
    else
      messed_up(text, state)
    end
  end

  defp markup(<<"^[", rest::binary>>, %{link_start: nil} = state) do
    state = if state.keep, do: push(state, ?^ ||| @hidden), else: state
    link_flags = state.ext
    ext = 12 <<< 24

    ext =
      if band(link_flags, @rich) == 0,
        do: ext ||| band(link_flags, @nonclear_bg ||| @half_alpha ||| @bg_mask),
        else: ext

    state = %{state | link_flags: link_flags, ext: ext, link_start: length(state.out)}
    state = push(state, ?[ ||| 0)
    run(rest, %{state | link_keep: state.keep, keep: false})
  end

  defp markup(<<"^]", rest::binary>>, state) do
    state = if state.keep, do: push(state, ?^ ||| @hidden), else: state
    run(rest, close_link(state))
  end

  defp markup(<<"^`u8:", rest::binary>>, %{keep: false} = state), do: utf8_section(rest, state)

  defp markup(<<"^b", _::binary>> = text, state),
    do: two(text, %{state | ext: bxor(state.ext, @blink)})

  defp markup(<<"^d", _::binary>> = text, state) do
    ext = if state.link_start, do: 12 <<< 24, else: state.default
    two(text, %{state | ext: ext})
  end

  defp markup(<<"^", c, _::binary>> = text, state) when c in [?m, ?a],
    do: two(text, %{state | ext: bxor(state.ext, @alt)})

  defp markup(<<"^h", _::binary>> = text, state),
    do: two(text, %{state | ext: bxor(state.ext, @half_alpha)})

  defp markup(<<"^s", _::binary>> = text, state) do
    stack = if length(state.stack) < 4, do: [state.ext | state.stack], else: state.stack
    two(text, %{state | stack: stack})
  end

  defp markup(<<"^r", _::binary>> = text, %{stack: [ext | stack]} = state),
    do: two(text, %{state | ext: ext, stack: stack})

  defp markup(<<"^r", _::binary>> = text, state), do: two(text, state)

  defp markup(<<"^U", a, b, c, d, rest::binary>>, %{keep: false} = state) do
    code = bsl(dehex(a), 12) ||| bsl(dehex(b), 8) ||| bsl(dehex(c), 4) ||| dehex(d)
    run(rest, push(state, band(code, 0xFFFF) ||| state.ext))
  end

  defp markup(<<"^U", _::binary>> = text, state), do: two(text, state)

  defp markup(<<"^{", rest::binary>>, %{keep: false} = state) do
    {code, rest} = hex_run(rest, 0)

    rest =
      case rest do
        <<"}", after_brace::binary>> -> after_brace
        _ -> rest
      end

    code = if code > 0x10FFFF, do: 0xFFFD, else: code
    run(rest, emit_code(state, code))
  end

  defp markup(<<"^{", _::binary>> = text, state), do: two(text, state)

  defp markup(<<"^x", r, g, b, rest::binary>> = text, state) do
    if hex?(r) and hex?(g) and hex?(b) do
      state = %{state | ext: rich_colour(state.ext, r, g, b)}
      if state.keep, do: two(text, state), else: run(rest, state)
    else
      two(text, state)
    end
  end

  defp markup(<<"^^", rest::binary>>, state) do
    state = if state.keep, do: push(state, ?^ ||| state.ext), else: state
    messed_up(<<"^", rest::binary>>, state)
  end

  defp markup(text, state), do: messed_up(text, state)

  defp two(<<"^", c, rest::binary>>, state) do
    if state.keep, do: messed_up(<<"^", c, rest::binary>>, state), else: run(rest, state)
  end

  defp two(text, state), do: messed_up(text, state)

  defp close_link(%{link_start: nil} = state), do: push(state, ?] ||| @link_special)

  defp close_link(state) do
    state = push(state, ?] ||| @hidden ||| @link_special)
    count = length(state.out) - state.link_start
    {link, before} = Enum.split(state.out, count)
    [open | inner] = Enum.reverse(link)
    open = open ||| @hidden ||| @link_special
    {visible, info} = Enum.split_while(inner, fn char -> band(char, @char_mask) != ?\\ end)
    {visible, info} = keep_last_visible(visible, info)
    info = Enum.map(info, &(&1 ||| @hidden))
    out = Enum.reverse([open | visible] ++ info) ++ before
    %{state | out: out, ext: state.link_flags, link_start: nil, keep: state.link_keep}
  end

  defp keep_last_visible(visible, []) do
    {Enum.drop(visible, -1), Enum.take(visible, -1)}
  end

  defp keep_last_visible(visible, info), do: {visible, info}

  defp utf8_section(text, state) do
    {section, rest} = until_terminator(text, "")
    inner = conchars_section(section, state)
    state = %{state | out: Enum.reverse(inner) ++ state.out, left: state.left - length(inner)}

    case rest do
      <<"`=", after_end::binary>> -> run(after_end, state)
      _ -> if rest == "", do: state, else: utf8_section(rest, state)
    end
  end

  defp koi8(text, state) do
    {section, rest} = until_terminator(text, "")
    utf = for <<byte <- section>>, into: "", do: <<koi_to_unicode(byte)::utf8>>
    inner = conchars_section(utf, state)
    state = %{state | out: Enum.reverse(inner) ++ state.out, left: state.left - length(inner)}

    case rest do
      <<"`=", after_end::binary>> -> run(after_end, state)
      _ -> if rest == "", do: state, else: koi8(rest, state)
    end
  end

  defp conchars_section(text, state) do
    text
    |> conchars_with(state.ext, state.left + 1)
  end

  defp conchars_with(text, ext, limit) do
    initial = %{
      ext: ext,
      default: ext,
      utf8: 2,
      keep: false,
      link_keep: false,
      link_start: nil,
      link_flags: @white,
      stack: [],
      out: [],
      left: limit - 1
    }

    text |> run(initial) |> Map.fetch!(:out) |> Enum.reverse()
  end

  defp until_terminator(<<"`=", _::binary>> = rest, acc), do: {acc, rest}
  defp until_terminator(<<>>, acc), do: {acc, <<>>}
  defp until_terminator(<<byte, rest::binary>>, acc), do: until_terminator(rest, acc <> <<byte>>)

  defp koi_to_unicode(byte) when byte >= 192, do: elem(@koi, byte - 192) + 0x400
  defp koi_to_unicode(byte), do: Map.get(@koi_high, byte, byte)

  defp messed_up(<<byte, rest::binary>>, %{utf8: 0} = state) do
    char =
      cond do
        byte in [?\n, ?\r, ?\t, ?\v, ?\s] -> byte ||| state.ext
        byte >= 32 and byte < 127 -> byte ||| state.ext
        byte >= 0x80 + 32 -> band(byte, 127) ||| state.ext ||| @alt
        true -> byte ||| state.ext ||| 0xE000
      end

    run(rest, push(state, char))
  end

  defp messed_up(<<byte, rest::binary>>, state), do: run(rest, push(state, byte ||| state.ext))
  defp messed_up(<<>>, state), do: state

  defp emit_code(state, code) when code > 0xFFFF do
    state
    |> push(bsr(code, 16) ||| @long_char ||| band(state.ext, @hidden))
    |> push(band(code, 0xFFFF) ||| state.ext)
  end

  defp emit_code(state, code), do: push(state, code ||| state.ext)

  defp push(%{left: left} = state, _char) when left <= 0, do: state
  defp push(state, char), do: %{state | out: [char | state.out], left: state.left - 1}

  defp plain_white(ext), do: 15 <<< 24 ||| band(ext, bnot(@rich_mask ||| @rich))

  defp rich_colour(ext, r, g, b) do
    band(ext, bnot(@rich_mask)) ||| @rich ||| bsl(dehex(r), 28) ||| bsl(dehex(g), 24) |||
      bsl(dehex(b), 20)
  end

  defp foreground(ext, ?-), do: 15 <<< 24 ||| band(ext, bnot(@fg_mask))
  defp foreground(ext, c) when c >= ?A, do: bsl(c - ?A + 10, 24) ||| band(ext, bnot(@fg_mask))
  defp foreground(ext, c), do: bsl(c - ?0, 24) ||| band(ext, bnot(@fg_mask))

  defp background(ext, ?-), do: band(ext, bnot(@bg_mask) &&& bnot(@nonclear_bg))

  defp background(ext, c) when c >= ?A,
    do: bsl(c - ?A + 10, 28) ||| band(ext, bnot(@bg_mask)) ||| @nonclear_bg

  defp background(ext, c), do: bsl(c - ?0, 28) ||| band(ext, bnot(@bg_mask)) ||| @nonclear_bg

  defp extended?(c), do: c in ?0..?9 or c in ?A..?F or c == ?-
  defp hex?(c), do: c in ?0..?9 or c in ?A..?F or c in ?a..?f

  defp dehex(c) when c in ?0..?9, do: c - ?0
  defp dehex(c) when c in ?A..?F, do: c - ?A + 10
  defp dehex(c) when c in ?a..?f, do: c - ?a + 10
  defp dehex(c), do: c - ?a + 10

  defp hex_run(<<c, rest::binary>>, acc) do
    if hex?(c), do: hex_run(rest, bsl(acc, 4) ||| dehex(c)), else: {acc, <<c, rest::binary>>}
  end

  defp hex_run(<<>>, acc), do: {acc, <<>>}
end
