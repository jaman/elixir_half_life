defmodule ElixirHalfLife.CommandClock do
  @moduledoc """
  When the client sends the player's command and how many milliseconds it covers, as
  FTE's `CL_SendCmd` works it out over QuakeWorld: each frame adds its time to the time
  banked; at most `cl_netfps` commands a second are sent (bounded by the server's
  `maxfps`, 72 when the server gives none or less than 20, and never below 6.7 a second),
  each covering a whole number of milliseconds with the fraction carried to the next,
  at most 200 (above 100 a multiple of 4, above 50 a multiple of 2), and more than one
  and a half sends' worth of banked time is dropped. A `cl_netfps` of 0 or less sends
  every frame.

      clock = ElixirHalfLife.CommandClock.new()
      {:send, 13, clock} = ElixirHalfLife.CommandClock.tick(clock, 0.016, 150.0, 72.0)

  `tick/4` returns `{:send, msec, clock}` when a command goes out covering `msec`
  milliseconds, `{:hold, msec, clock}` when the command is kept to be sent later,
  having covered `msec` milliseconds so far, and `{:none, 0, clock}` when no time has
  passed.
  """

  @enforce_keys [:banked, :carried]
  defstruct banked: 0.0, carried: 0.0

  @type t :: %__MODULE__{banked: float(), carried: float()}

  @limit 1.5

  @doc "A clock with nothing banked."
  @spec new() :: t()
  def new, do: %__MODULE__{banked: 0.0, carried: 0.0}

  @doc """
  Bank `seconds` more and decide on the command, sending at most `netfps` a second to a
  server whose `maxfps` is `maxfps` (FTE's `cls.maxfps`: 0 for none).
  """
  @spec tick(t(), number(), number(), number()) :: {:send | :hold | :none, number(), t()}
  def tick(%__MODULE__{} = clock, seconds, netfps, maxfps) do
    banked = clock.banked + seconds * 1000
    {send?, usetime, msec, clock} = take(%{clock | banked: banked}, netfps, server_fps(maxfps))
    msec = msec |> min(200) |> aligned()
    send? = send? and msec > 0

    cond do
      usetime <= 0 -> {:none, 0, clock}
      send? -> {:send, msec, %{clock | banked: clock.banked - msec}}
      true -> {:hold, msec, clock}
    end
  end

  defp take(clock, netfps, fpscap) when netfps > 0 do
    spare = spare(clock.banked, netfps, fpscap)
    usetime = clock.carried + (clock.banked - spare)
    msec = trunc(usetime)

    if spare == 0,
      do: {false, usetime, msec, clock},
      else: {true, usetime, msec, %{clock | carried: usetime - msec, banked: spare + msec}}
  end

  defp take(clock, _netfps, _fpscap) do
    usetime = clock.carried + clock.banked
    msec = trunc(usetime)
    {true, usetime, msec, %{clock | carried: usetime - msec}}
  end

  defp spare(banked, netfps, fpscap) do
    fps = netfps |> max(6.7) |> min(fpscap)
    slot = 1000 / fps

    cond do
      banked < Float.ceil(slot) -> 0
      banked - slot > slot * @limit -> slot * @limit
      true -> banked - slot
    end
  end

  defp server_fps(maxfps) when maxfps < 20, do: 72.0
  defp server_fps(maxfps), do: max(30.0, maxfps / 1)

  defp aligned(msec) when msec > 100, do: Bitwise.band(msec, Bitwise.bnot(3))
  defp aligned(msec) when msec > 50, do: Bitwise.band(msec, Bitwise.bnot(1))
  defp aligned(msec), do: msec
end
