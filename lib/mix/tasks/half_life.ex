defmodule Mix.Tasks.HalfLife do
  @shortdoc "Play Half-Life (FreeHL) in this terminal"

  @moduledoc """
  Play Half-Life in the terminal: the Half-Life game files with FreeHL's game code.

      mix half_life
      mix half_life --map c1a0 --skill 2

  The first run opens a setup page (`Cauldron2D.Drafter.Launcher`). There you pick the
  Half-Life install, the FreeHL folder, the skill and how the game is drawn. Play saves
  your choices, and later runs start straight away with them. The page also opens when a
  saved folder no longer checks out, or when you pass `--launcher`. When nothing is saved
  yet, the install is looked for in Steam's usual places first, including Steam in
  CrossOver on macOS.

  Flags change one run without changing what is saved:

    * `--dir` — the Half-Life install (holding `valve`); `HALF_LIFE_DIR` too
    * `--freehl` — the folder holding FreeHL's `package_valve.pk3` or its unpacked files;
      `FREEHL_DIR` too
    * `--map` — the map to start on; default `c0a0`, the start of the game
    * `--skill` — `1` (easy) to `3` (hard)
    * `--setpos "x y z [pitch yaw roll]"` — puts the player there once the level starts
      (FTE's `setpos`, which leaves the player in noclip). `F6` in the game adds the
      current spot to `positions.txt` in the game's data folder as
      `map setpos x y z pitch yaw roll`, ready for `--map` and `--setpos`.
    * `--software`, `--gpu`, `--window` — draw without the graphics card, with it in the
      terminal, or with it in a window of its own whose keys drive the game. Without
      these the saved drawing choice is used; its default draws on the graphics card
      when there is one.
    * `--picture` (or `CAULDRON_PICTURE`) — how pictures reach a terminal that keeps
      images, as `Cauldron2D.Drafter.Client.Picture` reads it; default `native:1,swap`
    * `--mute` — no sound (`CAULDRON_MUTE=1` too)
    * `--name` — the player name settings are kept under; default `freeman`

      mix half_life --map c1a0 --setpos "-1250 -718 40 0 90 0"
  """

  use Mix.Task
  alias Cauldron2D.Drafter.Client.Picture
  alias Cauldron2D.Drafter.Launcher
  alias ElixirHalfLife.Assets

  @switches [
    dir: :string,
    freehl: :string,
    picture: :string,
    gpu: :boolean,
    window: :boolean,
    software: :boolean,
    launcher: :boolean,
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
    name = Keyword.get(opts, :name, "freeman")

    overrides =
      %{
        dir: Keyword.get(opts, :dir) || System.get_env("HALF_LIFE_DIR"),
        freehl: Keyword.get(opts, :freehl) || System.get_env("FREEHL_DIR"),
        skill: opts[:skill]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Launcher.choose(ElixirHalfLife.Client, fields(),
           overrides: overrides,
           launcher: Keyword.get(opts, :launcher, false),
           player: name
         ) do
      {:ok, values} -> load(values, Keyword.put(opts, :name, name))
      :quit -> :ok
    end
  end

  defp fields do
    [
      %{
        key: :dir,
        label: "Half-Life folder",
        kind: {:path, &Assets.check_install/1},
        discover: &Assets.discover_install/0,
        hint: "the install holding valve"
      },
      %{
        key: :freehl,
        label: "FreeHL folder",
        kind: {:path, &Assets.check_freehl/1},
        hint: "the folder holding FreeHL's package_valve.pk3"
      },
      %{
        key: :skill,
        label: "Skill",
        kind: {:choice, [{1, "easy"}, {2, "medium"}, {3, "hard"}]},
        default: 1
      },
      Launcher.drawing_field()
    ]
  end

  defp load(%{dir: dir, freehl: freehl} = values, opts) do
    case Assets.load(dir, freehl) do
      {:ok, _} ->
        play(Keyword.put(opts, :skill, values.skill))

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
        picture: picture(opts[:picture], card(opts)),
        mute: opts[:mute]
      }
    )
  end

  defp card(opts) do
    for {switch, option} <- [gpu: :gpu, window: :window, software: :software],
        Keyword.get(opts, switch, false),
        do: option
  end

  defp picture(nil, []), do: nil
  defp picture(nil, card), do: ElixirHalfLife.Client.look().picture ++ card

  defp picture(options, card) do
    case Picture.parse(options) do
      {:ok, options} -> options ++ card
      {:error, message} -> Mix.raise("--picture: " <> message)
    end
  end
end
