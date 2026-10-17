defmodule ElixirHalfLife.Gpu.Overlay do
  @moduledoc """
  The client program's 2D layer (`ElixirHalfLife.ClientProgram.gpu_picture/4`'s
  `overlay`, RGBA bytes whose display colours are already multiplied by their alpha) as
  the texture `{:overlay, texture, :premultiplied}` lays over the card's picture: the
  picture kept at one minus the alpha and the colour added, so a pixel with colour and no
  alpha adds light (an additive HUD).

  The bytes are uploaded as they are (sRGB), with the gamma ramp `tone`
  (`ElixirHalfLife.Gamma`) put on the colours of opaque pixels; the card puts the ramp's
  console variables on the picture under them (`ElixirHalfLife.Gpu`).

      texture = ElixirHalfLife.Gpu.Overlay.texture(frame, tone)
  """

  alias CauldronGPU.Texture

  @doc "The overlay texture for `frame`, a `Cauldron3D.Frame` of RGBA pixels."
  @spec texture(Cauldron3D.Frame.t(), ElixirHalfLife.Gamma.table()) :: Texture.t()
  def texture(%{width: width, height: height, pixels: pixels}, tone) do
    %Texture{
      width: width,
      height: height,
      pixels: toned(pixels, tone),
      format: :srgb,
      filter: :nearest,
      wrap: :clamp,
      mipmaps: false
    }
  end

  defp toned(pixels, :identity), do: pixels

  defp toned(pixels, table) do
    for <<r, g, b, a <- pixels>>, into: <<>> do
      if a == 255,
        do: <<:binary.at(table, r), :binary.at(table, g), :binary.at(table, b), 255>>,
        else: <<r, g, b, a>>
    end
  end
end
