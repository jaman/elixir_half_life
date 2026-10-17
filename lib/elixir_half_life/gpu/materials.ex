defmodule ElixirHalfLife.Gpu.Materials do
  @moduledoc """
  Materials kept by key from tick to tick: `put/4` gives the handle for a key, defining
  the material the first time and redefining it under the same handle when it changes;
  `sweep/2` releases the materials of keys not put since the last sweep.

      {handle, changes, materials} = ElixirHalfLife.Gpu.Materials.put(materials, target, {:studio, 3, 0}, material)
      materials = ElixirHalfLife.Gpu.Materials.sweep(materials, target)
  """

  alias CauldronGPU.{Handle, Material}

  @type t :: %{kept: %{term() => {Handle.t(), Material.t()}}, used: MapSet.t()}

  @doc "No materials."
  @spec new() :: t()
  def new, do: %{kept: %{}, used: MapSet.new()}

  @doc "The handle for `key` holding `material`, with the change redefining it when it was different."
  @spec put(t(), CauldronGPU.Target.t(), term(), Material.t()) ::
          {Handle.t(), [CauldronGPU.Stream.change()], t()}
  def put(%{kept: kept, used: used} = materials, target, key, %Material{} = material) do
    used = MapSet.put(used, key)

    case kept do
      %{^key => {handle, ^material}} ->
        {handle, [], %{materials | used: used}}

      %{^key => {handle, _old}} ->
        {handle, [{:material, handle.id, material}],
         %{kept: Map.put(kept, key, {handle, material}), used: used}}

      _ ->
        handle = CauldronGPU.Target.material(target, material)
        {handle, [], %{kept: Map.put(kept, key, {handle, material}), used: used}}
    end
  end

  @doc "Releases the materials whose keys were not put since the last sweep."
  @spec sweep(t(), CauldronGPU.Target.t()) :: t()
  def sweep(%{kept: kept, used: used}, target) do
    {stay, gone} = Map.split_with(kept, fn {key, _} -> MapSet.member?(used, key) end)
    Enum.each(gone, fn {_key, {handle, _}} -> CauldronGPU.Target.release(target, handle) end)
    %{kept: stay, used: MapSet.new()}
  end

  @doc "Releases every material."
  @spec release(t(), CauldronGPU.Target.t()) :: :ok
  def release(%{kept: kept}, target),
    do: Enum.each(kept, fn {_key, {handle, _}} -> CauldronGPU.Target.release(target, handle) end)
end
