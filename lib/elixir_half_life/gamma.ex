defmodule ElixirHalfLife.Gamma do
  @moduledoc """
  FTE's gamma ramp (`BuildGammaTable`, `V_Gamma_Callback`), applied to a finished
  RGBA picture: each colour channel `i` becomes
  `255 * ((t ^ (1 / gamma)) * contrast + brightness)` rounded and held to 0–255, with
  `t = (i + 0.5) / 255.5`; alpha is left alone. `gamma` 1, `contrast` 1 and
  `brightness` 0 leave a picture as it is.

      table = ElixirHalfLife.Gamma.table(0.8, 1.0, 0.1)
      pixels = ElixirHalfLife.Gamma.adjust(table, pixels)
  """

  alias Cauldron3D.Frame.Pixels

  @type table :: :identity | binary()

  @doc "The ramp for console variables `gamma`, `contrast` and `brightness`, kept once built."
  @spec table(number(), number(), number()) :: table()
  def table(gamma, contrast, brightness)
      when gamma == 1 and contrast == 1 and brightness == 0,
      do: :identity

  def table(gamma, contrast, brightness) do
    key = {__MODULE__, gamma / 1, contrast / 1, brightness / 1}

    case :persistent_term.get(key, nil) do
      nil ->
        table = build(gamma, contrast, brightness)
        :persistent_term.put(key, table)
        table

      table ->
        table
    end
  end

  @doc "RGBA `pixels` put through `table`."
  @spec adjust(table(), binary()) :: binary()
  def adjust(:identity, pixels), do: pixels

  def adjust(table, pixels), do: Pixels.through(pixels, table)

  defp build(gamma, contrast, brightness) do
    exponent = if gamma > 0, do: 1 / gamma, else: 1.0e9

    0..255
    |> Enum.map(fn i ->
      t = (i + 0.5) / 255.5

      (255 * (:math.pow(t, exponent) * contrast + brightness) + 0.5)
      |> trunc()
      |> max(0)
      |> min(255)
    end)
    |> :binary.list_to_bin()
  end
end
