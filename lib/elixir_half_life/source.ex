defmodule ElixirHalfLife.Source do
  @moduledoc """
  FreeHL's program and Half-Life's maps, models and files for `QuakeServer`, from
  `ElixirHalfLife.Assets`. The use key chooses its target as Half-Life does
  (`ElixirHalfLife.PlayerUse`).
  """

  @behaviour QuakeServer.Source

  alias Cauldron3D.Formats.Files
  alias ElixirHalfLife.Assets

  @impl true
  def progs, do: Assets.progs()

  @impl true
  def map(name) do
    Assets.prefetch(name)
    Assets.map(name)
  end

  @impl true
  def model(name), do: Assets.model(name)

  @impl true
  def read(name), do: Assets.read(name)

  @impl true
  def list(prefix), do: Assets.list(prefix)

  @impl true
  def package(name), do: Files.package(Assets.get().files, name)

  @impl true
  def depth(name), do: Assets.depth(name)

  @impl true
  def replacements, do: ElixirHalfLife.PlayerUse.replacements()
end
