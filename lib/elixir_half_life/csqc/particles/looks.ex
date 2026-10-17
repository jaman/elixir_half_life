defmodule ElixirHalfLife.Csqc.Particles.Looks do
  @moduledoc """
  How a particle effect type is painted, as FTE chooses it: a shader named for its
  texture and blend mode when the game has one (a `.mat` material for the plain blend
  mode), otherwise a shader made for the blend mode with the texture loaded, and when
  the texture cannot be loaded one of FTE's own particle pictures (a soft ball for
  textures named `ball` or `glow` and textured sparks, a fading strip for beams, a fuzzy
  blob otherwise), the texture coordinates then the whole picture.

  `looks/1` gives `%{texture:, blend:, sort:, tinted?:, s1:, t1:, s2:, t2:, randsmax:}`;
  `shader/2` reads a shader's text for the same fields.
  """

  alias Cauldron3D.Texture
  alias ElixirHalfLife.{Assets, Pictures}

  @size 64

  @doc "The looks of effect type `ptype`, kept once made."
  @spec looks(map()) :: map()
  def looks(ptype) do
    key =
      {__MODULE__, ptype.config, ptype.name, ptype.texname, ptype.blendmode, ptype.premul,
       ptype.type}

    case :persistent_term.get(key, nil) do
      nil ->
        looks = make(ptype)
        :persistent_term.put(key, looks)
        looks

      looks ->
        looks
    end
  end

  @doc """
  The looks a shader text gives: its first stage's `map` or `clampmap` picture,
  `blendfunc`, whether `rgbgen vertex` applies the vertex colours (and no `program`
  replaces them), and its sort (`sort`, else decal with `polygonOffset`, else by
  blend). `fallback` is the picture when the text names `$diffuse`.
  """
  @spec shader(String.t(), Texture.t() | nil) :: map()
  def shader(text, fallback) do
    lines =
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    words = Enum.map(lines, &String.split/1)
    blend = blend_of(Enum.find_value(words, &blendfunc/1))
    picture = Enum.find_value(words, &map_name/1)

    texture =
      case picture do
        nil -> fallback
        "$diffuse" -> fallback
        name -> Pictures.get(name) || fallback
      end

    program? = Enum.any?(words, &match?(["program" | _], &1))
    vertex? = Enum.any?(words, &(&1 == ["rgbgen", "vertex"])) and not program?

    sort =
      case Enum.find_value(words, fn
             ["sort", value | _] -> value
             _ -> nil
           end) do
        nil -> default_sort(blend, Enum.any?(words, &match?(["polygonoffset" | _], &1)))
        value -> sort_number(value)
      end

    %{texture: texture, blend: blend, sort: sort, tinted?: vertex?}
  end

  defp make(ptype) do
    case material(ptype) do
      nil -> generated(ptype)
      looks -> looks
    end
  end

  defp material(%{texname: ""}), do: nil

  defp material(%{blendmode: :blend, texname: name} = ptype) do
    case Assets.read(name <> ".mat") do
      text when is_binary(text) ->
        found = shader(text, nil)

        if found.texture,
          do: Map.merge(coords(ptype), %{found | tinted?: false}),
          else: nil

      _ ->
        nil
    end
  end

  defp material(_ptype), do: nil

  defp generated(ptype) do
    {blend, sort} = blend_mode(ptype.blendmode)

    case loaded(ptype) do
      %Texture{} = texture ->
        Map.merge(coords(ptype), %{
          texture: premultiply(texture, ptype.premul),
          blend: blend,
          sort: sort,
          tinted?: true
        })

      nil ->
        %{
          texture: premultiply(builtin(ptype), ptype.premul),
          blend: blend,
          sort: sort,
          tinted?: true,
          s1: 0.0,
          t1: 0.0,
          s2: 1.0,
          t2: 1.0,
          randsmax: 1
        }
    end
  end

  defp coords(ptype),
    do: %{s1: ptype.s1, t1: ptype.t1, s2: ptype.s2, t2: ptype.t2, randsmax: ptype.randsmax}

  defp loaded(%{texname: ""}), do: nil
  defp loaded(%{texname: "classicparticle"}), do: classic()
  defp loaded(%{texname: name}), do: Pictures.get(name) || Pictures.get("particles/" <> name)

  defp builtin(%{type: :beam}), do: beam()
  defp builtin(%{type: :sparkfan}), do: triangle()

  defp builtin(%{texname: name, type: type}) do
    if String.contains?(name, "glow") or String.contains?(name, "ball") or type == :texturedspark,
      do: ball(),
      else: fuzzy()
  end

  defp blend_mode(:blend), do: {{:alpha, 1.0}, 8}
  defp blend_mode(:blendcolour), do: {{:alpha, 1.0}, 8}
  defp blend_mode(:adda), do: {{:add, 1.0}, 12}
  defp blend_mode(:addc), do: {{:add, 1.0}, 12}
  defp blend_mode(:premul), do: {{:premultiplied, 1.0}, 12}
  defp blend_mode(:invmoda), do: {{:darken, 1.0}, 8}
  defp blend_mode(:invmodc), do: {{:darken, 1.0}, 8}
  defp blend_mode(:subtract), do: {{:darken, 1.0}, 8}
  defp blend_mode(:rtsmoke), do: {{:alpha, 1.0}, 7}

  defp blendfunc(["blendfunc" | args]), do: args
  defp blendfunc(_words), do: nil

  defp map_name([kind, name | _]) when kind in ["map", "clampmap"], do: String.trim(name, "\"")
  defp map_name(_words), do: nil

  defp blend_of(nil), do: :none
  defp blend_of(["blend" | _]), do: {:alpha, 1.0}
  defp blend_of(["add" | _]), do: {:add, 1.0}
  defp blend_of(["gl_src_alpha", "gl_one_minus_src_alpha" | _]), do: {:alpha, 1.0}
  defp blend_of(["gl_src_alpha", "gl_one" | _]), do: {:add, 1.0}
  defp blend_of(["gl_one", "gl_one_minus_src_alpha" | _]), do: {:premultiplied, 1.0}
  defp blend_of(["gl_zero", "gl_one_minus_src_color" | _]), do: {:darken, 1.0}
  defp blend_of(["gl_one", "gl_one" | _]), do: {:add, 1.0}
  defp blend_of(_args), do: {:alpha, 1.0}

  defp default_sort(_blend, true), do: 6
  defp default_sort(:none, false), do: 5
  defp default_sort({:add, _}, false), do: 12
  defp default_sort(_blend, false), do: 11

  defp sort_number("portal"), do: 3
  defp sort_number("sky"), do: 4
  defp sort_number("opaque"), do: 5
  defp sort_number("decal"), do: 6
  defp sort_number("seethrough"), do: 7
  defp sort_number("unlitdecal"), do: 8
  defp sort_number("banner"), do: 9
  defp sort_number("underwater"), do: 10
  defp sort_number("blend"), do: 11
  defp sort_number("additive"), do: 12
  defp sort_number("nearest"), do: 13

  defp sort_number(value) do
    case Integer.parse(value) do
      {number, _} -> number
      :error -> 5
    end
  end

  defp premultiply(texture, 0), do: texture

  defp premultiply(%Texture{format: :rgba} = texture, _premul) do
    pixels =
      for <<r, g, b, a <- texture.pixels>>,
        into: <<>>,
        do: <<div(r * a, 255), div(g * a, 255), div(b * a, 255), a>>

    %{texture | pixels: pixels}
  end

  defp premultiply(texture, _premul), do: texture

  @doc "FTE's soft round particle picture, 64 pixels a side, white with alpha falling off from the centre."
  @spec ball() :: Texture.t()
  def ball do
    built(:ball, fn ->
      for y <- 0..(@size - 1), x <- 0..(@size - 1), into: <<>> do
        dy = (y - 0.5 * @size) / (@size * 0.5 - 1)
        dx = (x - 0.5 * @size) / (@size * 0.5 - 1)
        <<255, 255, 255, byte(256 * (1 - (dx * dx + dy * dy)))>>
      end
      |> then(&Texture.rgba(@size, @size, &1))
    end)
  end

  @doc "FTE's beam particle picture: white, alpha falling off across its rows."
  @spec beam() :: Texture.t()
  def beam do
    built(:beam, fn ->
      for y <- 0..(@size - 1), _x <- 0..(@size - 1), into: <<>> do
        dy = (y - 0.5 * @size) / (@size * 0.5 - 1)
        <<255, 255, 255, byte(256 * (1 - dy * dy))>>
      end
      |> then(&Texture.rgba(@size, @size, &1))
    end)
  end

  @doc "FTE's spark-fan particle picture."
  @spec triangle() :: Texture.t()
  def triangle do
    built(:triangle, fn ->
      for y <- 0..(@size - 1), x <- 0..(@size - 1), into: <<>> do
        dy = y / (@size * 0.5 - 1)
        dx = x / (@size * 0.5 - 1)
        d = byte(256 * (1 - (dx + dy)))
        <<d, d, d, div(d, 2)>>
      end
      |> then(&Texture.rgba(@size, @size, &1))
    end)
  end

  @doc "FTE's `classicparticle` picture: 32 pixels a side, a white disc in its top left 16."
  @spec classic() :: Texture.t()
  def classic do
    built(:classic, fn ->
      for(y <- 0..31, x <- 0..31, into: <<>>, do: classic_pixel(x, y))
      |> then(&Texture.rgba(32, 32, &1))
    end)
  end

  @doc "FTE's fuzzy particle picture, 16 pixels a side."
  @spec fuzzy() :: Texture.t()
  def fuzzy do
    built(:fuzzy, fn ->
      rows = [
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0],
        [0, 0, 0, 1, 1, 1, 1, 1, 3, 1, 1, 2, 1, 0, 0, 0],
        [0, 0, 0, 1, 1, 1, 1, 4, 4, 4, 5, 4, 2, 1, 1, 0],
        [0, 0, 1, 1, 6, 5, 5, 8, 6, 8, 3, 6, 3, 2, 1, 0],
        [0, 0, 1, 5, 6, 7, 5, 6, 8, 8, 8, 3, 3, 1, 0, 0],
        [0, 0, 0, 1, 6, 8, 9, 9, 9, 9, 4, 6, 3, 1, 0, 0],
        [0, 0, 2, 1, 7, 7, 9, 9, 9, 9, 5, 3, 1, 0, 0, 0],
        [0, 0, 2, 4, 6, 8, 9, 9, 9, 9, 8, 6, 1, 0, 0, 0],
        [0, 0, 2, 2, 3, 5, 6, 8, 9, 8, 8, 4, 4, 1, 0, 0],
        [0, 0, 1, 2, 4, 1, 8, 7, 8, 8, 6, 5, 4, 1, 0, 0],
        [0, 1, 1, 1, 7, 8, 1, 6, 7, 5, 4, 7, 1, 0, 0, 0],
        [0, 1, 2, 1, 1, 5, 1, 3, 4, 3, 1, 1, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      ]

      grid = rows |> Enum.map(&List.to_tuple/1) |> List.to_tuple()

      for y <- 0..15, x <- 0..15, into: <<>> do
        <<255, 255, 255, trunc(elem(elem(grid, x), y) * 255 / 9.0)>>
      end
      |> then(&Texture.rgba(16, 16, &1))
    end)
  end

  defp built(name, make) do
    key = {__MODULE__, :builtin, name}

    case :persistent_term.get(key, nil) do
      nil ->
        texture = make.()
        :persistent_term.put(key, texture)
        texture

      texture ->
        texture
    end
  end

  defp classic_pixel(x, y) do
    inside? = x < 16 and y < 16 and (x - 7.5) * (x - 7.5) + (y - 7.5) * (y - 7.5) <= 64
    <<255, 255, 255, alpha_byte(inside?)>>
  end

  defp alpha_byte(true), do: 255
  defp alpha_byte(false), do: 0

  defp byte(value), do: value |> max(0) |> min(255) |> trunc()
end
