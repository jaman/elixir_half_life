defmodule ElixirHalfLife.Csqc.Particles.DecalsTest do
  use ExUnit.Case, async: true

  alias ElixirHalfLife.Csqc.Particles.Decals

  test "a mark with no depth or no size has no triangles" do
    bsp = struct(Cauldron3D.Bsp)
    assert Decals.project(bsp, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {4.0, 0.0, 0.0}) == []
    assert Decals.project(bsp, {0.0, 0.0, 0.0}, {0.0, 0.0, 4.0}, {0.0, 0.0, 0.0}) == []
  end
end
