defmodule ElixirHalfLife.PlayerUse do
  @moduledoc """
  The use key choosing what it uses as Half-Life's `CBasePlayer::PlayerUse` chooses,
  run in place of FreeHL's `NSClientPlayer::InputUse_Down` (`down/2`). FreeHL runs that
  function with `self` the player while use is held; it does nothing for a dead player
  (`health` 0 or below) or one whose `flags` lack `FL_USE_RELEASED` (1048576).

  The target:

    * on a fresh press (`NSClientPlayer::__mlast_used` is the world), the train the
      player drives (`NSClientPlayer::__mvehicle`); otherwise the train the player
      stands on (`groundentity`) when the player is on the ground (`FL_ONGROUND`), is not
      holding jump (`button2`), and is on its controls (the program's
      `<classname>::ControlCheck` of the player, run with `self` the train, when the
      program has one). A train is a `func_tracktrain` or `func_vehicle` (Half-Life's
      directional-use entities) with a `PlayerUse`.
    * otherwise, of every entity Half-Life lets the player use whose box (`absmin`..`absmax`
      as linking it now gives it, `QuakeServer.World.bounds/2`) is nearer than 64 units
      to the player's origin, the one most in view: the direction from the eye
      (`origin + view_ofs`) to the box's centre (`absmin + size / 2`) is shortened on
      each axis by half the entity's `size` on it (an axis the eye lies within counts 0)
      and made unit length (`{0, 0, 1}` when nothing is left); the entity whose direction
      lies most along the view (`v_angle`'s forward) is chosen, when that is above 0.7;
      the lowest entity number wins a tie.

  An entity the player can use has a `PlayerUse` and a class Half-Life gives use caps
  (`ObjectCaps`): always `monster_barney`, `monster_scientist`,
  `monster_sitting_scientist`, `func_healthcharger`, `func_recharge`, `func_pushable`,
  `func_tankcontrols`, `cycler`, `cycler_prdroid` and `cycler_sprite`; `func_door`,
  `func_water` and `func_door_rotating` with spawnflag 256 (use only); `func_button` and
  `func_rot_button` that take no damage (`takedamage` 0); `momentary_rot_button` without
  spawnflag 1 (a door); `button_target` with spawnflag 1 (use). Any other class is not
  used.

  With a target, as FreeHL: `FL_USE_RELEASED` is cleared, `_NSClientPlayer_useworkaround`
  runs the target's `PlayerUse` with the player as `eActivator`, the target becomes
  `NSClientPlayer::__mlast_used`, and the player sounds `Player.WeaponSelected` unless
  the use set `FL_USE_RELEASED` again (a target used for as long as use is held, such as
  a charger). Without one the player sounds `Player.DenyWeaponSelection` and
  `FL_USE_RELEASED` is cleared. `v_forward`, `v_right` and `v_up` are left as the view's.

      ElixirHalfLife.PlayerUse.replacements()
      #=> %{"NSClientPlayer::InputUse_Down" => &ElixirHalfLife.PlayerUse.down/2}
  """

  import Bitwise

  alias Cauldron3D.Vec
  alias QuakeC.Exec
  alias QuakeServer.{Angles, Edicts, Server, World}

  @function "NSClientPlayer::InputUse_Down"
  @use_released 1_048_576
  @search_radius 64.0
  @view_field_narrow 0.7
  @trains ["func_tracktrain", "func_vehicle"]
  @always_usable [
    "monster_barney",
    "monster_scientist",
    "monster_sitting_scientist",
    "func_healthcharger",
    "func_recharge",
    "func_pushable",
    "func_tankcontrols",
    "cycler",
    "cycler_prdroid",
    "cycler_sprite"
  ]
  @use_only_doors ["func_door", "func_water", "func_door_rotating"]
  @buttons ["func_button", "func_rot_button"]
  @door_use_only 256
  @momentary_door 1
  @button_target_use 1
  @chan_item 3.0
  @last_used "NSClientPlayer::__mlast_used"
  @vehicle "NSClientPlayer::__mvehicle"

  @doc "The program functions this module runs in place of FreeHL's, for `QuakeServer.Source.replacements/0`."
  @spec replacements() :: %{String.t() => (Server.t(), non_neg_integer() -> Server.t())}
  def replacements, do: %{@function => &down/2}

  @doc "Press use for the player in `self`, choosing and using the target as the module describes."
  @spec down(Server.t(), non_neg_integer()) :: Server.t()
  def down(%Server{} = server, _argc) do
    player = entity_global(server, "self")

    if ready?(server, player),
      do: server |> view_vectors(player) |> use_target(player),
      else: server
  end

  @doc """
  The entity the player `player` would use now (`nil` when none), as the module
  describes; `pressed?` is whether use was just pressed, which lets a train be chosen.
  """
  @spec target(Server.t(), non_neg_integer(), boolean()) :: non_neg_integer() | nil
  def target(%Server{} = server, player, pressed?) do
    (pressed? && train(server, player)) || in_view(server, player)
  end

  defp ready?(server, player),
    do: Edicts.float(server, player, "health") > 0 and use_released?(server, player)

  defp use_released?(server, player),
    do: (trunc(Edicts.float(server, player, "flags")) &&& @use_released) != 0

  defp use_target(server, player) do
    case target(server, player, Edicts.int(server, player, @last_used) == 0) do
      nil -> deny(server, player)
      found -> use(server, player, found)
    end
  end

  defp use(server, player, found) do
    server =
      server
      |> clear_use_released(player)
      |> call("_NSClientPlayer_useworkaround", [found])
      |> Edicts.put(player, @last_used, found)

    if use_released?(server, player),
      do: server,
      else: sound(server, "Player.WeaponSelected")
  end

  defp deny(server, player) do
    server
    |> sound("Player.DenyWeaponSelection")
    |> clear_use_released(player)
  end

  defp clear_use_released(server, player) do
    flags = trunc(Edicts.float(server, player, "flags")) &&& bnot(@use_released)
    Edicts.put(server, player, "flags", flags / 1)
  end

  defp sound(server, name), do: call(server, "NSEntity::StartSoundDef", [name, @chan_item, 0.0])

  defp train(server, player) do
    driven = Edicts.int(server, player, @vehicle)
    ground = Edicts.int(server, player, "groundentity")

    cond do
      train?(server, driven) -> driven
      train?(server, ground) and on_controls?(server, player, ground) -> ground
      true -> nil
    end
  end

  defp train?(_server, 0), do: false

  defp train?(server, entity),
    do: player_use?(server, entity) and Edicts.string(server, entity, "classname") in @trains

  defp on_controls?(server, player, train) do
    Edicts.flag?(server, player, :onground) and Edicts.float(server, player, "button2") == 0 and
      control_check(server, player, train)
  end

  defp control_check(server, player, train) do
    name = Edicts.string(server, train, "classname") <> "::ControlCheck"

    case QuakeC.Progs.function(server.qc.progs, name) do
      nil ->
        true

      _index ->
        server
        |> Server.keeping_self(fn s ->
          s
          |> Map.update!(:qc, &QuakeC.put_global(&1, "self", train))
          |> call(name, [player])
        end)
        |> returned_true?()
    end
  end

  defp returned_true?(server), do: QuakeC.float(QuakeC.slot(server.qc, 1)) != 0

  defp in_view(server, player) do
    origin = Edicts.vector(server, player, "origin")
    eye = Vec.add(origin, Edicts.vector(server, player, "view_ofs"))
    forward = QuakeC.global_vector(server.qc, "v_forward")

    server
    |> Edicts.live()
    |> Enum.filter(&usable?(server, &1))
    |> Enum.reduce({nil, @view_field_narrow}, fn entity, best ->
      closer(best, entity, view_dot(server, entity, origin, eye, forward))
    end)
    |> elem(0)
  end

  defp closer({_best, best_dot}, entity, dot) when is_float(dot) and dot > best_dot,
    do: {entity, dot}

  defp closer(best, _entity, _dot), do: best

  defp view_dot(server, entity, origin, eye, forward) do
    {absmin, absmax} = World.bounds(server, entity)

    if box_distance_squared(origin, absmin, absmax) < @search_radius * @search_radius do
      half = Vec.scale(Edicts.vector(server, entity, "size"), 0.5)

      absmin
      |> Vec.add(half)
      |> Vec.sub(eye)
      |> clamp_to_box(half)
      |> unit()
      |> Vec.dot(forward)
    end
  end

  defp box_distance_squared(point, absmin, absmax) do
    [point, absmin, absmax]
    |> Enum.map(&Tuple.to_list/1)
    |> Enum.zip()
    |> Enum.map(fn {p, low, high} -> outside(p, low, high) end)
    |> Enum.reduce(0.0, &(&1 * &1 + &2))
  end

  defp outside(p, low, _high) when p < low, do: p - low
  defp outside(p, _low, high) when p > high, do: p - high
  defp outside(_p, _low, _high), do: 0.0

  defp clamp_to_box({x, y, z}, {hx, hy, hz}), do: {shorten(x, hx), shorten(y, hy), shorten(z, hz)}

  defp shorten(value, half) when value > half, do: value - half
  defp shorten(value, half) when value < -half, do: value + half
  defp shorten(_value, _half), do: 0.0

  defp unit(vector) do
    case Vec.length(vector) do
      length when length == 0 -> {0.0, 0.0, 1.0}
      length -> Vec.scale(vector, 1 / length)
    end
  end

  defp usable?(server, entity) do
    player_use?(server, entity) and
      use_caps?(server, entity, Edicts.string(server, entity, "classname"))
  end

  defp player_use?(server, entity),
    do: QuakeC.float(Edicts.get(server, entity, "PlayerUse")) != 0

  defp use_caps?(_server, _entity, class) when class in @always_usable, do: true

  defp use_caps?(server, entity, class) when class in @use_only_doors,
    do: spawnflag?(server, entity, @door_use_only)

  defp use_caps?(server, entity, class) when class in @buttons,
    do: Edicts.float(server, entity, "takedamage") == 0

  defp use_caps?(server, entity, "momentary_rot_button"),
    do: not spawnflag?(server, entity, @momentary_door)

  defp use_caps?(server, entity, "button_target"),
    do: spawnflag?(server, entity, @button_target_use)

  defp use_caps?(_server, _entity, _class), do: false

  defp spawnflag?(server, entity, bit),
    do: (trunc(Edicts.float(server, entity, "spawnflags")) &&& bit) != 0

  defp view_vectors(server, player) do
    {forward, right, up} = Angles.vectors(Edicts.vector(server, player, "v_angle"))

    qc =
      server.qc
      |> QuakeC.put_global("v_forward", forward)
      |> QuakeC.put_global("v_right", right)
      |> QuakeC.put_global("v_up", up)

    %{server | qc: qc}
  end

  defp call(server, name, args) do
    qc =
      args
      |> Enum.with_index()
      |> Enum.reduce(server.qc, fn {value, i}, qc -> QuakeC.put_slot(qc, 4 + 3 * i, value) end)

    Exec.call_named(%{server | qc: qc}, name, server.builtins, Server.exec_opts(server))
  end

  defp entity_global(server, name), do: trunc(QuakeC.float(QuakeC.global(server.qc, name)))
end
