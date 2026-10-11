defmodule ElixirHalfLife.EightBitSound do
  @moduledoc """
  A sound under `sound/` as a `TuningFork.Voice` cut to 8 bits a sample, as FTE stores
  sounds while `loadas8bit` is set (`QAF_S8`): each 16-bit sample keeps only its upper
  byte. Made once a sound and kept.

      voice = ElixirHalfLife.EightBitSound.voice("weapons/pl_gun3.wav")
  """

  alias ElixirHalfLife.Assets

  @doc "The sound `name`, cut to 8 bits, or `nil` when there is none."
  @spec voice(String.t()) :: TuningFork.Voice.t() | nil
  def voice(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, :unmade) do
      :unmade ->
        voice = make(Assets.sample(name))
        :persistent_term.put(key, voice)
        voice

      voice ->
        voice
    end
  end

  defp make(nil), do: nil

  defp make(%{rate: rate, pcm: pcm}) do
    TuningFork.Voice.new(
      sample: TuningFork.Sample.from_pcm(cut(pcm), rate: rate, root: 440.0),
      freq: 440.0,
      gain: 1.0
    )
  end

  defp cut(pcm),
    do:
      for(<<sample::little-signed-16 <- pcm>>,
        into: <<>>,
        do: <<Bitwise.band(sample, -256)::little-signed-16>>
      )
end
