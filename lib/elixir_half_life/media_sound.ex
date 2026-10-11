defmodule ElixirHalfLife.MediaSound do
  @moduledoc """
  A sound under Half-Life's `media/` (the menu's own sounds, such as
  `launch_select2.wav`), as a `TuningFork.Voice`, read once and kept.

      voice = ElixirHalfLife.MediaSound.voice("launch_upmenu1.wav")
  """

  alias Cauldron3D.Formats.Wav
  alias ElixirHalfLife.Assets

  @doc "The sound `name` under `media/`, or `nil` when there is none."
  @spec voice(String.t()) :: TuningFork.Voice.t() | nil
  def voice(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, :unread) do
      :unread ->
        voice = name |> read() |> make()
        :persistent_term.put(key, voice)
        voice

      voice ->
        voice
    end
  end

  defp read(name) do
    case Assets.read("media/" <> name) do
      nil -> :error
      bytes -> Wav.read(bytes)
    end
  end

  defp make({:ok, %{rate: rate, pcm: pcm}}),
    do:
      TuningFork.Voice.new(
        sample: TuningFork.Sample.from_pcm(pcm, rate: rate, root: 440.0),
        freq: 440.0,
        gain: 1.0
      )

  defp make(_unread), do: nil
end
