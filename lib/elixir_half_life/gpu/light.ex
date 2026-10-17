defmodule ElixirHalfLife.Gpu.Light do
  @moduledoc """
  Half-Life's light as the graphics card takes it, lighting in display colours
  (`CauldronGPU.Environment`'s `light_space: :display`): a texture's display colour times
  a light level, as the software picture lights it.

  The world's lightmaps are given as the software picture lights a face with one light
  style at its normal value (264, `ElixirHalfLife.Csqc.Lighting`): each sample times 264
  shifted down 7 bits, the three channels scaled together so none is above 255, cut down
  to steps of 1/32 of 255 (red and blue) or 1/64 (green). A style's brightness on the
  card (`{:light_styles, ...}`) is its value over 264, or for a coloured style each
  channel `trunc(colour * value) / 264`.

  Colours a texture's linear colour is multiplied by (material colours, unlit levels) are
  given as `linear/1` of the display factor.

      bsp = ElixirHalfLife.Gpu.Light.lightmaps(bsp)
      {:light_styles, ElixirHalfLife.Gpu.Light.styles(description.styles)}
  """

  import Bitwise

  @exponent 2.2

  @doc "`bsp` with its lightmaps as the card reads them."
  @spec lightmaps(Cauldron3D.Bsp.t()) :: Cauldron3D.Bsp.t()
  def lightmaps(%{lightmaps: samples, light_channels: 3} = bsp),
    do: %{bsp | lightmaps: for(<<r, g, b <- samples>>, into: <<>>, do: sample(r, g, b))}

  def lightmaps(%{lightmaps: samples, light_channels: 1} = bsp),
    do: %{bsp | lightmaps: for(<<level <- samples>>, into: <<>>, do: grey(level))}

  @doc "The card's brightness of each style, from `{value, colour}` pairs in style order."
  @spec styles([{number(), {number(), number(), number()}}]) :: [
          float() | {float(), float(), float()}
        ]
  def styles(styles), do: Enum.map(styles, &style/1)

  defp style({value, {1.0, 1.0, 1.0}}), do: trunc(value) / 264

  defp style({value, {r, g, b}}),
    do: {trunc(r * value) / 264, trunc(g * value) / 264, trunc(b * value) / 264}

  @doc "A display factor, or `{r, g, b}` factors, as a factor of linear colour: raised to 2.2."
  @spec linear(number() | {number(), number(), number()}) :: float() | {float(), float(), float()}
  def linear({r, g, b}), do: {linear(r), linear(g), linear(b)}
  def linear(level) when level <= 0, do: 0.0
  def linear(level), do: :math.pow(level, @exponent)

  defp sample(r, g, b) do
    {r, g, b} = stored(bsr(r * 264, 7), bsr(g * 264, 7), bsr(b * 264, 7))
    <<stepped(r, 32), stepped(g, 64), stepped(b, 32)>>
  end

  defp grey(level) do
    {value, _, _} = stored(bsr(level * 264, 7), 0, 0)
    <<stepped(value, 32)>>
  end

  defp stored(r, g, b) do
    top = max(max(r, g), b)

    if top > 255,
      do: {trunc(r * 255.0 / top), trunc(g * 255.0 / top), trunc(b * 255.0 / top)},
      else: {r, g, b}
  end

  defp stepped(stored, count), do: round(Float.floor(stored / 255 * count) / count * 255)
end
