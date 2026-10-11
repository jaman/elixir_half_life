defmodule ElixirHalfLife.Pictures do
  @moduledoc """
  Pictures by the names a client program asks for, as RGBA `Cauldron3D.Texture`s, found
  as FTE finds a 2D picture's shader and image, read once and kept:

    * `sprites/640hud1.spr_0.tga` — frame 0 of a sprite, by its format
    * a name without an extension, or ending `.mat`: the material `<name>.mat` (or the
      `.mat` named) when there is one, its picture the first stage's `map`,
      `clampmap` or `diffusemap` image; otherwise the image `name`
    * an image `name` (FTE's `Image_LocateHighResTexture`): a name ending in an image
      extension FTE searches for (`.tga`, `.png`, `.jpg`, `.pcx`, `.dds`, `.ktx`) or in
      none is tried with each of those and with none, as itself (when it holds a `/`),
      under `textures/` and under `override/`, then as `<name>.lmp`; any other name
      (`.bmp`, `.lmp`, …) only as itself. The first file found that reads as a TGA,
      BMP or LMP picture is it. Failing that (FTE's `W_GetTexture`), a name beginning
      `gfx/` or `wad/` is a picture in `gfx.wad`, colour 255 of a Half-Life picture
      see-through; any other is a wall texture of that name in the install's WAD3
      collections (a name beginning `{` see-through at colour 255)

  PNG, JPEG, PCX, DDS and KTX files are found but not read. `from_wad/1` is the picture
  FTE's `drawpic` falls back to when a name gives no picture with a size.

      ElixirHalfLife.Pictures.get("sprites/640hud7.spr_0.tga")
      ElixirHalfLife.Pictures.get("gfx/loading")
  """

  alias Cauldron3D.Formats.{Bmp, Spr, Tga, Wad2, Wad3}
  alias Cauldron3D.Texture
  alias ElixirHalfLife.Assets

  @searched [".tga", ".png", ".jpg", ".pcx", ".dds", ".ktx"]

  @doc "The picture `name`, or `nil` when there is none."
  @spec get(String.t()) :: Texture.t() | nil
  def get(name), do: cached({:get, String.downcase(name)}, &load/1)

  @doc """
  The picture FTE's `drawpic` draws for `name` when `get/1` has none
  (`R2D_SafePicFromWad`): the image `gfx/<name>`, or FTE's missing-texture picture, a
  16 by 16 check of palette colours 0 and 255.
  """
  @spec from_wad(String.t()) :: Texture.t()
  def from_wad(name) do
    cached({:from_wad, String.downcase(name)}, fn name -> image("gfx/" <> name) || missing() end)
  end

  @doc "An indexed picture as RGBA, colour 255 see-through where its palette entry is pure blue."
  @spec rgba(Texture.t(), binary() | nil) :: Texture.t()
  def rgba(%Texture{format: :rgba} = texture, _palette), do: texture

  def rgba(%Texture{} = texture, palette) do
    palette = texture.palette || palette || grey()
    colours = Texture.colours(palette)
    clear? = binary_part(palette, 765, 3) == <<0, 0, 255>>

    pixels =
      for <<index <- texture.pixels>>, into: <<>> do
        if clear? and index == 255, do: <<0, 0, 0, 0>>, else: Texture.colour(colours, index)
      end

    Texture.rgba(texture.width, texture.height, pixels)
  end

  defp cached(key, make) do
    case :persistent_term.get({__MODULE__, key}, :unread) do
      :unread ->
        picture = key |> elem(1) |> String.split("?") |> hd() |> make.()
        :persistent_term.put({__MODULE__, key}, picture)
        picture

      picture ->
        picture
    end
  end

  defp load(name) do
    case Regex.run(~r/^(.+\.spr)_(\d+)\.(tga|png)$/, name) do
      [_, sprite, frame, _] -> sprite_frame(sprite, String.to_integer(frame))
      nil -> shader(name, Path.extname(name))
    end
  end

  defp shader(name, ".spr"), do: sprite_frame(name, 0)

  defp shader(name, extension) when extension in ["", ".mat"] do
    file = if extension == "", do: name <> ".mat", else: name

    case Assets.read(file) do
      nil -> image(name)
      text -> material(text)
    end
  end

  defp shader(name, _extension), do: image(name)

  defp material(text) do
    text
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(String.trim(line)) do
        [key, path | _] when key in ["map", "clampmap", "diffusemap"] -> image(path)
        _ -> nil
      end
    end)
  end

  defp image(ident) do
    {stem, extensions} = searched(ident)

    ident
    |> candidates(stem, extensions)
    |> Enum.find(&Assets.read/1)
    |> read_file()
    |> case do
      nil -> wad_texture(Path.rootname(ident))
      texture -> texture
    end
  end

  defp searched(ident) do
    extension = String.downcase(Path.extname(ident))

    cond do
      extension in @searched -> {Path.rootname(ident), @searched ++ [""]}
      extension == "" -> {ident, @searched ++ [""]}
      true -> {ident, [""]}
    end
  end

  defp candidates(_ident, stem, extensions) do
    prefixes =
      if String.contains?(stem, "/"),
        do: ["", "textures/", "override/"],
        else: ["textures/", "override/"]

    lmp = if Path.extname(stem) == "", do: stem <> ".lmp", else: stem
    for(prefix <- prefixes, extension <- extensions, do: prefix <> stem <> extension) ++ [lmp]
  end

  defp read_file(nil), do: nil

  defp read_file(file) do
    data = Assets.read(file)

    if String.downcase(Path.extname(file)) == ".lmp",
      do: lmp(data),
      else: decode(data, &Tga.parse/1) || decode(data, &Bmp.parse/1)
  end

  defp decode(nil, _parse), do: nil

  defp decode(data, parse) do
    case parse.(data) do
      {:ok, texture} -> rgba(texture, nil)
      _ -> nil
    end
  end

  defp lmp(nil), do: nil

  defp lmp(data) do
    case Wad2.lmp(data) do
      nil -> nil
      texture -> rgba(texture, Assets.read("gfx/palette.lmp") |> palette())
    end
  end

  defp sprite_frame(name, frame) do
    with data when is_binary(data) <- Assets.read(name),
         {:ok, sprite} <- Spr.parse(data),
         %{texture: texture} <- Enum.at(Spr.pictures(sprite), frame) do
      Spr.rgba(sprite, texture, grey())
    else
      _ -> nil
    end
  end

  defp wad_texture("gfx/" <> name), do: wad_lump(name)
  defp wad_texture("wad/" <> name), do: wad_lump(name)
  defp wad_texture("textures/" <> name), do: wall(clean(name))
  defp wad_texture(name), do: wall(clean(name))

  defp wad_lump(name) do
    wanted = clean(name)

    "gfx.wad"
    |> Assets.read()
    |> Wad3.lumps()
    |> Enum.find_value(fn
      {0x42, ^wanted, lump} -> qpic(lump)
      _ -> nil
    end)
  end

  defp qpic(<<width::little-32, height::little-32, rest::binary>> = lump)
       when byte_size(lump) == 8 + width * height + 4 + 768 do
    <<pixels::binary-size(^width * ^height), _::binary-4, palette::binary-768>> = rest
    colours = Texture.colours(palette)

    rgba =
      for <<index <- pixels>>, into: <<>> do
        <<r, g, b, _a>> = Texture.colour(colours, index)
        <<r, g, b, if(index == 255, do: 0, else: 255)>>
      end

    Texture.rgba(width, height, rgba)
  end

  defp qpic(<<width::little-32, height::little-32, pixels::binary>> = lump)
       when byte_size(lump) == 8 + width * height do
    colours =
      "gfx/palette.lmp" |> Assets.read() |> palette() |> Kernel.||(grey()) |> Texture.colours()

    rgba =
      for <<index <- pixels>>, into: <<>> do
        <<r, g, b, _a>> = Texture.colour(colours, index)
        <<r, g, b, if(index == 255, do: 0, else: 255)>>
      end

    Texture.rgba(width, height, rgba)
  end

  defp qpic(_lump), do: nil

  defp clean(name) do
    name
    |> String.downcase()
    |> String.replace("*", "#")
    |> binary_part(0, min(byte_size(name), 16))
  end

  defp wall(name) do
    case Map.get(Assets.get().textures, name) do
      [mip | _] -> masked(mip, String.starts_with?(name, "{"))
      _ -> nil
    end
  end

  defp masked(texture, false), do: rgba(texture, nil)

  defp masked(texture, true) do
    colours = Texture.colours(texture.palette)

    pixels =
      for <<index <- texture.pixels>>,
        into: <<>>,
        do: if(index == 255, do: <<0, 0, 0, 0>>, else: Texture.colour(colours, index))

    Texture.rgba(texture.width, texture.height, pixels)
  end

  defp missing do
    colours =
      "gfx/palette.lmp" |> Assets.read() |> palette() |> Kernel.||(grey()) |> Texture.colours()

    <<r0, g0, b0, _>> = Texture.colour(colours, 0)
    <<r1, g1, b1, _>> = Texture.colour(colours, 255)

    pixels =
      for y <- 0..15, x <- 0..15, into: <<>> do
        if y < 8 != x < 8, do: <<r0, g0, b0, 255>>, else: <<r1, g1, b1, 255>>
      end

    Texture.rgba(16, 16, pixels)
  end

  defp palette(nil), do: nil
  defp palette(data) when byte_size(data) >= 768, do: binary_part(data, 0, 768)
  defp palette(_data), do: nil

  defp grey, do: for(i <- 0..255, into: <<>>, do: <<i, i, i>>)
end
