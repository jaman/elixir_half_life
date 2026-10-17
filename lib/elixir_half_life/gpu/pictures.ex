defmodule ElixirHalfLife.Gpu.Pictures do
  @moduledoc """
  `Cauldron3D.Texture` pictures uploaded for the graphics card once each, kept by the
  picture and the form asked for:

    * `:straight` — the picture's colours and alpha; an indexed picture's colour `clear`
      (when given) see-through
    * `:premultiplied` — a picture whose colours are already multiplied by its alpha,
      as linear half floats divided by its alpha (at least 1/1024)
    * `:inverted` — each colour `c` as `255 - c`, opaque: the factor a picture laid down
      as `1 - colour` (FTE's `blendfunc gl_zero gl_one_minus_src_color`) multiplies by

      {handle, pictures} = ElixirHalfLife.Gpu.Pictures.get(pictures, target, texture, :straight)
  """

  alias Cauldron3D.Texture
  alias CauldronGPU.Texture, as: GpuTexture

  @kept 1 / 1024

  @type form :: :straight | :premultiplied | :inverted
  @type t :: %{term() => CauldronGPU.Handle.t()}

  @doc "No pictures."
  @spec new() :: t()
  def new, do: %{}

  @doc "The handle of `texture` in `form`, uploading it through `target` the first time."
  @spec get(t(), CauldronGPU.Target.t(), Texture.t(), form(), byte() | nil) ::
          {CauldronGPU.Handle.t(), t()}
  def get(pictures, target, %Texture{} = texture, form, clear \\ nil) do
    key = {:erlang.phash2(texture), texture.width, texture.height, form, clear}

    case pictures do
      %{^key => handle} ->
        {handle, pictures}

      _ ->
        handle = CauldronGPU.Target.texture(target, upload(texture, form, clear))
        {handle, Map.put(pictures, key, handle)}
    end
  end

  @doc "Releases every picture."
  @spec release(t(), CauldronGPU.Target.t()) :: :ok
  def release(pictures, target),
    do: Enum.each(Map.values(pictures), &CauldronGPU.Target.release(target, &1))

  defp upload(texture, :straight, clear),
    do: gpu_texture(texture, rgba(texture, clear), :srgb)

  defp upload(texture, :inverted, clear) do
    pixels =
      for <<r, g, b, _a <- rgba(texture, clear)>>,
        into: <<>>,
        do: <<255 - r, 255 - g, 255 - b, 255>>

    gpu_texture(texture, pixels, :srgb)
  end

  defp upload(texture, :premultiplied, clear) do
    pixels =
      for <<r, g, b, a <- rgba(texture, clear)>>, into: <<>> do
        kept = max(a / 255, @kept)

        <<decode(r) / kept::little-float-16, decode(g) / kept::little-float-16,
          decode(b) / kept::little-float-16, kept::little-float-16>>
      end

    gpu_texture(texture, pixels, :rgba16f)
  end

  defp gpu_texture(texture, pixels, format) do
    %GpuTexture{
      width: texture.width,
      height: texture.height,
      pixels: pixels,
      format: format,
      filter: :nearest,
      mipmaps: false
    }
  end

  defp rgba(%Texture{format: :rgba, pixels: pixels}, _clear), do: pixels

  defp rgba(%Texture{} = texture, clear) do
    colours = texture.colours || Texture.colours(texture.palette || grey_palette())

    for <<index <- texture.pixels>>, into: <<>> do
      if index == clear, do: <<0, 0, 0, 0>>, else: Texture.colour(colours, index)
    end
  end

  defp decode(byte) do
    value = byte / 255
    if value <= 0.04045, do: value / 12.92, else: :math.pow((value + 0.055) / 1.055, 2.4)
  end

  defp grey_palette, do: for(level <- 0..255, into: <<>>, do: <<level, level, level>>)
end
