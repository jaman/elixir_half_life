defmodule ElixirHalfLife.Csqc.Messages do
  @moduledoc """
  The client program's message-reading builtins (`readbyte` to `readentitynum`, and
  `readint`), reading the message being handed to it, kept in the host's `ext.message`
  as `{bytes, at}`. Coordinates are 32-bit floats and angles 65536ths of a turn, as a
  server started with `coords: :float` writes them. Reading past the end gives zero, or
  the empty string.
  """

  alias QuakeServer.Args

  @doc "Run reading builtin `builtin`."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 360, _argc), do: read(s, 1, fn <<v>> -> v / 1 end)
  def call(s, 361, _argc), do: read(s, 1, fn <<v::signed>> -> v / 1 end)
  def call(s, 362, _argc), do: read(s, 2, fn <<v::little-signed-16>> -> v / 1 end)
  def call(s, 363, _argc), do: read(s, 4, fn <<v::little-signed-32>> -> v / 1 end)
  def call(s, 364, _argc), do: read(s, 4, fn <<v::little-float-32>> -> v end)
  def call(s, 365, _argc), do: read(s, 2, fn <<v::little-16>> -> v * 360 / 65_536 end)
  def call(s, 367, _argc), do: read(s, 4, fn <<v::little-float-32>> -> v end)
  def call(s, 368, _argc), do: read(s, 2, fn <<v::little-16>> -> v / 1 end)
  def call(s, "readint", _argc), do: read(s, 4, fn <<v::little-signed-32>> -> v end)

  def call(s, 366, _argc) do
    {bytes, at} = Map.get(s.ext, :message, {<<>>, 0})
    rest = binary_part(bytes, min(at, byte_size(bytes)), max(byte_size(bytes) - at, 0))

    case :binary.split(rest, <<0>>) do
      [text, _] -> s |> moved(bytes, at + byte_size(text) + 1) |> Args.return(text)
      [text] -> s |> moved(bytes, byte_size(bytes)) |> Args.return(text)
    end
  end

  @doc "The host with `bytes` as the message being read, from its start."
  @spec start(map(), binary()) :: map()
  def start(s, bytes), do: %{s | ext: Map.put(s.ext, :message, {bytes, 0})}

  defp read(s, size, decode) do
    {bytes, at} = Map.get(s.ext, :message, {<<>>, 0})

    if at + size <= byte_size(bytes),
      do: s |> moved(bytes, at + size) |> Args.return(decode.(binary_part(bytes, at, size))),
      else: s |> moved(bytes, byte_size(bytes)) |> Args.return(0.0)
  end

  defp moved(s, bytes, at), do: %{s | ext: Map.put(s.ext, :message, {bytes, at})}
end
