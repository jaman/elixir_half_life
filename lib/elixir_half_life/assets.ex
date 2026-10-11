defmodule ElixirHalfLife.Assets do
  @moduledoc """
  Half-Life's files and FreeHL's game code, read once and shared by every process.

      {:ok, _} = ElixirHalfLife.Assets.load("/games/Half-Life", "/games/freehl")
      ElixirHalfLife.Assets.map("c1a0")

  `load/2` takes the Half-Life install (its `valve` directory, or the directory holding
  one) and the directory holding FreeHL's `package_valve.pk3` or its unpacked files. The
  install must hold Half-Life's own `valve/halflife.wad` and `valve/maps/c0a0.bsp`;
  without them `load/2` returns `{:error, {:no_half_life, missing}}`, `missing` the names
  not found.
  Everything is kept in `:persistent_term`, each thing made once even when several
  processes ask for it at the same time.
  """

  alias Cauldron3D.Formats.{Bsp, Entities, Files, Spr, Studio, Wad3, Wav}
  alias Cauldron3D.Texture

  @key __MODULE__
  @install_files ["halflife.wad", "maps/c0a0.bsp"]
  @hulls [
    {{-16.0, -16.0, -36.0}, {16.0, 16.0, 36.0}},
    {{-32.0, -32.0, -32.0}, {32.0, 32.0, 32.0}},
    {{-16.0, -16.0, -18.0}, {16.0, 16.0, 18.0}}
  ]

  @doc """
  Open the game files, read every wall texture in the install's WAD3 collections, and
  compile FreeHL's server, client and menu programs (`QuakeC.Compiler.load/1`), from its
  disk cache when it has them.
  """
  @spec load(Path.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def load(half_life, freehl) do
    with :ok <- installed(half_life),
         {:ok, files} <- Files.open([half_life, freehl], within: "valve"),
         true <- Files.exists?(files, "progs.dat") || {:error, :no_freehl} do
      textures =
        files
        |> Files.list("")
        |> Enum.filter(&(Path.extname(&1) == ".wad" and not String.contains?(&1, "/")))
        |> Enum.reduce(%{}, fn wad, acc ->
          Map.merge(acc, Wad3.textures(Files.read(files, wad)))
        end)

      assets = %{files: files, textures: textures, half_life: half_life, freehl: freehl}
      :persistent_term.put(@key, assets)
      compile_programs()
      {:ok, assets}
    end
  end

  @doc "What `load/2` read."
  @spec get() :: map()
  def get, do: :persistent_term.get(@key)

  @doc "The bytes of file `name`, or `nil`; each file is read from the game files once."
  @spec read(String.t()) :: binary() | nil
  def read(name),
    do: cached({:read, String.downcase(name)}, fn -> Files.read(get().files, name) end)

  @doc "The game's file names starting with `prefix`, sorted; each prefix is listed once."
  @spec list(String.t()) :: [String.t()]
  def list(prefix) do
    prefix = String.downcase(prefix)
    cached({:list, prefix}, fn -> Files.list(get().files, prefix) end)
  end

  @doc """
  Where file `name` is found in the order the game files are searched, as FTE's
  `COM_FDepthFile` counts it: 0 for the first place searched, `nil` when there is no
  such file. The places are searched in the order `Cauldron3D.Formats.Files` resolves
  a name: the last directory given to `load/2` first; within a directory its loose
  files, then its `.pk3` archives from the last by name (each archive before the
  archives inside it, those from the last), then its numbered `.pak` archives from the
  highest. The places are listed once.
  """
  @spec depth(String.t()) :: non_neg_integer() | nil
  def depth(name) do
    lower = String.downcase(name)
    Enum.find_index(search_places(), &holds?(&1, lower))
  end

  @doc "The sound `name` under `sound/` as a `TuningFork.Voice`, or `nil`."
  @spec sound(String.t()) :: TuningFork.Voice.t() | nil
  def sound(name) do
    cached({:sound, name}, fn ->
      case Wav.read(read("sound/" <> name)) do
        {:ok, %{rate: rate, pcm: pcm}} ->
          TuningFork.Voice.new(
            sample: TuningFork.Sample.from_pcm(pcm, rate: rate, root: 440.0),
            freq: 440.0,
            gain: 1.0
          )

        :error ->
          nil
      end
    end)
  end

  @doc """
  The sound `name` under `sound/` as its length and loop start in seconds (`loop` `nil`
  for a sound that plays once), rate and mono 16-bit PCM, or `nil`.
  """
  @spec sample(String.t()) ::
          %{seconds: float(), loop: float() | nil, rate: pos_integer(), pcm: binary()} | nil
  def sample(name) do
    cached({:sample, name}, fn ->
      case Wav.read(read("sound/" <> name)) do
        {:ok, %{rate: rate, pcm: pcm, loop: loop}} ->
          %{seconds: byte_size(pcm) / 2 / rate, loop: loop, rate: rate, pcm: pcm}

        :error ->
          nil
      end
    end)
  end

  @doc "FreeHL's server program, `progs.dat`."
  @spec progs() :: QuakeC.Progs.t()
  def progs, do: cached(:progs, fn -> program("progs.dat") end)

  @doc "FreeHL's client program, `csprogs.dat`."
  @spec csprogs() :: QuakeC.Progs.t()
  def csprogs, do: cached(:csprogs, fn -> program("csprogs.dat") end)

  @doc "FreeHL's menu program, `menu.dat`."
  @spec menu() :: QuakeC.Progs.t()
  def menu, do: cached(:menu, fn -> program("menu.dat") end)

  @doc "The map `name` (without `maps/` or `.bsp`) as `%{bsp:, entities:}`, or `nil`."
  @spec map(String.t()) :: map() | nil
  def map(name), do: cached({:map, name}, fn -> parse_map(read("maps/#{name}.bsp")) end)

  @doc """
  The model file `name`, as `%{kind:, data:, mins:, maxs:}`: `kind` `:studio` (a
  `Cauldron3D.Formats.Studio` with its separate texture and sequence files added),
  `:sprite`, `:brush` (a map file's world, as `%{bsp:, entities:}`) or `:missing`.
  """
  @spec model(String.t()) :: map()
  def model(name), do: cached({:model, name}, fn -> read_model(name, read(name)) end)

  @doc """
  Start reading, in the background, the maps map `name`'s level changes lead to, with
  the models and sounds their entities name, so they are ready when the game gets there.
  Each map's neighbours are read once.
  """
  @spec prefetch(String.t()) :: :ok
  def prefetch(name) do
    cached({:prefetch, name}, fn -> Task.start(fn -> warm(name) end) end)
    :ok
  end

  @doc """
  Half-Life's texture kinds by name: `sky` is sky; `!…` and `*…` are liquid; `aaatrigger`,
  `clip`, `origin`, `null` and `bevel` are hidden; `{…` is masked (see-through at colour
  255); everything else is solid. A texture
  the map names but does not hold comes from the install's WAD3 collections.
  """
  @spec texture(String.t(), [Texture.t()]) :: map()
  def texture(name, []), do: texture(name, Map.get(get().textures, name, Bsp.missing().mips))
  def texture("sky" = name, mips), do: %{name: name, kind: :sky, mips: mips}
  def texture("!" <> _ = name, mips), do: %{name: name, kind: :liquid, mips: mips}
  def texture("{" <> _ = name, mips), do: %{name: name, kind: :masked, mips: mips}
  def texture("*" <> _ = name, mips), do: %{name: name, kind: :liquid, mips: mips}

  def texture(name, mips) when name in ["aaatrigger", "clip", "origin", "null", "bevel"],
    do: %{name: name, kind: :hidden, mips: mips}

  def texture(name, mips), do: Bsp.solid(name, mips)

  @doc "The hull a box of `size` moves through in a brush model, as FTE chooses it (`QuakeServer.World.choose_hull/2`)."
  @spec hull([Cauldron3D.Hull.t()], Cauldron3D.Vec.t()) :: Cauldron3D.Hull.t()
  def hull(hulls, size), do: QuakeServer.World.choose_hull(hulls, size)

  defp search_places,
    do:
      cached(:search_places, fn ->
        get().files.dirs |> Enum.reverse() |> Enum.flat_map(&places_in/1)
      end)

  defp places_in(dir) do
    names =
      case File.ls(dir) do
        {:ok, names} -> names
        {:error, _} -> []
      end

    pk3s =
      names
      |> Enum.filter(&(String.downcase(Path.extname(&1)) == ".pk3"))
      |> Enum.sort_by(&String.downcase/1, :desc)

    paks =
      names
      |> Enum.flat_map(fn name ->
        case Regex.run(~r/\Apak(\d+)\.pak\z/, String.downcase(name)) do
          [_, number] -> [{String.to_integer(number), name}]
          nil -> []
        end
      end)
      |> Enum.sort(:desc)

    [{:loose, dir}] ++
      Enum.flat_map(pk3s, &archive_places(String.to_charlist(Path.join(dir, &1)))) ++
      Enum.map(paks, fn {_, pak} -> {:names, pak_names(Path.join(dir, pak))} end)
  end

  defp archive_places(archive) do
    case :zip.list_dir(archive) do
      {:ok, [_comment | entries]} ->
        names = for {:zip_file, name, _info, _, _, _} <- entries, do: name

        {inner, own} =
          Enum.split_with(names, &(String.downcase(Path.extname(List.to_string(&1))) == ".pk3"))

        own = MapSet.new(own, &String.downcase(List.to_string(&1)))

        [{:names, own}] ++
          (inner |> Enum.sort(:desc) |> Enum.flat_map(&inner_places(archive, &1)))

      _ ->
        []
    end
  end

  defp inner_places(archive, name) do
    case :zip.extract(archive, [{:file_list, [name]}, :memory]) do
      {:ok, [{_name, bytes}]} -> archive_places(bytes)
      _ -> []
    end
  end

  defp pak_names(path) do
    case File.read(path) do
      {:ok, <<"PACK", offset::little-32, size::little-32, _::binary>> = data}
      when offset + size <= byte_size(data) ->
        for <<name::binary-56, _at::little-32,
              _length::little-32 <- binary_part(data, offset, size)>>,
            into: MapSet.new(),
            do: name |> :binary.split(<<0>>) |> hd() |> String.downcase()

      _ ->
        MapSet.new()
    end
  end

  defp holds?({:names, names}, name), do: MapSet.member?(names, name)
  defp holds?({:loose, dir}, name), do: loose?(dir, Path.split(name))

  defp loose?(dir, [last]), do: dir |> entry(last) |> then(&(&1 != nil and File.regular?(&1)))

  defp loose?(dir, [part | rest]) do
    case entry(dir, part) do
      nil -> false
      sub -> File.dir?(sub) and loose?(sub, rest)
    end
  end

  defp entry(dir, part) do
    case File.ls(dir) do
      {:ok, names} ->
        case Enum.find(names, &(String.downcase(&1) == part)) do
          nil -> nil
          found -> Path.join(dir, found)
        end

      {:error, _} ->
        nil
    end
  end

  defp program(name) do
    {:ok, progs} = QuakeC.Progs.parse(read(name) || raise(ArgumentError, "there is no #{name}"))
    progs
  end

  defp cached(key, make) do
    case :persistent_term.get({@key, key}, :unread) do
      :unread -> :global.trans({{@key, key}, self()}, fn -> make_once(key, make) end)
      value -> value
    end
  end

  defp make_once(key, make) do
    case :persistent_term.get({@key, key}, :unread) do
      :unread ->
        value = make.()
        :persistent_term.put({@key, key}, value)
        value

      value ->
        value
    end
  end

  defp warm(name) do
    name
    |> entity_values(["map"])
    |> Enum.uniq()
    |> Enum.reject(&(&1 == name))
    |> Task.async_stream(&warm_map/1, timeout: :infinity, ordered: false)
    |> Stream.run()
  end

  defp warm_map(name) do
    map(name)

    name
    |> entity_values(["model", "message", "noise", "noise1", "noise2"])
    |> Enum.uniq()
    |> Task.async_stream(&warm_file/1, timeout: :infinity, ordered: false)
    |> Stream.run()
  end

  defp warm_file(name) do
    cond do
      Path.extname(name) in [".mdl", ".spr"] -> model(name)
      Path.extname(name) == ".wav" -> sound(name)
      true -> nil
    end
  end

  defp entity_values(name, keys) do
    case map(name) do
      %{entities: text} ->
        for {_block, values} <- Entities.blocks(text),
            key <- keys,
            value = values[key],
            value != nil,
            do: value

      nil ->
        []
    end
  end

  defp parse_map(nil), do: nil

  defp parse_map(data) do
    case Bsp.parse(data, hulls: @hulls, texture: &texture/2) do
      {:ok, map} -> map
      _ -> nil
    end
  end

  defp read_model(_name, nil), do: missing()

  defp read_model(name, data) do
    case Path.extname(name) do
      ".mdl" -> studio(name, data)
      ".spr" -> data |> Spr.parse() |> from(:sprite)
      ".bsp" -> data |> parse_map() |> brush()
      _ -> missing()
    end
  end

  defp studio(name, data) do
    case Studio.parse(data) do
      {:ok, studio} ->
        base = Path.rootname(name)

        studio =
          if tuple_size(studio.textures) == 0,
            do: Studio.add_textures(studio, read(base <> "t.mdl") || ""),
            else: studio

        studio =
          studio
          |> Studio.missing_groups()
          |> Enum.reduce(studio, fn group, acc ->
            file = base <> String.pad_leading(Integer.to_string(group), 2, "0") <> ".mdl"
            Studio.add_group(acc, group, read(file) || "")
          end)

        %{kind: :studio, data: studio, mins: studio.mins, maxs: studio.maxs}

      _ ->
        missing()
    end
  end

  defp from({:ok, data}, kind), do: %{kind: kind, data: data, mins: data.mins, maxs: data.maxs}
  defp from(_error, _kind), do: missing()

  defp brush(%{bsp: bsp} = map) do
    %{mins: mins, maxs: maxs} = elem(bsp.models, 0)
    %{kind: :brush, data: map, mins: mins, maxs: maxs}
  end

  defp brush(nil), do: missing()

  defp missing, do: %{kind: :missing, data: nil, mins: {0.0, 0.0, 0.0}, maxs: {0.0, 0.0, 0.0}}

  defp installed(half_life) do
    with {:ok, files} <- Files.open(half_life, within: "valve") do
      case Enum.reject(@install_files, &Files.exists?(files, &1)) do
        [] -> :ok
        absent -> {:error, {:no_half_life, absent}}
      end
    end
  end

  defp compile_programs do
    [&progs/0, &csprogs/0, &menu/0]
    |> Task.async_stream(&QuakeC.Compiler.load(&1.()), timeout: :infinity)
    |> Stream.run()
  end
end
