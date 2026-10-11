defmodule ElixirHalfLife.Client do
  @moduledoc """
  Half-Life as a `Cauldron2D.Client.Game`: the keys, the picture the terminal shows, the
  in-game menu and the sounds.

      mix half_life --dir "/games/Half-Life" --freehl /games/freehl

  The whole pane is FreeHL's client program's own frame (`ElixirHalfLife.ClientProgram`),
  drawn at the pane's size: the world, the entities it chooses, and its HUD.

  ## Keys

    * `W`/`S` or `↑`/`↓` — forward and back; `A`/`D` — strafe; `←`/`→` — turn
    * `T`/`G` or `PgUp`/`PgDn` — look up and down; `C` or `End` — look straight ahead
    * `'` and `/` — swim up and down; `;` — the mouse look modifier; `Insert` — the
      keyboard look modifier; the strafe modifier has no key until one is bound
    * `F` — fire; `V` — alternate fire; `Space` — jump; `X` — crouch; `E` — use;
      `R` — reload; `L` — flashlight; `Z` — walking on or off (`+speed`)
    * `Q`/`Tab` — previous and next weapon; `B` — the last weapon used; `1`–`6` — a
      weapon slot; `F5` — a screenshot; `F6` — note where you stand (a `setpos` line
      added to `positions.txt` in the game's data directory)
    * `Esc` — the menu (`ElixirHalfLife.Menu`): FreeHL's Configuration pages, with the
      game paused; `F2` — the terminal client's own settings (display, frame rate,
      pointer steering, levels and bindings); `P` — pause

  Each press of `Z` turns walking on or off. Where the terminal reports key releases
  every other key is held for as long as it is down; where it does not, held keys stay
  held while the terminal repeats them.

  The `mouse` preset adds the mouse: moving it turns and looks (the pointer actions,
  scaled by the menu's mouse settings), the buttons fire, the wheel changes weapon.

  ## Controller

    * left stick — move; right stick — turn and look; right trigger — fire; left
      trigger — alternate fire; `A` — jump; `B` — crouch; `X` — use; `Y` — reload;
      bumpers — weapons; `Start` — the menu, where the d-pad moves, `A` chooses and `B`
      goes back; `Back` — the terminal client's settings

  ## Options

  The player's options are `ElixirHalfLife.Options`, kept with their settings, given to
  the world when it is joined (`join_props/1`) and with every input after, and changed
  in the menu.

  ## Disconnection

  When the server ends (`ElixirHalfLife.Game`'s view `over`), the outcome is titled
  `Disconnected` with the reason under it, as FreeHL's menu shows a disconnection, and
  leads back to the lobby.
  """

  @behaviour Cauldron2D.Client.Game

  alias ElixirHalfLife.{
    Assets,
    ClientProgram,
    EightBitSound,
    Game,
    MediaSound,
    Menu,
    Options
  }

  @atlas :elixir_half_life
  @pointer [:pointer_left, :pointer_right, :pointer_up, :pointer_down]

  @impl true
  def title, do: %{name: "HALF-LIFE", tagline: "FreeHL, in Elixir, in your terminal"}

  @impl true
  def atlas do
    unless Cauldron2D.Atlas.installed?(@atlas) do
      @atlas |> Cauldron2D.Atlas.new(tile: 16, void: {0, 0, 0}) |> Cauldron2D.Atlas.install()
    end

    @atlas
  end

  @impl true
  def actions do
    [
      :forward,
      :back,
      :turn_left,
      :turn_right,
      :strafe_left,
      :strafe_right,
      :swim_up,
      :swim_down,
      :look_up,
      :look_down,
      :center_view,
      :strafe,
      :mouse_look,
      :klook,
      :walk,
      :fire,
      :alt_fire,
      :jump,
      :crouch,
      :use,
      :reload,
      :flashlight,
      :next_weapon,
      :prev_weapon,
      :last_weapon
    ] ++
      Enum.map(1..6, &:"weapon_#{&1}") ++ [:screenshot, :where] ++ @pointer
  end

  @impl true
  def keymaps do
    keys =
      Map.merge(
        %{
          forward: [:w, :up],
          back: [:s, :down],
          turn_left: [:left],
          turn_right: [:right],
          strafe_left: [:a],
          strafe_right: [:d],
          swim_up: [:"'"],
          swim_down: [:/],
          look_up: [:t, :page_up],
          look_down: [:g, :page_down],
          center_view: [:c, :end],
          strafe: [],
          mouse_look: [:";"],
          klook: [:insert],
          walk: [:z],
          fire: [:f],
          alt_fire: [:v],
          jump: [:" "],
          crouch: [:x],
          use: [:e],
          reload: [:r],
          flashlight: [:l],
          prev_weapon: [:q],
          next_weapon: [:tab],
          last_weapon: [:b],
          screenshot: [:f5],
          where: [:f6],
          pointer_left: [],
          pointer_right: [],
          pointer_up: [],
          pointer_down: []
        },
        Map.new(1..6, &{:"weapon_#{&1}", [:"#{&1}"]})
      )

    mouse = %{
      pointer_left: [{:mouse, :move_left}],
      pointer_right: [{:mouse, :move_right}],
      pointer_up: [{:mouse, :move_up}],
      pointer_down: [{:mouse, :move_down}],
      fire: [{:mouse, :left}],
      alt_fire: [{:mouse, :right}],
      prev_weapon: [{:mouse, :wheel_up}],
      next_weapon: [{:mouse, :wheel_down}]
    }

    [keyboard: keys, mouse: Map.merge(keys, mouse, fn _action, key, button -> key ++ button end)]
  end

  @impl true
  def padmap(_props) do
    %{
      forward: [:dpad_up, {:axis, :left_y, :neg}],
      back: [:dpad_down, {:axis, :left_y, :pos}],
      strafe_left: [{:axis, :left_x, :neg}],
      strafe_right: [{:axis, :left_x, :pos}],
      turn_left: [:dpad_left, {:axis, :right_x, :neg}],
      turn_right: [:dpad_right, {:axis, :right_x, :pos}],
      look_up: [{:axis, :right_y, :neg}],
      look_down: [{:axis, :right_y, :pos}],
      fire: [{:axis, :right_trigger, :pos}],
      alt_fire: [{:axis, :left_trigger, :pos}],
      jump: [:a],
      crouch: [:b],
      use: [:x],
      reload: [:y],
      prev_weapon: [:left_bumper],
      next_weapon: [:right_bumper]
    }
  end

  @impl true
  def client_pad,
    do: %{menu: :start, settings: :back, projection: nil, turn_left: nil, turn_right: nil}

  @impl true
  def toggles, do: []

  @impl true
  def holds do
    for action <- [
          :forward,
          :back,
          :turn_left,
          :turn_right,
          :strafe_left,
          :strafe_right,
          :swim_up,
          :swim_down,
          :look_up,
          :look_down,
          :strafe,
          :mouse_look,
          :klook,
          :fire,
          :alt_fire,
          :jump,
          :crouch,
          :use
        ],
        do: {action, 160}
  end

  @impl true
  def client_keys do
    %{
      menu: :escape,
      back: nil,
      settings: :f2,
      title: nil,
      talk: nil,
      watch: nil,
      team: nil,
      chat: nil,
      guide: nil,
      projection: nil,
      turn_left: nil,
      turn_right: nil,
      tilt_up: nil,
      tilt_down: nil,
      zoom_in: nil,
      zoom_out: nil,
      zoom_reset: nil
    }
  end

  @impl true
  def options, do: Options.defaults()

  @impl true
  def open_menu(settings), do: Menu.open(settings)

  @impl true
  def menu_event(menu, event, settings), do: Menu.event(menu, event, settings)

  @impl true
  def join_props(%{settings: %{options: options}}), do: %{options: options}
  def join_props(_player), do: %{}

  @impl true
  def start, do: {:play, :half_life}

  @impl true
  def look, do: %{projection: :picture, projections: [:picture], picture: [{:native, 1}, :swap]}

  @impl true
  def chat?, do: false

  @impl true
  def lobby?, do: false

  @impl true
  def worlds(props) do
    game_opts = [
      map: Map.get(props, :map) || "c0a0",
      skill: Map.get(props, :skill, 1),
      setpos: Map.get(props, :setpos)
    ]

    [
      %{
        id: :half_life,
        name: "Half-Life",
        world: {Game, [hz: 20, game_opts: game_opts]},
        players: 0,
        humans: []
      }
    ]
  end

  @impl true
  def scene(view), do: scene(view, look())

  @impl true
  def scene(view, look) do
    overlay = overlay(Map.get(look, :menu))

    %{
      focus: {0.0, 0.0},
      bounds: :unbounded,
      cell: fn _cell -> nil end,
      movers: [],
      native: native(view),
      picture: fn {width, height}, aspect ->
        {width, height} = {max(width, 32), max(height, 20)}

        case view do
          %{program: program} when is_pid(program) ->
            FrenchCurve.Raster.from_rgba(
              width,
              height,
              ClientProgram.picture(program, {width, height}, aspect, overlay)
            )

          _ ->
            FrenchCurve.Raster.from_rgba(
              width,
              height,
              :binary.copy(<<0, 0, 0, 255>>, width * height)
            )
        end
      end
    }
  end

  defp native(%{picture_width: width}), do: {width, round(width * 9 / 16)}
  defp native(_view), do: nil

  @impl true
  def hud(_view), do: []

  @impl true
  def listener(%{listener: {x, y, _}}), do: {x / 33.0, y / 33.0}
  def listener(_view), do: nil

  @impl true
  def sounds do
    fn
      {:sample, name, rate} -> pitched(Assets.sound(name), rate)
      {:sample, name, rate, :s8} -> pitched(EightBitSound.voice(name), rate)
      {:menu_sound, name} -> MediaSound.voice(name)
      _other -> nil
    end
  end

  @impl true
  def audio, do: [voices: 64]

  @impl true
  def music, do: []

  @impl true
  def cue(_view, _screen), do: nil

  @impl true
  def outcome(%{over: reason}) when is_binary(reason),
    do: %{
      title: "Disconnected",
      lines: reason |> String.trim() |> String.split("\n"),
      next: :lobby
    }

  def outcome(_view), do: nil

  defp overlay(nil), do: nil
  defp overlay(menu), do: &Menu.Draw.over(menu, &1)

  defp pitched(nil, _rate), do: nil
  defp pitched(voice, rate), do: %{voice | freq: voice.freq * rate}
end
