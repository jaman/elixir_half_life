defmodule ElixirHalfLife.ClientSource do
  @moduledoc "FreeHL's client program and Half-Life's maps, models and files for the client's world, from `ElixirHalfLife.Assets`."

  @behaviour QuakeServer.Source

  alias Cauldron3D.Formats.Files
  alias ElixirHalfLife.Assets

  @impl true
  def progs, do: Assets.csprogs()

  @impl true
  def map(name), do: Assets.map(name)

  @impl true
  def model(name), do: Assets.model(name)

  @impl true
  def read(name), do: Assets.read(name)

  @impl true
  def list(prefix), do: Files.list(Assets.get().files, prefix)

  @impl true
  def package(name), do: Files.package(Assets.get().files, name)

  @impl true
  def depth(name), do: Assets.depth(name)
end
