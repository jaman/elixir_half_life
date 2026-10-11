defmodule ElixirHalfLife.Csqc.ServerParticles do
  @moduledoc """
  The server's particle messages run on the client's particle effects
  (`ElixirHalfLife.Csqc.Particles`), as FTE's client runs them
  (`CL_ParsePointParticles`, `CL_ParseTrailParticles`). The effect is the one the server
  named by that number (`ElixirHalfLife.Csqc.Precaches`); a number it never named runs
  nothing.

  A point effect further than the console variable `cl_part_density_fade_start` (default
  1024) from the listener has its count cut by the distance past that over
  `cl_part_density_fade` (default 1024, 0 for no cutting), and runs nothing once the
  count falls below 0. A trail from server entity `n` above 0 keeps its spacing from
  message to message under entity `-n`, apart from the client's own entities.

      csqc = ElixirHalfLife.Csqc.ServerParticles.point(csqc, 3, origin, {0.0, 0.0, 0.0}, 1)
  """

  alias Cauldron3D.Vec
  alias ElixirHalfLife.Csqc.{Particles, Precaches, Sounds}
  alias QuakeServer.Server

  @doc "Run server effect `number` at `origin` toward `direction`, `count` times as many."
  @spec point(Server.t(), non_neg_integer(), Vec.t(), Vec.t(), number()) :: Server.t()
  def point(csqc, number, origin, direction, count) do
    with name when is_binary(name) <- Precaches.effect(csqc, number),
         count when count >= 0 <- faded(csqc, origin, count) do
      Particles.point(csqc, name, origin, direction, count)
    else
      _ -> csqc
    end
  end

  @doc "Run server trail effect `number` from `from` to `to` for server entity `entity` (0 for none)."
  @spec trail(Server.t(), non_neg_integer(), non_neg_integer(), Vec.t(), Vec.t()) :: Server.t()
  def trail(csqc, number, entity, from, to) do
    case Precaches.effect(csqc, number) do
      nil -> csqc
      name -> Particles.trail(csqc, name, -entity, from, to)
    end
  end

  defp faded(csqc, origin, count) do
    start = cvar(csqc, "cl_part_density_fade_start", 1024.0)
    fade = cvar(csqc, "cl_part_density_fade", 1024.0)
    distance = Vec.length(Vec.sub(origin, Sounds.listener_origin(csqc)))

    if fade > 0 and distance > start,
      do: count - (distance - start) / fade,
      else: count
  end

  defp cvar(csqc, name, default),
    do: if(Server.cvar?(csqc, name), do: Server.cvar(csqc, name), else: default)
end
