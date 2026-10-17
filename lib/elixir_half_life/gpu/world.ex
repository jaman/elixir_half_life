defmodule ElixirHalfLife.Gpu.World do
  @moduledoc """
  A level's world (brush model 0) on the graphics card, drawn by `CauldronGPU.Bsp` from
  the map `ElixirHalfLife.Assets.map/1` reads: textures nearest-sampled, lightmaps as
  `ElixirHalfLife.Gpu.Light` gives them, and `{` textures opaque, colour 255 drawn as its
  palette colour, as the software picture draws the world's.

      world = ElixirHalfLife.Gpu.World.upload(target, "c1a0")
      {:instance, 1, ElixirHalfLife.Gpu.World.instance(world)}
      ElixirHalfLife.Gpu.World.release(target, world)
  """

  alias CauldronGPU.{Bsp, Instance}
  alias ElixirHalfLife.Assets
  alias ElixirHalfLife.Gpu.{Light, Space}

  @type t :: %{map: String.t(), bsp: Cauldron3D.Bsp.t(), gpu: Bsp.t()}

  @doc "Map `map`'s world uploaded through `target`, with the map as the card lights it (`:bsp`)."
  @spec upload(CauldronGPU.Target.t(), String.t()) :: t()
  def upload(target, map) do
    %{bsp: bsp} = Assets.map(map)
    bsp = Light.lightmaps(bsp)
    world = %{bsp | models: {elem(bsp.models, 0)}, textures: opaque(bsp.textures)}

    gpu =
      Bsp.upload(target, world, grey(), filter: :nearest, light_scale: 1.0, scale: Space.scale())

    %{map: map, bsp: bsp, gpu: gpu}
  end

  @doc "The world's instance, or `nil` when it has nothing to draw."
  @spec instance(t()) :: Instance.t() | nil
  def instance(%{gpu: gpu}) do
    case Bsp.model(gpu, 0) do
      nil ->
        nil

      {mesh, materials} ->
        %Instance{mesh: mesh, materials: materials, transform: Bsp.transform(gpu), snap: true}
    end
  end

  @doc "Releases the world's handles."
  @spec release(CauldronGPU.Target.t(), t()) :: :ok
  def release(target, %{gpu: gpu}) do
    handles =
      gpu.handles ++ Enum.flat_map(gpu.models, fn {mesh, materials} -> [mesh | materials] end)

    Enum.each(handles, &CauldronGPU.Target.release(target, &1))
  end

  defp opaque(textures) do
    textures
    |> Tuple.to_list()
    |> Enum.map(fn
      %{kind: :masked} = texture -> %{texture | kind: :solid}
      texture -> texture
    end)
    |> List.to_tuple()
  end

  defp grey, do: for(level <- 0..255, into: <<>>, do: <<level, level, level>>)
end
