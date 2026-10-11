defmodule Mix.Tasks.HalfLife do
  @shortdoc "Play Half-Life (FreeHL) in this terminal"

  @moduledoc """
  Play Half-Life in the terminal: the Half-Life game files with FreeHL's game code.

      mix half_life --dir "/games/Half-Life" --freehl /games/freehl
      mix half_life --dir "/games/Half-Life" --freehl /games/freehl --map c1a0 --skill 2

  `--dir` is the Half-Life install (holding `valve`), defaulting to `HALF_LIFE_DIR`;
  `--freehl` the directory holding FreeHL's `package_valve.pk3` or its unpacked files,
  defaulting to `FREEHL_DIR`. `--map` defaults to `c0a0`, the start of the game; `--skill`
  is `1` (easy) to `3` (hard), default `1`. `--setpos "x y z [pitch yaw roll]"` puts
  the player there once the level starts (FTE's `setpos`, which leaves the player in
  noclip); `F6` in the game adds the current spot to `positions.txt` in the game's data
  directory as `map setpos x y z pitch yaw roll`, ready for `--map` and `--setpos`.
  `--picture` (or `CAULDRON_PICTURE`) is how the picture
  reaches a terminal that keeps images, as `Cauldron2D.Drafter.Client.Picture` reads it:
  any of `native`, `native:N`, `size:WxH`, `png` and `swap`, comma separated, or
  `none`; default `native:1,swap`. `--mute` plays no sound
  (`CAULDRON_MUTE=1` too).

      mix half_life --dir "/games/Half-Life" --freehl /games/freehl --map c1a0 --setpos "-1250 -718 40 0 90 0"
  """

  use Mix.Task
  alias Cauldron2D.Drafter.Client.Picture

  @switches [
    dir: :string,
    freehl: :string,
    picture: :string,
    mute: :boolean,
    map: :string,
    skill: :integer,
    name: :string,
    setpos: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start")
    dir = Keyword.get(opts, :dir) || System.get_env("HALF_LIFE_DIR")
    freehl = Keyword.get(opts, :freehl) || System.get_env("FREEHL_DIR")

    cond do
      dir == nil -> Mix.raise("give the Half-Life install: mix half_life --dir path/to/Half-Life")
      freehl == nil -> Mix.raise("give FreeHL's files: mix half_life --freehl path/to/freehl")
      true -> load(dir, freehl, opts)
    end
  end

  defp load(dir, freehl, opts) do
    case ElixirHalfLife.Assets.load(dir, freehl) do
      {:ok, _} ->
        play(opts)

      {:error, {:no_half_life, missing}} ->
        Mix.raise(
          "#{dir} is not a Half-Life install: it has no #{Enum.map_join(missing, ", ", &("valve/" <> &1))}"
        )

      {:error, reason} ->
        Mix.raise("could not read the game files: #{inspect(reason)}")
    end
  end

  defp play(opts) do
    Code.ensure_loaded!(Cauldron2D.Drafter.Surface)
    Drafter.Widget.Registry.register(Cauldron2D.Drafter.Surface)

    Drafter.run(Cauldron2D.Drafter.Client,
      refresh_rate: "30fps",
      props: %{
        game: ElixirHalfLife.Client,
        username: Keyword.get(opts, :name, "freeman"),
        map: Keyword.get(opts, :map),
        skill: Keyword.get(opts, :skill, 1),
        setpos: Keyword.get(opts, :setpos),
        picture: picture(opts[:picture]),
        mute: opts[:mute]
      }
    )
  end

  defp picture(nil), do: nil

  defp picture(options) do
    case Picture.parse(options) do
      {:ok, options} -> options
      {:error, message} -> Mix.raise("--picture: " <> message)
    end
  end
end
