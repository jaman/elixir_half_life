defmodule ElixirHalfLife.Csqc.Shaders do
  @moduledoc """
  The shader texts the client program gives `shaderforname`, read for what a forced
  shader on a model needs: the picture its first stage maps, `deformVertexes bulge
  <width> <height> <speed>`, `tcMod scroll <s> <t>`, `tcGen environment`, `rgbGen
  entity` and `cull back`.

      ElixirHalfLife.Csqc.Shaders.read("{\\ncull back\\n{\\nmap x.tga\\ntcGen environment\\n}\\n}")
      #=> %{map: "x.tga", bulge: nil, scroll: {0.0, 0.0}, environment?: true, entity?: false, cull_back?: true}
  """

  @doc "The parts of shader text `text` named above."
  @spec read(String.t()) :: map()
  def read(text) do
    words =
      text
      |> String.split("\n")
      |> Enum.map(&(&1 |> String.trim() |> String.split()))

    Enum.reduce(words, empty(), &line/2)
  end

  defp empty,
    do: %{
      map: nil,
      bulge: nil,
      scroll: {0.0, 0.0},
      environment?: false,
      entity?: false,
      cull_back?: false
    }

  defp line([word | rest], acc), do: line(String.downcase(word), rest, acc)
  defp line([], acc), do: acc

  defp line("map", [name | _], %{map: nil} = acc), do: %{acc | map: name}

  defp line("deformvertexes", [kind, width, height, speed | _], acc) do
    if String.downcase(kind) == "bulge",
      do: %{acc | bulge: {number(width), number(height), number(speed)}},
      else: acc
  end

  defp line("tcmod", [kind, s, t | _], acc) do
    if String.downcase(kind) == "scroll", do: %{acc | scroll: {number(s), number(t)}}, else: acc
  end

  defp line("tcgen", [kind | _], acc),
    do: %{acc | environment?: String.downcase(kind) == "environment"}

  defp line("rgbgen", [kind | _], acc), do: %{acc | entity?: String.downcase(kind) == "entity"}

  defp line("cull", [kind | _], acc),
    do: %{acc | cull_back?: String.downcase(kind) in ["back", "backside", "backsided"]}

  defp line(_word, _rest, acc), do: acc

  defp number(text) do
    case Float.parse(text) do
      {value, _} -> value
      :error -> 0.0
    end
  end
end
