defmodule ElixirHalfLife.Csqc.Lighting do
  @moduledoc """
  The client's light, as FTE works it out for FreeHL: light style values, the world's
  lightmaps, and a model's light.

  A style's value is 264 when it has no pattern, `256 * v` for a pattern `=v`, and
  otherwise `22 * (letter - ?a)` of the pattern's letter at `trunc(time * 10)` (wrapping);
  its colour is the one given with `lightstyle`, white when none was.

  The world's lightmaps keep, per sample and channel, the sum of each style's sample
  times `trunc(colour * value)` shifted down 7 bits, the three channels scaled together
  so that none is above 255; a texel is its texture's colour times the blended samples
  over 255, each cut down to steps of 1/32 (red and blue) or 1/64 (green).

  A model added with `addentity_lighting` is lit by the direction (along its own axes),
  ambient and diffuse parts given there. Otherwise a model is lit from the world's light
  at its origin 24 units up (a held weapon: at the
  view, its directional part at least 24 a channel), the light times `255 / 200` over
  255 being both its ambient and diffuse parts, with half-Lambert shading and the same
  steps as the world; `EF_FULLBRIGHT` lights it evenly at 1.0, draw flags 7 at
  `abslight / 255`, draw flags 1 to 5 by light style 25 to 29, draw flags 6 add
  `abslight` to the world's light, and an entity standing for a player (a colormap of
  1 to 255) not held or drawn in front keeps at least 104 a channel of both parts
  before the scaling.
  """

  import Bitwise

  alias Cauldron3D.Bsp.Light
  alias Cauldron3D.Texture
  alias Cauldron3D.Vec

  @grey for i <- 0..255, into: <<>>, do: <<i, i, i>>

  @doc "Every light style's `{value, {r, g, b}}` now, styles 0 to 255."
  @spec styles(map()) :: %{non_neg_integer() => {number(), {float(), float(), float()}}}
  def styles(s) do
    colours = Map.get(s.ext, :lightstyle_rgb, %{})
    step = trunc(max(s.time, 0.0) * 10)

    Map.new(0..255, fn style ->
      pattern = Map.get(s.lightstyles, style, "")
      {style, {value(pattern, step), colour(pattern, Map.get(colours, style))}}
    end)
  end

  @doc "The light map `Cauldron3D.Bsp.Surfaces` makes the world's surfaces with."
  @spec world(map()) :: map()
  def world(styles) do
    %{
      rgba: Texture.colours(@grey),
      styles: styles,
      unlit: 0,
      store: &store/1,
      shade: &shade/1
    }
  end

  @doc "The world's light map with every sample `abslight * 255`, as draw flags 7 light a brush entity."
  @spec absolute(map(), number()) :: map()
  def absolute(light, abslight), do: Map.put(light, :fixed, trunc(abslight) * 255)

  @doc """
  The light of model snapshot `thing` for `Cauldron3D.Formats.Studio.polygons/3`:
  `%{ambient:, diffuse:, direction:}`.
  """
  @spec model(map(), map(), map(), Vec.t()) :: map()
  def model(s, thing, styles, view_origin) do
    {ambient, diffuse, direction} = model_parts(s, thing, styles, view_origin)
    %{ambient: ambient, diffuse: diffuse, direction: direction}
  end

  defp model_parts(
         _s,
         %{lighting: {{dx, dy, dz}, ambient, diffuse}, axes: {f, l, u}},
         _styles,
         _origin
       ),
       do: {ambient, diffuse, f |> Vec.scale(dx) |> Vec.madd(l, dy) |> Vec.madd(u, dz)}

  defp model_parts(_s, %{drawflags: flags, abslight: abslight}, _styles, _origin)
       when band(flags, 7) == 7 do
    level = abslight / 255
    {{level, level, level}, {level, level, level}, {0.0, 1.0, 0.0}}
  end

  defp model_parts(_s, %{drawflags: flags}, styles, _origin) when band(flags, 7) in 1..5 do
    {value, {r, g, b}} = Map.get(styles, 24 + band(flags, 7))
    level = value / 255
    {{r * level, g * level, b * level}, {r * level, g * level, b * level}, {0.0, 1.0, 0.0}}
  end

  defp model_parts(_s, %{effects: effects}, _styles, _origin) when band(effects, 512) != 0,
    do: {{1.0, 1.0, 1.0}, {0.0, 0.0, 0.0}, {0.0, 1.0, 0.0}}

  defp model_parts(s, thing, styles, view_origin) do
    weapon? = band(thing.flags, 1) != 0
    at = if weapon?, do: view_origin, else: Vec.add(thing.origin, {0.0, 0.0, 24.0})
    {colour, direction} = Light.point(s.bsp, at, styles)
    shade = colour
    ambient = if weapon?, do: map3(colour, &max(&1, 24.0)), else: colour
    {shade, ambient} = add_light(thing, shade, ambient)

    {shade, ambient} =
      if player?(thing, weapon?),
        do: {map3(shade, &max(&1, 104.0)), map3(ambient, &max(&1, 104.0))},
        else: {shade, ambient}

    m = 1 / (200 / 255) / 255
    {map3(shade, &(&1 * m)), map3(ambient, &(&1 * m)), direction}
  end

  defp add_light(%{drawflags: flags, abslight: abslight}, shade, ambient)
       when band(flags, 7) == 6,
       do: {map3(shade, &(&1 + abslight)), map3(ambient, &(&1 + abslight))}

  defp add_light(_thing, shade, ambient), do: {shade, ambient}

  defp player?(%{colormap: colormap, flags: flags}, weapon?),
    do: colormap >= 1 and colormap <= 255 and not weapon? and band(flags, 4) == 0

  defp map3({r, g, b}, fun), do: {fun.(r), fun.(g), fun.(b)}

  defp value("", _step), do: 264
  defp value("=" <> number, _step), do: parse_float(number) * 256

  defp value(pattern, step) do
    (:binary.at(pattern, rem(step, byte_size(pattern))) - ?a) * 22
  end

  defp colour("", _given), do: {1.0, 1.0, 1.0}
  defp colour(_pattern, nil), do: {1.0, 1.0, 1.0}
  defp colour(_pattern, {r, g, b}), do: {r / 1, g / 1, b / 1}

  defp parse_float(text) do
    case Float.parse(String.trim(text)) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp store({r, g, b}) do
    {r, g, b} = {bsr(trunc(r), 7), bsr(trunc(g), 7), bsr(trunc(b), 7)}
    m = max(max(r, g), b)

    if m > 255,
      do: {trunc(r * 255.0 / m), trunc(g * 255.0 / m), trunc(b * 255.0 / m)},
      else: {r, g, b}
  end

  defp shade({r, g, b}),
    do: {steps(r / 255, 32), steps(g / 255, 64), steps(b / 255, 32)}

  defp steps(level, count), do: Float.floor(min(level, 1.5) * count) / count
end
