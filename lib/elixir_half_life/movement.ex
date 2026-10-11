defmodule ElixirHalfLife.Movement do
  @moduledoc """
  The player's view angles and movement for one tick, as FTE's client works them out
  from the keys and the mouse: `CL_AdjustAngles` and `CL_BaseMove` for the keys, the
  mouse half of `IN_MoveMouse` for the pointer, and `V_DriftPitch` for the view drifting
  back level.

      look = ElixirHalfLife.Movement.new()
      {angles, {forward, side, up}, look} =
        ElixirHalfLife.Movement.step(look, input, angles, mouse, motion, dt)

  `input` is `%{held, strength, previous}`: the actions held now, how hard each analog
  one is held (`0.0..1.0`, keys in full), and the actions held the tick before. The
  actions read:

    * `:forward`, `:back`, `:strafe_left`, `:strafe_right`, `:swim_up`, `:swim_down` —
      `+forward`, `+back`, `+moveleft`, `+moveright`, `+moveup`, `+movedown`
    * `:turn_left`, `:turn_right`, `:look_up`, `:look_down` — `+left`, `+right`,
      `+lookup`, `+lookdown`; `:center_view` — `force_centerview`
    * `:walk` — `+speed`, moves scaled by `cl_movespeedkey`
    * `:strafe` — `+strafe`: the turn keys strafe, and the pointer's sideways movement
      strafes
    * `:klook` — `+klook`: forward and back look down and up instead of moving
    * `:mouse_look` — `+mlook`, on from the start as FTE has it; letting it go turns
      mouse look off until it is held again, and with `lookspring` starts the view
      drifting level. With mouse look off the pointer's up and down move forward and
      back
    * `:pointer_left`, `:pointer_right`, `:pointer_up`, `:pointer_down` — the pointer
      moving that way; each tick one is held counts as `mouse_counts * dt` mouse counts

  `mouse` is `ElixirHalfLife.Options.mouse/1`'s map with `:scale`, the client
  program's sensitivity scaler (`setsensitivityscaler`). `motion` is
  `%{onground, velocity}`, the player as the server last had them. Angles are
  `{pitch, yaw, roll}` in degrees, pitch held to ±89 and yaw to 0–360.

  The console variables are the look's `cvars`, given to `new/1` over FTE's and
  Half-Life's defaults (`cvars/0`).
  """

  defstruct mlook: true,
            nodrift: false,
            pitchvel: 0.0,
            driftmove: 0.0,
            stopped: false,
            mouse: {0.0, 0.0},
            cvars: %{}

  @type t :: %__MODULE__{}
  @type angles :: {float(), float(), float()}

  @doc """
  The console variables and their defaults: `cl_forwardspeed`, `cl_backspeed`,
  `cl_sidespeed`, `cl_upspeed` (400), `cl_yawspeed` (210), `cl_pitchspeed` (225),
  `cl_movespeedkey` (0.3), `m_yaw` (0.022), `m_side` (0.8), `m_forward` (1),
  `v_centermove` (0.15), `v_centerspeed` (500) and `mouse_counts` (955 counts a
  second).
  """
  @spec cvars() :: map()
  def cvars do
    %{
      cl_forwardspeed: 400.0,
      cl_backspeed: 400.0,
      cl_sidespeed: 400.0,
      cl_upspeed: 400.0,
      cl_yawspeed: 210.0,
      cl_pitchspeed: 225.0,
      cl_movespeedkey: 0.3,
      m_yaw: 0.022,
      m_side: 0.8,
      m_forward: 1.0,
      v_centermove: 0.15,
      v_centerspeed: 500.0,
      mouse_counts: 955.0
    }
  end

  @doc "A look with mouse look on, using `cvars` over `cvars/0`."
  @spec new(map()) :: t()
  def new(cvars \\ %{}), do: %__MODULE__{cvars: Map.merge(cvars(), cvars)}

  @doc "One tick of `dt` seconds; see the module documentation."
  @spec step(t(), map(), angles(), map(), map(), float()) ::
          {angles(), {float(), float(), float()}, t()}
  def step(%__MODULE__{} = look, input, {pitch, yaw, roll}, mouse, motion, dt) do
    look = %{look | stopped: false} |> mlook(input, mouse)
    {look, {pitch, yaw}, mouse_moves} = pointer(look, input, {pitch, yaw}, mouse, dt)
    {look, {pitch, yaw}} = keys(look, input, {pitch, yaw}, dt)
    {forward, side, up} = base_move(look, input)
    {mouse_forward, mouse_side} = mouse_moves
    {pitch, look} = drift(look, pitch, motion, dt)
    pitch = if pressed?(input, :center_view), do: 0.0, else: pitch |> max(-89.0) |> min(89.0)

    {{pitch, :math.fmod(:math.fmod(yaw, 360.0) + 360.0, 360.0), roll},
     {forward + mouse_forward, side + mouse_side, up}, look}
  end

  defp mlook(look, input, mouse) do
    cond do
      pressed?(input, :mouse_look) -> %{look | mlook: true}
      released?(input, :mouse_look) -> spring(%{look | mlook: false}, mouse.lookspring)
      true -> look
    end
  end

  defp spring(look, true), do: start_drift(look)
  defp spring(look, false), do: look

  defp pointer(look, input, {pitch, yaw}, mouse, dt) do
    counts = look.cvars.mouse_counts * dt
    mx = counts * (strength(input, :pointer_right) - strength(input, :pointer_left))
    my = counts * (strength(input, :pointer_down) - strength(input, :pointer_up))
    {old_x, old_y} = look.mouse
    {fx, fy} = if mouse.m_filter, do: {(mx + old_x) / 2, (my + old_y) / 2}, else: {mx, my}
    sens = mouse.sensitivity * Map.get(mouse, :scale, 1.0)
    {mouse_x, mouse_y} = {fx * sens, fy * sens}
    strafe? = held?(input, :strafe)
    strafe_x = strafe? or (mouse.lookstrafe and look.mlook)
    strafe_y = not (look.mlook and not strafe?)

    look =
      if look.mlook, do: stop_drift(%{look | mouse: {mx, my}}), else: %{look | mouse: {mx, my}}

    {side, yaw} =
      if strafe_x,
        do: {look.cvars.m_side * mouse_x, yaw},
        else: {0.0, yaw - look.cvars.m_yaw * mouse_x}

    {forward, pitch} =
      if strafe_y,
        do: {-look.cvars.m_forward * mouse_y, pitch},
        else: {0.0, pitch + mouse.m_pitch * mouse_y}

    {look, {pitch, yaw}, {forward, side}}
  end

  defp keys(look, input, {pitch, yaw}, dt) do
    turn = look.cvars.cl_yawspeed * dt
    tilt = look.cvars.cl_pitchspeed * dt

    yaw =
      if held?(input, :strafe),
        do: yaw,
        else: yaw - turn * strength(input, :turn_right) + turn * strength(input, :turn_left)

    {look, pitch} =
      if held?(input, :klook),
        do:
          {stop_drift(look),
           pitch - tilt * strength(input, :forward) + tilt * strength(input, :back)},
        else: {look, pitch}

    up = strength(input, :look_up)
    down = strength(input, :look_down)
    look = if up != 0 or down != 0, do: stop_drift(look), else: look
    {look, {pitch - tilt * up + tilt * down, yaw}}
  end

  defp base_move(look, input) do
    cvars = look.cvars
    scale = if held?(input, :walk), do: cvars.cl_movespeedkey, else: 1.0

    forward =
      if held?(input, :klook),
        do: 0.0,
        else:
          cvars.cl_forwardspeed * strength(input, :forward) -
            cvars.cl_backspeed * strength(input, :back)

    side =
      cvars.cl_sidespeed * (strength(input, :strafe_right) - strength(input, :strafe_left)) +
        strafe_turn(look, input)

    up = cvars.cl_upspeed * (strength(input, :swim_up) - strength(input, :swim_down))
    {forward * scale, side * scale, up * scale}
  end

  defp strafe_turn(look, input) do
    if held?(input, :strafe),
      do:
        look.cvars.cl_sidespeed *
          (strength(input, :turn_right) - strength(input, :turn_left)),
      else: 0.0
  end

  defp drift(look, pitch, %{onground: false}, _dt),
    do: {pitch, %{look | driftmove: 0.0, pitchvel: 0.0}}

  defp drift(%{nodrift: true} = look, pitch, motion, dt) do
    driftmove = if speed(motion.velocity) < 200, do: 0.0, else: look.driftmove + dt
    look = %{look | driftmove: driftmove}

    look =
      if driftmove > look.cvars.v_centermove, do: start_drift(look), else: look

    {pitch, look}
  end

  defp drift(look, pitch, _motion, dt) do
    move = dt * look.pitchvel
    look = %{look | pitchvel: look.pitchvel + dt * look.cvars.v_centerspeed}
    toward_level(look, pitch, -pitch, move)
  end

  defp toward_level(look, pitch, delta, _move) when delta == 0,
    do: {pitch, %{look | pitchvel: 0.0}}

  defp toward_level(look, pitch, delta, move) when delta > 0 and move > delta,
    do: {pitch + delta, %{look | pitchvel: 0.0}}

  defp toward_level(look, pitch, delta, move) when delta > 0, do: {pitch + move, look}

  defp toward_level(look, pitch, delta, move) when move > -delta,
    do: {pitch + delta, %{look | pitchvel: 0.0}}

  defp toward_level(look, pitch, _delta, move), do: {pitch - move, look}

  defp start_drift(%{stopped: true} = look), do: look

  defp start_drift(look) do
    if look.nodrift or look.pitchvel == 0,
      do: %{look | pitchvel: look.cvars.v_centerspeed, nodrift: false, driftmove: 0.0},
      else: look
  end

  defp stop_drift(look), do: %{look | stopped: true, nodrift: true, pitchvel: 0.0}

  defp speed({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  defp held?(input, action), do: MapSet.member?(input.held, action)

  defp pressed?(input, action),
    do: held?(input, action) and not MapSet.member?(input.previous, action)

  defp released?(input, action),
    do: MapSet.member?(input.previous, action) and not held?(input, action)

  defp strength(input, action) do
    if held?(input, action),
      do: Map.get(input.strength, action, 1.0),
      else: 0.0
  end
end
