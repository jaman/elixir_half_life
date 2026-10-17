defmodule ElixirHalfLife.Gpu.Lights do
  @moduledoc """
  The scene's dynamic lights (`ElixirHalfLife.Csqc.Described`'s `:lights`: the program's
  and the particles') as renderer lights, added to baked light in display colours by
  `CauldronGPU.Environment`'s rule, the software picture's: a point light of the light's
  colour reaching as far as its radius, or for a light with a field of view a spot light
  along its forward axis whose cone is half that field of view.

      ElixirHalfLife.Gpu.Lights.lights(description.lights)
  """

  alias CauldronGPU.Light
  alias ElixirHalfLife.Gpu.Space

  @doc "Renderer lights for `lights`."
  @spec lights([map()]) :: [Light.t()]
  def lights(lights), do: Enum.map(lights, &light/1)

  defp light(%{origin: origin, radius: radius, colour: colour} = light) do
    shaped(light, %Light{
      kind: :point,
      position: Space.point(origin),
      range: radius * Space.scale(),
      color: colour,
      intensity: 1.0
    })
  end

  defp shaped(%{fov: fov, axes: {forward, _right, _up}}, light) when fov > 0 do
    cone = fov * :math.pi() / 360

    %{
      light
      | kind: :spot,
        direction: Space.direction(forward),
        inner_cone: cone,
        outer_cone: cone
    }
  end

  defp shaped(_light, light), do: light
end
