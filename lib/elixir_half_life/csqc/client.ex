defmodule ElixirHalfLife.Csqc.Client do
  @moduledoc """
  The builtins of FTE's client and menu programs about the client and the engine
  around it (`pr_clcmd.c`, `pr_csqc.c`), under the client program's numbers:
  `cprint` (338), `isdemo` (349), `isserver` (350), `setlocaluserinfo`,
  `getlocaluserinfo`, `setlocaluserinfoblob`, `getlocaluserinfoblob`, `clipboard_set`,
  `setwindowcaption`, `setmousetarget` (603), `getmousetarget` (604), `getresolution`
  (608), `getgamedirinfo` (626) and `getpackagemanagerinfo`.

    * `cprint` prints its joined arguments in the middle of the screen, as a
      `{:print, :center, text}` event.
    * `isdemo` is 0: no demo plays.
    * `isserver` is 0.5 while a server runs in the host's console variable table
      (`QuakeServer.Cvars.running?/2`; the server has one player slot), 0 otherwise.
    * The local user info of seat 0 is the player's: a key naming a `:userinfo`
      console variable reads and sets that variable; other keys live in the host's
      `ext.local_userinfo`. Another seat holds its own keys there; a seat outside 0 to 3
      is a program error.
    * `clipboard_set` keeps the text in `ext.clipboard` (by clipboard number).
    * `setwindowcaption` keeps the caption in `ext.window_caption` (`nil` for empty).
    * `setmousetarget` 1 makes the mouse move by deltas for this program, 2 absolute
      (`ext.absolute_mouse`); another value is a program error. `getmousetarget` gives
      2 when absolute, else 1.
    * `getresolution(mode, fullscreen)` gives `{width, height, 1}` of video mode `mode`
      (`modes/1`), the desktop for -1 (the host's `ext.desktop`, zeros when the host
      has none), and zeros past the list.
    * `getgamedirinfo(index, property)` reads `ElixirHalfLife.GameDirs` (index -1 the
      running game): 0 the game directory, 1 every game directory (`;` between), 2 the
      description, 3 the commands run first, 4 the command switching to it
      (`fs_changegame n`), 5 its icon (none here); null past the list.
    * `getpackagemanagerinfo` is null for every package: the package manager knows no
      packages.
  """

  alias ElixirHalfLife.GameDirs
  alias QuakeC.Exec
  alias QuakeServer.{Args, Cvars, Events}

  @fallback_modes [
    "640x480",
    "800x600",
    "960x720",
    "1024x768",
    "1152x864",
    "1280x960",
    "1440x1080",
    "1600x1200",
    "1920x1440",
    "2048x1536",
    "1280x1024",
    "1800x1440",
    "2560x2048",
    "856x480",
    "1024x576",
    "1280x720",
    "1366x768",
    "1600x900",
    "1920x1080",
    "2048x1152",
    "2560x1440",
    "3840x2160",
    "4096x2304",
    "1024x640",
    "1152x720",
    "1280x800",
    "1440x900",
    "1680x1050",
    "1920x1200",
    "2304x1440",
    "2560x1600"
  ]

  @doc "The builtins this module runs."
  @spec builtins() :: [integer() | String.t()]
  def builtins,
    do: [
      338,
      349,
      350,
      "setlocaluserinfo",
      "getlocaluserinfo",
      "setlocaluserinfoblob",
      "getlocaluserinfoblob",
      "clipboard_set",
      "setwindowcaption",
      603,
      604,
      608,
      626,
      "getpackagemanagerinfo"
    ]

  @doc """
  The video modes `getresolution` lists, in order: FTE's own list of 4:3, 5:4, 16:9 and
  16:10 sizes (the terminal lists no modes of its own), without those smaller than
  `vid_minsize` (`cvars`' value, default 320 by 200), sorted by width then height.
  """
  @spec modes(Cvars.t() | nil) :: [{pos_integer(), pos_integer()}]
  def modes(cvars) do
    {min_width, min_height} = minimum(cvars)

    @fallback_modes
    |> Enum.map(fn mode ->
      [width, height] = mode |> String.split("x") |> Enum.map(&String.to_integer/1)
      {width, height}
    end)
    |> Enum.reject(fn {width, height} -> width < min_width or height < min_height end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Whether a server runs in `host`'s console variable table."
  @spec server_running?(map()) :: boolean()
  def server_running?(%{cvars: %Cvars{} = cvars}), do: Cvars.running?(cvars, :server)
  def server_running?(_host), do: false

  @doc "Run client builtin `builtin`, one of `builtins/0`."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 338, argc), do: Events.print(s, :center, joined(s, 0, argc))
  def call(s, 349, _argc), do: Args.return(s, 0.0)
  def call(s, 350, _argc), do: Args.return(s, if(server_running?(s), do: 0.5, else: 0.0))

  def call(s, name, argc) when name in ["setlocaluserinfo", "setlocaluserinfoblob"] do
    with {:ok, seat} <- seat(s) do
      value =
        if argc < 4,
          do: Args.str(s, 2),
          else: memory_bytes(s.qc, Args.int(s, 2), Args.int(s, 3))

      put_userinfo(s, seat, Args.str(s, 1), value)
    end
  end

  def call(s, "getlocaluserinfo", _argc) do
    with {:ok, seat} <- seat(s) do
      Args.return(s, userinfo(s, seat, Args.str(s, 1)))
    end
  end

  def call(s, "getlocaluserinfoblob", _argc) do
    with {:ok, seat} <- seat(s) do
      blob = userinfo(s, seat, Args.str(s, 1))
      pointer = Args.int(s, 2)

      if pointer != 0 do
        bytes = binary_part(blob, 0, min(byte_size(blob), max(Args.int(s, 3), 0)))
        %{s | qc: write_bytes(s.qc, pointer, bytes)} |> Args.return(byte_size(bytes))
      else
        Args.return(s, byte_size(blob))
      end
    end
  end

  def call(s, "clipboard_set", _argc),
    do: put_ext(s, :clipboard, &Map.put(&1 || %{}, Args.int(s, 0), Args.str(s, 1)))

  def call(s, "setwindowcaption", _argc) do
    caption = Args.str(s, 0)
    put_ext(s, :window_caption, fn _ -> if caption == "", do: nil, else: caption end)
  end

  def call(s, 603, _argc) do
    case Args.int(s, 0) do
      1 -> put_ext(s, :absolute_mouse, fn _ -> false end)
      2 -> put_ext(s, :absolute_mouse, fn _ -> true end)
      _ -> raise Exec.Error, "PF_setmousetarget: not a valid destination"
    end
  end

  def call(s, 604, _argc),
    do: Args.return(s, if(Map.get(s.ext, :absolute_mouse, false), do: 2.0, else: 1.0))

  def call(s, 608, _argc) do
    {width, height} = resolution(s, Args.int(s, 0))
    Args.return(s, {width / 1, height / 1, if(width != 0 and height != 0, do: 1.0, else: 0.0)})
  end

  def call(s, 626, _argc) do
    index = Args.int(s, 0)
    mod = if index == -1, do: GameDirs.current(), else: Enum.at(GameDirs.list(), index)

    if mod,
      do: Args.return(s, game_property(mod, Args.int(s, 1), index) || 0),
      else: Args.return(s, 0)
  end

  def call(s, "getpackagemanagerinfo", _argc), do: Args.return(s, 0)

  defp joined(s, from, argc), do: Enum.map_join(from..(argc - 1)//1, &Args.str(s, &1))

  defp seat(s) do
    seat = Args.int(s, 0)

    if seat in 0..3,
      do: {:ok, seat},
      else: raise(Exec.Error, "PF_cs_getlocaluserinfoblob: invalid seat")
  end

  defp put_userinfo(s, 0, key, value) do
    case s.cvars && Cvars.fetch(s.cvars, key) do
      nil ->
        put_local(s, 0, key, value)

      cvar ->
        if Cvars.flag?(cvar, :userinfo),
          do: QuakeServer.Server.put_cvar(s, key, value),
          else: put_local(s, 0, key, value)
    end
  end

  defp put_userinfo(s, seat, key, value), do: put_local(s, seat, key, value)

  defp put_local(s, seat, key, value) do
    put_ext(s, :local_userinfo, fn infos ->
      infos = infos || %{}
      seat_info = Map.get(infos, seat, %{})

      seat_info =
        if value == "", do: Map.delete(seat_info, key), else: Map.put(seat_info, key, value)

      Map.put(infos, seat, seat_info)
    end)
  end

  defp userinfo(s, seat, key) do
    cvar = seat == 0 && s.cvars && Cvars.fetch(s.cvars, key)

    if cvar && Cvars.flag?(cvar, :userinfo),
      do: cvar.string,
      else: s.ext |> Map.get(:local_userinfo, %{}) |> Map.get(seat, %{}) |> Map.get(key, "")
  end

  defp resolution(s, -1), do: Map.get(s.ext, :desktop, {0, 0})
  defp resolution(s, mode) when mode >= 0, do: Enum.at(modes(s.cvars), mode, {0, 0})
  defp resolution(_s, _mode), do: {0, 0}

  defp minimum(nil), do: {320, 200}

  defp minimum(cvars) do
    case cvars |> Cvars.string("vid_minsize") |> String.split() |> Enum.map(&Cvars.c_atof/1) do
      [width, height | _] -> {width, height}
      [width] -> {width, 0.0}
      [] -> {0.0, 0.0}
    end
  end

  defp game_property(mod, 0, _index), do: mod.gamedir

  defp game_property(mod, 1, _index) do
    case mod.manifest do
      nil -> mod.gamedir
      manifest -> Enum.join(manifest.basegames ++ manifest.mods, ";")
    end
  end

  defp game_property(mod, 2, _index), do: mod.description
  defp game_property(%{manifest: %{defaultexec: exec}}, 3, _index), do: exec
  defp game_property(_mod, 4, index), do: "fs_changegame #{index + 1}\n"
  defp game_property(_mod, _property, _index), do: nil

  defp put_ext(s, key, fun), do: %{s | ext: Map.put(s.ext, key, fun.(Map.get(s.ext, key)))}

  defp memory_bytes(qc, address, size) do
    words = div(max(size, 0) + 3, 4)

    bytes =
      for i <- 0..(words - 1)//1,
          into: <<>>,
          do: word_bytes(QuakeC.load(qc, address + 4 * i))

    binary_part(bytes, 0, min(max(size, 0), byte_size(bytes)))
  end

  defp word_bytes(value) when is_integer(value),
    do: <<Bitwise.band(value, 0xFFFFFFFF)::little-32>>

  defp word_bytes(value) when is_float(value), do: <<value::little-float-32>>
  defp word_bytes(_value), do: <<0::32>>

  defp write_bytes(qc, address, bytes) do
    whole = byte_size(bytes) - rem(byte_size(bytes), 4)
    <<head::binary-size(^whole), tail::binary>> = bytes

    padded =
      if tail == "" do
        head
      else
        existing = word_bytes(QuakeC.load(qc, address + whole))
        head <> tail <> binary_part(existing, byte_size(tail), 4 - byte_size(tail))
      end

    for {<<word::little-signed-32>>, i} <- Enum.with_index(chunks(padded)), reduce: qc do
      qc -> QuakeC.store(qc, address + 4 * i, word)
    end
  end

  defp chunks(<<>>), do: []
  defp chunks(<<word::binary-size(4), rest::binary>>), do: [word | chunks(rest)]
end
