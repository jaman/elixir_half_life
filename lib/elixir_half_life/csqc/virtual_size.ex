defmodule ElixirHalfLife.Csqc.VirtualSize do
  @moduledoc """
  The 2D size the client and menu programs draw in (FTE's `vid.width` by `vid.height`)
  for a picture of `width` by `height` pixels, as FTE's `R2D_Console_Resize` works it
  out from the console variables:

    * `vid_conautoscale` (default 0): above 0, the pixel size divided by it (a second
      number divides the height), in place of the two below
    * `vid_conwidth`, `vid_conheight` (default 0): the size; one left at 0 follows the
      other by the picture's shape
    * with both 0, `vid_baseheight` (up to four heights, default none): the picture's
      height halved while it stays at least the largest of them that is below the
      picture's height and at least `vid_minsize`'s height; with none, 480
    * `vid_minsize` (default `320 200`): the least size, and never below 320 by 200

  The picture's shape counts its pixels as `aspect` times as tall as wide, so a square
  in the 2D size is square on the screen.

      ElixirHalfLife.Csqc.VirtualSize.size(csqc, 320, 200, 1.0)
      #=> {768, 480}
  """

  alias QuakeServer.Server

  @doc "The 2D size for a picture of `width` by `height` pixels each `aspect` times as tall as wide."
  @spec size(map(), pos_integer(), pos_integer(), number()) :: {pos_integer(), pos_integer()}
  def size(host, width, height, aspect) do
    shown = height * aspect
    {xratio, yratio, width_set, height_set} = autoscale(host, width, shown)
    minimum = numbers(cvar(host, "vid_minsize", "320 200"), 2)

    {cwidth, cheight} =
      {width_set, height_set}
      |> unset(host, shown, Enum.at(minimum, 1))
      |> follow(width, shown)

    cwidth = trunc(cwidth * xratio) |> max(trunc(Enum.at(minimum, 0))) |> max(320)
    cheight = trunc(cheight * yratio) |> max(trunc(Enum.at(minimum, 1))) |> max(200)
    {cwidth, cheight}
  end

  defp autoscale(host, width, shown) do
    text = cvar(host, "vid_conautoscale", "0")

    case numbers(text, 2) do
      [x, y] when x > 0 ->
        y = if y <= 0, do: x, else: y
        {1 / x, 1 / y, width, trunc(shown)}

      _ ->
        {1.0, 1.0, trunc(number(host, "vid_conwidth")), trunc(number(host, "vid_conheight"))}
    end
  end

  defp unset({0, 0}, host, shown, least_height) do
    biggest =
      host
      |> cvar("vid_baseheight", "")
      |> numbers(4)
      |> Enum.filter(&(&1 < shown and &1 >= least_height))
      |> Enum.max(fn -> 0 end)

    {0, if(biggest > 0, do: halved(trunc(shown), biggest), else: 480)}
  end

  defp unset(set, _host, _shown, _least_height), do: set

  defp halved(height, biggest) when div(height, 2) >= biggest, do: halved(div(height, 2), biggest)
  defp halved(height, _biggest), do: height

  defp follow({0, cheight}, width, shown) when cheight != 0 and shown > 0,
    do: {trunc(cheight * width / shown), cheight}

  defp follow({cwidth, 0}, width, shown) when cwidth != 0 and width > 0,
    do: {cwidth, trunc(cwidth * shown / width)}

  defp follow({0, 0}, width, shown), do: {width, trunc(shown)}
  defp follow(set, _width, _shown), do: set

  defp cvar(host, name, default),
    do: if(Server.cvar?(host, name), do: Server.cvar_string(host, name), else: default)

  defp number(host, name),
    do: if(Server.cvar?(host, name), do: Server.cvar(host, name), else: 0.0)

  defp numbers(text, count) do
    parsed =
      text
      |> String.split()
      |> Enum.map(fn word ->
        case Float.parse(word) do
          {value, _} -> value
          :error -> 0.0
        end
      end)

    Enum.take(parsed ++ List.duplicate(0.0, count), count)
  end
end
