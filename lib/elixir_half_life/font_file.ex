defmodule ElixirHalfLife.FontFile do
  @moduledoc """
  A TrueType or OpenType font file (`.ttf`, `.otf`): its character map, its glyphs'
  advances and their outlines, in font units, as FreeType reads them for FTE's
  `Font_LoadFreeTypeFont`.

      {:ok, font} = ElixirHalfLife.FontFile.parse(File.read!("whitrabt.ttf"))
      glyph = ElixirHalfLife.FontFile.glyph_index(font, ?A)
      ElixirHalfLife.FontFile.advance(font, glyph)
      ElixirHalfLife.FontFile.outline(font, glyph)

  An outline is a list of contours, each a list of segments starting with
  `{:move, point}` and going on with `{:line, point}`, `{:quad, control, point}` or
  `{:cubic, control1, control2, point}`; a contour is closed back to its start. Points
  are `{x, y}` in font units, `y` upwards. Outlines come from the `glyf` table
  (`ElixirHalfLife.FontFile.Glyf`) or the `CFF ` table (`ElixirHalfLife.FontFile.Cff`).
  The character map is the font's Unicode one (platform 3 encoding 10, then platform 3
  encoding 1, then platform 0), in format 0, 4, 6 or 12.
  """

  import Bitwise

  alias ElixirHalfLife.FontFile.{Cff, Glyf}

  @enforce_keys [:units_per_em, :characters, :metrics, :outlines]
  defstruct [:units_per_em, :characters, :metrics, :outlines]

  @type point :: {float(), float()}
  @type segment ::
          {:move, point()}
          | {:line, point()}
          | {:quad, point(), point()}
          | {:cubic, point(), point(), point()}
  @type t :: %__MODULE__{
          units_per_em: pos_integer(),
          characters: %{non_neg_integer() => non_neg_integer()},
          metrics: tuple(),
          outlines: Cff.t() | Glyf.t()
        }

  @doc "Read a font file; `:error` when it is not a TrueType or OpenType font with outlines."
  @spec parse(binary()) :: {:ok, t()} | :error
  def parse(<<version::binary-4, count::16, _::binary-6, rest::binary>> = data)
      when version in [<<0, 1, 0, 0>>, "OTTO", "true"] and byte_size(rest) >= count * 16 do
    tables =
      for <<tag::binary-4, _sum::32, offset::32, length::32 <- binary_part(rest, 0, count * 16)>>,
          offset + length <= byte_size(data),
          into: %{},
          do: {tag, binary_part(data, offset, length)}

    with %{"head" => head, "hhea" => hhea, "hmtx" => hmtx, "cmap" => cmap} <- tables,
         <<_::binary-18, units_per_em::16, _::binary-30, loca_format::signed-16, _::binary>> <-
           head,
         <<_::binary-34, long_metrics::16>> <- binary_part(hhea, 0, 36),
         {:ok, outlines} <- outlines(tables, loca_format) do
      {:ok,
       %__MODULE__{
         units_per_em: units_per_em,
         characters: characters(cmap),
         metrics: metrics(hmtx, long_metrics),
         outlines: outlines
       }}
    else
      _ -> :error
    end
  end

  def parse(_data), do: :error

  @doc "The glyph for character `codepoint`, 0 (the missing glyph) when the font has none."
  @spec glyph_index(t(), non_neg_integer()) :: non_neg_integer()
  def glyph_index(%__MODULE__{characters: characters}, codepoint),
    do: Map.get(characters, codepoint, 0)

  @doc "How far glyph `glyph` moves the pen, in font units."
  @spec advance(t(), non_neg_integer()) :: integer()
  def advance(%__MODULE__{metrics: {}}, _glyph), do: 0

  def advance(%__MODULE__{metrics: metrics}, glyph),
    do: elem(metrics, min(glyph, tuple_size(metrics) - 1))

  @doc "Glyph `glyph`'s outline, in font units."
  @spec outline(t(), non_neg_integer()) :: [[segment()]]
  def outline(%__MODULE__{outlines: %Cff{} = cff}, glyph), do: Cff.outline(cff, glyph)
  def outline(%__MODULE__{outlines: %Glyf{} = glyf}, glyph), do: Glyf.outline(glyf, glyph)

  defp outlines(%{"CFF " => cff}, _loca_format), do: Cff.parse(cff)

  defp outlines(%{"glyf" => glyf, "loca" => loca}, loca_format),
    do: Glyf.parse(glyf, loca, loca_format)

  defp outlines(_tables, _loca_format), do: :error

  defp metrics(hmtx, long_metrics) do
    long = min(long_metrics, div(byte_size(hmtx), 4))

    for(<<advance::16, _bearing::signed-16 <- binary_part(hmtx, 0, long * 4)>>, do: advance)
    |> List.to_tuple()
  end

  defp characters(<<_version::16, count::16, rest::binary>> = cmap) do
    records =
      for <<platform::16, encoding::16, offset::32 <- binary_part(rest, 0, count * 8)>>,
        do: {platform, encoding, offset}

    [{3, 10}, {3, 1}, {0, nil}]
    |> Enum.find_value(fn want -> Enum.find(records, &unicode?(&1, want)) end)
    |> case do
      nil ->
        %{}

      {_platform, _encoding, offset} ->
        subtable(binary_part(cmap, offset, byte_size(cmap) - offset))
    end
  end

  defp characters(_cmap), do: %{}

  defp unicode?({platform, _encoding, _offset}, {platform, nil}), do: true
  defp unicode?({platform, encoding, _offset}, {platform, encoding}), do: true
  defp unicode?(_record, _want), do: false

  defp subtable(<<0::16, _length::16, _language::16, glyphs::binary-256, _::binary>>) do
    for {glyph, codepoint} <- Enum.with_index(:binary.bin_to_list(glyphs)),
        glyph != 0,
        into: %{},
        do: {codepoint, glyph}
  end

  defp subtable(
         <<4::16, _length::16, _language::16, doubled::16, _::binary-6, rest::binary>> = table
       ) do
    segments = div(doubled, 2)

    <<ends::binary-size(^doubled), _pad::16, starts::binary-size(^doubled),
      deltas::binary-size(^doubled), _::binary>> = rest

    range_at = 14 + doubled + 2 + doubled * 2

    for i <- 0..(segments - 1),
        <<last::16>> = binary_part(ends, i * 2, 2),
        <<first::16>> = binary_part(starts, i * 2, 2),
        <<delta::16>> = binary_part(deltas, i * 2, 2),
        <<range::16>> = binary_part(table, range_at + i * 2, 2),
        first <= last and first != 0xFFFF,
        codepoint <- first..last,
        glyph = format4_glyph(table, codepoint, first, delta, range, range_at + i * 2),
        glyph != 0,
        into: %{},
        do: {codepoint, glyph}
  end

  defp subtable(<<6::16, _length::16, _language::16, first::16, count::16, rest::binary>>) do
    for {<<glyph::16>>, i} <- Enum.with_index(chunks(binary_part(rest, 0, count * 2), 2)),
        glyph != 0,
        into: %{},
        do: {first + i, glyph}
  end

  defp subtable(<<12::16, _::16, _length::32, _language::32, count::32, rest::binary>>) do
    for <<first::32, last::32, start_glyph::32 <- binary_part(rest, 0, count * 12)>>,
        codepoint <- first..last,
        into: %{},
        do: {codepoint, start_glyph + codepoint - first}
  end

  defp subtable(_table), do: %{}

  defp format4_glyph(_table, codepoint, _first, delta, 0, _range_offset_at),
    do: band(codepoint + delta, 0xFFFF)

  defp format4_glyph(table, codepoint, first, delta, range, range_offset_at) do
    at = range_offset_at + range + (codepoint - first) * 2

    case table do
      <<_::binary-size(^at), 0::16, _::binary>> -> 0
      <<_::binary-size(^at), glyph::16, _::binary>> -> band(glyph + delta, 0xFFFF)
      _ -> 0
    end
  end

  defp chunks(binary, size), do: for(<<chunk::binary-size(^size) <- binary>>, do: chunk)
end
