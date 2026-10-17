defmodule ElixirHalfLife.Csqc.Particles.LooksTest do
  use ExUnit.Case, async: true

  alias ElixirHalfLife.Csqc.Particles.Looks

  test "the classic particle picture is one 32 by 32 RGBA picture" do
    texture = Looks.classic()
    assert {texture.width, texture.height, byte_size(texture.pixels)} == {32, 32, 4096}
  end
end
