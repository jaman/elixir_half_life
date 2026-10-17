defmodule ElixirHalfLife.Gpu.Space do
  @moduledoc """
  Map places and turns in the renderer's frame: map point `{x, y, z}` (units, +Z up) is
  renderer point `{x, z, -y}` times `scale/0` metres, as `CauldronGPU.Bsp.point/2` puts it.

      ElixirHalfLife.Gpu.Space.transform({128.0, 0.0, 64.0}, {{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}}, 1.0)
  """

  alias CauldronGPU.{Camera, Quat, Transform}

  @type vec :: {number(), number(), number()}
  @type axes :: {vec(), vec(), vec()}

  @doc "Metres per map unit."
  @spec scale() :: float()
  def scale, do: 1 / 32

  @doc "Map point `point` in the renderer's frame."
  @spec point(vec()) :: {float(), float(), float()}
  def point({x, y, z}), do: {x * scale(), z * scale(), -y * scale()}

  @doc "Map direction `direction` in the renderer's frame, unscaled."
  @spec direction(vec()) :: {float(), float(), float()}
  def direction({x, y, z}), do: {x / 1, z / 1, -y / 1}

  @doc """
  The transform placing a model made in map units at map point `origin`, its own x, y
  and z along `axes` (`{forward, left, up}`, map directions of length one), `size` times
  its own size.
  """
  @spec transform(vec(), axes(), number()) :: Transform.t()
  def transform(origin, {forward, left, up}, size) do
    Transform.new(
      position: point(origin),
      rotation: rotation(direction(forward), direction(left), direction(up)),
      scale: size * scale()
    )
  end

  @doc """
  The camera at map point `origin` looking along map direction `forward`, `right` and
  `up` its other axes, `fov_y` degrees from top to bottom, its near plane `near` units on.
  """
  @spec camera(vec(), vec(), vec(), vec(), number(), number()) :: Camera.t()
  def camera(origin, forward, right, up, fov_y, near) do
    {fx, fy, fz} = direction(forward)

    %Camera{
      position: point(origin),
      rotation: rotation(direction(right), direction(up), {-fx, -fy, -fz}),
      fov_y: fov_y * :math.pi() / 180,
      near: near * scale(),
      far: 65_536 * scale(),
      snap: true
    }
  end

  @doc "The rotation taking +X, +Y and +Z to `x`, `y` and `z` (a right-handed set of unit vectors)."
  @spec rotation(vec(), vec(), vec()) :: Quat.t()
  def rotation({m00, m10, m20}, {m01, m11, m21}, {m02, m12, m22}) do
    trace = m00 + m11 + m22

    cond do
      trace > 0 ->
        s = :math.sqrt(trace + 1.0) * 2
        normalized({(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s})

      m00 > m11 and m00 > m22 ->
        s = :math.sqrt(max(1.0 + m00 - m11 - m22, 1.0e-12)) * 2
        normalized({0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s})

      m11 > m22 ->
        s = :math.sqrt(max(1.0 + m11 - m00 - m22, 1.0e-12)) * 2
        normalized({(m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s})

      true ->
        s = :math.sqrt(max(1.0 + m22 - m00 - m11, 1.0e-12)) * 2
        normalized({(m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s})
    end
  end

  defp normalized({x, y, z, w}) do
    size = :math.sqrt(x * x + y * y + z * z + w * w)
    {x / size, y / size, z / size, w / size}
  end
end
