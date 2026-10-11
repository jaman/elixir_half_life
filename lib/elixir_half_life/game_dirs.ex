defmodule ElixirHalfLife.GameDirs do
  @moduledoc """
  The games and mods FTE lists for the Half-Life installation (`Mods_GetMod`), in its
  order: FTE's built-in Half-Life game (`-halflife`: game directory `valve`, named
  `Rad-Therapy`, running `plug_load ffmpeg` first), then each directory of the base
  directory holding the install's `valve` that FTE would take for a mod, sorted by name.

      ElixirHalfLife.GameDirs.list()
      #=> [%{gamedir: "valve", description: "Rad-Therapy", manifest: %{...}}]

  A directory is taken when its name is a usable game directory (no leading dot, no
  `..`, `:`, `/`, `\\`, `$` or `"`, not starting `downloads`, `docs`, `help`, `bin` or
  `lib`), it is not already a game's directory, and it has a `modinfo.txt` or
  `description.txt` (its text the description), a `liblist.gam` (its `game` key the
  description), a `.pk3`, `.pak` or `.dat` file, or a map under `maps/`. The game files
  must have been loaded (`ElixirHalfLife.Assets.load/2`).
  """

  alias ElixirHalfLife.Assets
  alias QuakeServer.Extensions.Strings

  @game %{
    gamedir: "valve",
    description: "Rad-Therapy",
    manifest: %{
      basegames: ["valve"],
      mods: [],
      defaultexec: "plug_load ffmpeg\n",
      protocolname: "Rad-Therapy"
    }
  }

  @refused ~w(downloads docs help bin lib)
  @taken Enum.map(@game.manifest.basegames, &String.downcase/1)

  @type mod :: %{gamedir: String.t(), description: String.t() | nil, manifest: map() | nil}

  @doc "The listed games and mods, the built-in game first."
  @spec list() :: [mod()]
  def list do
    base = base_dir()

    found =
      case base && File.ls(base) do
        {:ok, names} ->
          names
          |> Enum.filter(&(File.dir?(Path.join(base, &1)) and usable?(&1)))
          |> Enum.reject(&(String.downcase(&1) in @taken))
          |> Enum.flat_map(&mod(base, &1))
          |> Enum.sort_by(& &1.gamedir)

        _ ->
          []
      end

    [@game | found]
  end

  @doc "The game running now, as FTE gives it for index -1."
  @spec current() :: mod()
  def current, do: @game

  @doc "The base directory holding the install's `valve` directory, or `nil` when there is none."
  @spec base_dir() :: Path.t() | nil
  def base_dir do
    half_life = Assets.get().half_life

    cond do
      File.dir?(Path.join(half_life, "valve")) -> half_life
      Path.basename(half_life) == "valve" -> Path.dirname(half_life)
      true -> nil
    end
  end

  defp usable?(name) do
    lower = String.downcase(name)

    name != "" and not String.starts_with?(name, ".") and
      not String.contains?(name, ["..", ":", "/", "\\", "$", "\"", "\n", "\r", ";"]) and
      not Enum.any?(@refused, &String.starts_with?(lower, &1))
  end

  defp mod(base, name) do
    dir = Path.join(base, name)

    cond do
      text = read(dir, "modinfo.txt") ->
        [%{gamedir: name, description: text, manifest: nil}]

      text = read(dir, "description.txt") ->
        [%{gamedir: name, description: text, manifest: nil}]

      text = read(dir, "liblist.gam") ->
        [%{gamedir: name, description: liblist_game(text), manifest: nil}]

      interesting?(dir) ->
        [%{gamedir: name, description: nil, manifest: nil}]

      true ->
        []
    end
  end

  defp read(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, text} -> text
      _ -> nil
    end
  end

  defp liblist_game(text) do
    text
    |> Strings.tokenize_console()
    |> Enum.map(&elem(&1, 0))
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn
      [key, value] -> if String.downcase(key) == "game", do: value
      _ -> nil
    end)
  end

  defp interesting?(dir) do
    packaged? =
      dir
      |> list_files()
      |> Enum.any?(&(String.downcase(Path.extname(&1)) in [".pk3", ".pak", ".dat"]))

    packaged? or
      dir
      |> Path.join("maps")
      |> list_files()
      |> Enum.any?(&map?/1)
  end

  defp map?(name) do
    lower = String.downcase(name)
    String.ends_with?(lower, [".bsp", ".hmp", ".bsp.gz", ".hmp.gz"])
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      _ -> []
    end
  end
end
