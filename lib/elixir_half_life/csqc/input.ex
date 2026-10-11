defmodule ElixirHalfLife.Csqc.Input do
  @moduledoc """
  The client program's builtins about the player at the keyboard and the speakers: the
  cursor and the mouse, input frames kept for
  `getinputstate`, mouse sensitivity, player info keys, the listener's place, sound
  lengths and uploaded pictures (`r_uploadimage` as FTE takes it: name,
  width, height, data, size, and format 1 RGBA, 15 or 16 indexed with an RGB or RGBA
  palette after the pixels; another format, or a size that does not fit, uploads nothing
  and returns 0).

  State lives in the host's `ext`: `:cursor`, `:mouse`, `:input_frames` (the last 64
  sent input frames, each an input map with its `:sequence` and the monotonic
  microsecond it was `:sent`, at index `sequence &&& 63`), `:movesequence` (the number
  of the command being gathered), `:pending` (that command so far), `:view_angles`,
  `:sensitivity`, `:listener`, `:pictures`
  (uploaded RGBA textures by name).
  """

  alias Cauldron3D.Formats.Wav
  alias ElixirHalfLife.Csqc.Precaches
  alias QuakeServer.Args
  alias QuakeServer.Extensions.{Settings, Strings}

  @doc "Run input builtin `builtin`."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 343, _argc), do: %{s | ext: Map.put(s.ext, :cursor, Args.num(s, 0) != 0)}
  def call(s, "getcursormode", _argc), do: Args.return(s, Map.get(s.ext, :cursor, false))

  def call(s, 344, _argc) do
    {x, y} = Map.get(s.ext, :mouse, {0.0, 0.0})
    Args.return(s, {x / 1, y / 1, 0.0})
  end

  def call(s, "setmousepos", _argc) do
    {x, y, _} = Args.vec(s, 0)
    %{s | ext: Map.put(s.ext, :mouse, {x, y})}
  end

  def call(s, 345, _argc) do
    case input_frame(s.ext, Args.int(s, 0)) do
      nil -> Args.return(s, false)
      input -> s |> put_input(input) |> Args.return(true)
    end
  end

  def call(s, 346, _argc), do: %{s | ext: Map.put(s.ext, :sensitivity, Args.num(s, 0))}

  def call(s, 348, _argc),
    do: Args.return(s, Settings.info(s, Args.int(s, 0) + 1, Args.str(s, 1)))

  def call(s, "getplayerkeyfloat", argc) do
    case Settings.info(s, Args.int(s, 0) + 1, Args.str(s, 1)) do
      "" -> Args.return(s, Args.num(s, 2, argc, 0.0))
      text -> Args.return(s, Strings.number(text))
    end
  end

  def call(s, "getplayerkeyblob", _argc), do: Args.return(s, 0)

  def call(s, 351, _argc),
    do: %{
      s
      | ext:
          Map.put(s.ext, :listener, %{
            origin: Args.vec(s, 0),
            forward: Args.vec(s, 1),
            right: Args.vec(s, 2),
            up: Args.vec(s, 3)
          })
    }

  def call(s, "setup_reverb", _argc), do: s

  def call(s, 534, _argc) do
    seconds =
      with data when is_binary(data) <- ElixirHalfLife.Assets.read("sound/" <> Args.str(s, 0)),
           {:ok, %{rate: rate, pcm: pcm}} <- Wav.read(data) do
        byte_size(pcm) / 2 / rate
      else
        _ -> 0.0
      end

    Args.return(s, seconds)
  end

  def call(s, "soundnameforindex", _argc),
    do: Args.return(s, Precaches.sound(s, Args.int(s, 0)))

  def call(s, "r_uploadimage", argc) do
    {w, h} = {Args.int(s, 1), Args.int(s, 2)}
    size = if argc > 4, do: Args.int(s, 4), else: w * h * 4
    format = if argc > 5, do: Args.int(s, 5), else: 1

    with true <- w >= 0 and h >= 0 and w <= 16_384 and h <= 16_384,
         true <- Args.int(s, 3) > 0,
         {:ok, pixels} <- upload(format, w, h, memory_bytes(s.qc, Args.int(s, 3), size)) do
      name = Args.str(s, 0)
      texture = Cauldron3D.Texture.rgba(w, h, pixels)

      %{s | ext: Map.update(s.ext, :pictures, %{name => texture}, &Map.put(&1, name, texture))}
      |> Args.return(1)
    else
      _ -> Args.return(s, 0)
    end
  end

  def call(s, "r_readimage", _argc), do: Args.return(s, 0)

  @doc """
  The input frame `frame` as `getinputstate` gives it, or `nil` when it is no longer
  kept: frame `ext.movesequence` is the command still being gathered (`ext.pending`),
  at the view angles `ext.view_angles`, or, while it covers no time yet, the frame
  before it, covering the time since that one was sent; any other is the sent frame
  kept at index `frame &&& 63` of `ext.input_frames` when its `:sequence` is `frame`.
  """
  @spec input_frame(map(), integer()) :: map() | nil
  def input_frame(ext, frame) do
    if frame == Map.get(ext, :movesequence),
      do: pending_frame(ext, frame),
      else: sent_frame(ext, frame)
  end

  @doc "Keep sent input frame `input` (its `:sequence` its number) in `ext.input_frames`, at index `sequence &&& 63`."
  @spec keep_frame(map(), map()) :: map()
  def keep_frame(ext, %{sequence: sequence} = input),
    do:
      Map.update(
        ext,
        :input_frames,
        %{index(sequence) => input},
        &Map.put(&1, index(sequence), input)
      )

  @doc """
  The `input_` globals set from `input`, a map of `:angles`, `:movevalues`, `:buttons`,
  `:impulse`, `:timelength` and `:sequence` (FTE's `cs_set_input_state`).
  """
  @spec put_input(map(), map()) :: map()
  def put_input(s, input) do
    qc =
      s.qc
      |> QuakeC.put_declared("input_sequence", Map.get(input, :sequence, 0) / 1)
      |> QuakeC.put_declared("input_angles", Map.get(input, :angles, {0.0, 0.0, 0.0}))
      |> QuakeC.put_declared("input_movevalues", Map.get(input, :movevalues, {0.0, 0.0, 0.0}))
      |> QuakeC.put_declared("input_buttons", Map.get(input, :buttons, 0) / 1)
      |> QuakeC.put_declared("input_impulse", Map.get(input, :impulse, 0) / 1)
      |> QuakeC.put_declared("input_timelength", Map.get(input, :timelength, 0.0) / 1)

    %{s | qc: qc}
  end

  defp pending_frame(ext, frame) do
    previous = ext |> Map.get(:input_frames, %{}) |> Map.get(index(frame - 1))

    case gathering(Map.get(ext, :pending), previous, Map.get(ext, :view_angles)) do
      nil -> nil
      input -> input |> since_sent(previous) |> Map.put(:sequence, frame)
    end
  end

  defp gathering(nil, previous, _angles), do: previous

  defp gathering(%{timelength: seconds}, previous, _angles)
       when seconds <= 0 and previous != nil,
       do: previous

  defp gathering(pending, _previous, nil), do: pending
  defp gathering(pending, _previous, angles), do: %{pending | angles: angles}

  defp since_sent(input, %{sent: sent}),
    do: %{input | timelength: (System.monotonic_time(:microsecond) - sent) / 1_000_000}

  defp since_sent(input, _previous), do: input

  defp sent_frame(ext, frame) do
    case ext |> Map.get(:input_frames, %{}) |> Map.get(index(frame)) do
      %{sequence: ^frame} = input -> input
      _ -> nil
    end
  end

  defp index(sequence), do: Bitwise.band(sequence, 63)

  defp upload(1, w, h, bytes) when byte_size(bytes) == w * h * 4, do: {:ok, bytes}

  defp upload(15, w, h, bytes) when byte_size(bytes) == w * h + 768 do
    <<indices::binary-size(^w * ^h), palette::binary-size(768)>> = bytes
    {:ok, for(<<i <- indices>>, into: <<>>, do: binary_part(palette, i * 3, 3) <> <<255>>)}
  end

  defp upload(16, w, h, bytes) when byte_size(bytes) == w * h + 1024 do
    <<indices::binary-size(^w * ^h), palette::binary-size(1024)>> = bytes
    {:ok, for(<<i <- indices>>, into: <<>>, do: binary_part(palette, i * 4, 4))}
  end

  defp upload(_format, _w, _h, _bytes), do: :error

  defp memory_bytes(qc, address, size) do
    words = div(size + 3, 4)

    bytes =
      for i <- 0..(words - 1)//1,
          into: <<>>,
          do: word_bytes(QuakeC.load(qc, address + 4 * i))

    binary_part(bytes, 0, min(size, byte_size(bytes)))
  end

  defp word_bytes(value) when is_integer(value),
    do: <<Bitwise.band(value, 0xFFFFFFFF)::little-32>>

  defp word_bytes(value) when is_float(value), do: <<value::little-float-32>>
  defp word_bytes(_value), do: <<0::32>>
end
