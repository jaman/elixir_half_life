defmodule ElixirHalfLife.Csqc.Precaches do
  @moduledoc """
  The client's copies of the server's sound list and particle effect list (FTE's
  `cl.sound_name` and `cl.particle_ssname`), kept in the host's `ext.sound_list` and
  `ext.particle_list`, index to name. The server's sound numbers name sounds in its
  entities' updates (`soundnameforindex`), its effect numbers the effects of its
  particle messages.

      csqc = ElixirHalfLife.Csqc.Precaches.put_sounds(csqc, 1, ["a.wav", "b.wav"])
      ElixirHalfLife.Csqc.Precaches.sound(csqc, 2)
      #=> "b.wav"
  """

  import Bitwise

  @kind 0xC000
  @sound 0x8000
  @particle 0x4000

  @doc "Name sounds `first`, `first + 1`, … after `names`, in order."
  @spec put_sounds(map(), non_neg_integer(), [String.t()]) :: map()
  def put_sounds(s, first, names) do
    sounds =
      names
      |> Enum.with_index(first)
      |> Enum.reduce(list(s, :sound_list), fn {name, index}, acc -> Map.put(acc, index, name) end)

    %{s | ext: Map.put(s.ext, :sound_list, sounds)}
  end

  @doc """
  Take one precache (`svcfte_precache`): `code`'s top two bits say what it names (0x8000
  a sound, 0x4000 a particle effect), the rest its index, from 1. A model, or an index of
  0, is left alone.
  """
  @spec put(map(), non_neg_integer(), String.t()) :: map()
  def put(s, code, name) do
    index = band(code, bnot(@kind))

    case {band(code, @kind), index} do
      {_kind, 0} -> s
      {@sound, index} -> put_in_list(s, :sound_list, index, name)
      {@particle, index} -> put_in_list(s, :particle_list, index, name)
      _other -> s
    end
  end

  @doc "The server's sound `index`, `\"\"` for one it never named."
  @spec sound(map(), integer()) :: String.t()
  def sound(s, index), do: s |> list(:sound_list) |> Map.get(index, "")

  @doc "The server's particle effect `index`, `nil` for one it never named."
  @spec effect(map(), integer()) :: String.t() | nil
  def effect(s, index), do: s |> list(:particle_list) |> Map.get(index)

  defp put_in_list(s, key, index, name),
    do: %{s | ext: Map.put(s.ext, key, s |> list(key) |> Map.put(index, name))}

  defp list(s, key), do: Map.get(s.ext, key, %{})
end
