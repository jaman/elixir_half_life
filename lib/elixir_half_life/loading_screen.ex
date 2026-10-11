defmodule ElixirHalfLife.LoadingScreen do
  @moduledoc """
  The picture shown while a level loads: the last picture of the game as it stood (black
  when there is none yet), with FreeHL's "LOADING..." picture (`gfx/loading`, 64 by 64
  in 2D units) drawn over its middle. Nothing else is drawn over the scene.

      {frame, menu} = ElixirHalfLife.LoadingScreen.beginning(menu, nil, 320, 200, {768, 480})

  `menu` is any host with a QuakeC memory to draw through (the menu program), `view` the
  game's picture of that size or `nil`, and the last argument the 2D size the picture
  stands for.
  """

  alias ElixirHalfLife.Csqc.Screen
  alias QuakeServer.Server

  @type size :: {pos_integer(), pos_integer()}

  @doc "The loading picture over `view`, or over black when it is `nil`."
  @spec beginning(
          Server.t(),
          Cauldron3D.Frame.t() | nil,
          pos_integer(),
          pos_integer(),
          size()
        ) :: {Cauldron3D.Frame.t(), Server.t()}
  def beginning(menu, view, width, height, {vw, vh} = virtual) do
    qc =
      menu.qc
      |> QuakeC.put_slot_vector(4, {vw / 2 - 32.0, vh / 2 - 32.0, 0.0})
      |> QuakeC.put_slot(7, "gfx/loading")
      |> QuakeC.put_slot_vector(10, {64.0, 64.0, 0.0})
      |> QuakeC.put_slot_vector(13, {1.0, 1.0, 1.0})
      |> QuakeC.put_slot(16, 1.0)

    menu =
      %{menu | qc: qc}
      |> Screen.begin(width, height, virtual)
      |> under(view)
      |> Screen.call(322, 5)

    {Screen.frame(menu), menu}
  end

  defp under(menu, nil), do: menu
  defp under(menu, view), do: Screen.put_frame(menu, view)
end
