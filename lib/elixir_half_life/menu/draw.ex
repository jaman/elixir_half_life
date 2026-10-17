defmodule ElixirHalfLife.Menu.Draw do
  @moduledoc """
  The in-game menu drawn over a picture, in FreeHL's menu colours and its label face
  (`fonts/nimbus/NimbusSanL-Reg.otf`, `ElixirHalfLife.Csqc.Fonts.Font`): the picture
  dimmed, the page's title, its items with their switches, sliders, choices and key
  bindings, the item under the cursor in the selected colour, and a line of help. Rows
  are an eighteenth of the picture's height, at least 11 pixels; a page with more
  items than fit scrolls to keep the cursor in sight.

  A picture whose alpha is below 255 (its colours already multiplied by it) has its alpha
  raised by what the menu lays over it, as `ElixirHalfLife.Csqc.Screen` keeps it: dimming
  lays black over it at two thirds.

      frame = ElixirHalfLife.Menu.Draw.over(menu, frame)
  """

  alias Cauldron3D.Frame
  alias ElixirHalfLife.Csqc.Fonts.Font
  alias ElixirHalfLife.Menu
  alias ElixirHalfLife.Menu.Pages
  alias ElixirHalfLife.Options

  @face "fonts/nimbus/NimbusSanL-Reg.otf"
  @bold "fonts/nimbus/NimbusSanL-Bol.otf"
  @label {247, 181, 56}
  @selected {255, 0, 0}
  @white {255, 255, 255}
  @help {128, 128, 128}
  @list {255, 128, 26}
  @list_selected {84, 45, 0}
  @prompt {240, 181, 23}
  @prompt_back {56, 56, 56}

  @doc "`frame`, an RGBA `Cauldron3D.Frame`, with `menu` drawn over it."
  @spec over(Menu.t(), Frame.t()) :: Frame.t()
  def over(%Menu{} = menu, %Frame{} = frame) do
    row = max(11, div(frame.height, 18))
    layout = %{row: row, left: div(frame.width, 14), font: Font.load(@face, row - 1, %{})}

    frame
    |> dim()
    |> text(Font.load(@bold, row + 3, %{}), Pages.title(menu.page), {layout.left, row}, @white)
    |> page(menu.page, menu, layout)
  end

  defp page(frame, :quit, _menu, layout) do
    frame
    |> text(layout.font, "Are you sure you want to quit?", {layout.left, layout.row * 4}, @prompt)
    |> text(layout.font, "Enter: quit    Esc: stay", {layout.left, layout.row * 6}, @help)
  end

  defp page(frame, name, menu, layout) do
    items = Pages.items(name)
    cursor = Menu.cursor(menu)
    top = layout.row * 3
    fits = max(div(frame.height - top - layout.row * 2, layout.row), 1)
    first = (cursor - fits + 1) |> max(0) |> min(max(length(items) - fits, 0))

    items
    |> Enum.with_index()
    |> Enum.slice(first, fits)
    |> Enum.reduce(frame, fn {item, index}, acc ->
      y = top + (index - first) * layout.row
      item_row(acc, item, index == cursor, y, menu, layout)
    end)
    |> help(menu, Enum.at(items, cursor), layout)
  end

  defp item_row(frame, {:heading, label}, _selected?, y, _menu, layout),
    do: text(frame, layout.font, label, {layout.left, y}, @white)

  defp item_row(frame, {:bind, label, action}, selected?, y, menu, layout) do
    keys = Map.get(menu.settings.bindings, action, [])
    {first, second} = {Enum.at(keys, 0), Enum.at(keys, 1)}

    frame =
      if selected?,
        do:
          fill(
            frame,
            {layout.left, y},
            {frame.width - layout.left * 2, layout.row},
            @list_selected
          ),
        else: frame

    frame
    |> text(layout.font, label, {layout.left + layout.row, y}, @list)
    |> text(layout.font, key_text(first), {div(frame.width, 2), y}, @list)
    |> text(layout.font, key_text(second), {div(frame.width * 3, 4), y}, @list)
  end

  defp item_row(frame, item, selected?, y, menu, layout) do
    colour = if selected?, do: @selected, else: @label

    frame
    |> text(layout.font, elem(item, 1), {layout.left, y}, colour)
    |> value(item, {div(frame.width, 2), y}, menu.settings, layout)
  end

  defp value(frame, {:check, _label, option}, at, settings, layout),
    do: text(frame, layout.font, if(option(settings, option), do: "[x]", else: "[ ]"), at, @white)

  defp value(frame, {:slider, _label, option, {low, high, _step}}, at, settings, layout),
    do:
      slider(frame, (option(settings, option) - low) / (high - low), at, settings, option, layout)

  defp value(frame, {:choice, _label, option, _choices}, at, settings, layout),
    do:
      text(frame, layout.font, "< #{choice_text(option, option(settings, option))} >", at, @white)

  defp value(frame, {:volume, _label}, at, settings, layout),
    do: slider(frame, settings.sfx, at, settings, :sfx, layout)

  defp value(frame, _item, _at, _settings, _layout), do: frame

  defp slider(frame, fraction, {x, y}, settings, option, layout) do
    length = div(frame.width, 4)
    bar_y = y + div(layout.row, 2) - 1
    knob = x + round(fraction * (length - 3))

    frame
    |> fill({x, bar_y - 1}, {length, 4}, {64, 64, 64})
    |> fill({x + 1, bar_y}, {length - 2, 2}, {0, 0, 0})
    |> fill({knob, bar_y - 2}, {3, 6}, @label)
    |> text(
      layout.font,
      number_text(option, slider_value(settings, option)),
      {x + length + layout.row, y},
      @white
    )
  end

  defp slider_value(settings, :sfx), do: settings.sfx
  defp slider_value(settings, option), do: option(settings, option)

  defp number_text(:fov, value), do: "#{value}°"
  defp number_text(_option, value) when is_integer(value), do: Integer.to_string(value)
  defp number_text(_option, value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp choice_text(:picture_width, width), do: "#{width} pixels across"
  defp choice_text(_option, value), do: to_string(value)

  defp help(frame, %Menu{grab: action}, _item, layout) when action != nil do
    label = bind_label(action)
    y = frame.height - layout.row * 3

    frame
    |> fill(
      {layout.left, y - 2},
      {frame.width - layout.left * 2, layout.row * 2 + 4},
      @prompt_back
    )
    |> text(layout.font, "Press a key or button for:", {layout.left + 4, y}, @prompt)
    |> text(layout.font, label <> "   (Esc cancels)", {layout.left + 4, y + layout.row}, @white)
  end

  defp help(frame, _menu, item, layout),
    do:
      text(
        frame,
        layout.font,
        help_text(item),
        {layout.left, frame.height - layout.row - 2},
        @help
      )

  defp help_text({:bind, _label, _action}), do: "Enter to change, Backspace to clear"
  defp help_text({:slider, _label, _option, _range}), do: "Left and right to change"
  defp help_text({:volume, _label}), do: "Left and right to change"

  defp help_text({:choice, _label, :picture_width, _choices}),
    do: "How many pixels across the game is drawn"

  defp help_text({:choice, _label, _option, _choices}), do: "Left and right to change"
  defp help_text({:check, _label, _option}), do: "Enter to switch"
  defp help_text(_item), do: "Esc to go back"

  defp bind_label(action) do
    Enum.find_value(Pages.items(:controls), to_string(action), fn
      {:bind, label, ^action} -> label
      _item -> nil
    end)
  end

  defp option(settings, option), do: Map.fetch!(Options.complete(settings.options), option)

  defp key_text(nil), do: ""

  defp key_text({:mouse, button}),
    do: "mouse " <> String.replace(Atom.to_string(button), "_", " ")

  defp key_text({key, mods}),
    do: Enum.map_join(mods, "+", &Atom.to_string/1) <> "+" <> key_text(key)

  defp key_text(:" "), do: "space"
  defp key_text(key), do: key |> Atom.to_string() |> String.replace("_", " ")

  defp dim(frame) do
    pixels =
      for <<r, g, b, a <- frame.pixels>>,
        into: <<>>,
        do: <<div(r, 3), div(g, 3), div(b, 3), 255 - div(255 - a, 3)>>

    %{frame | pixels: pixels}
  end

  defp fill(frame, {x, y}, {w, h}, {r, g, b}) when w > 0 and h > 0,
    do:
      Frame.blit(
        frame,
        %{width: w, height: h, pixels: :binary.copy(<<r, g, b, 255>>, w * h)},
        {x, y}
      )

  defp fill(frame, _at, _size, _colour), do: frame

  defp text(frame, _font, "", _at, _colour), do: frame

  defp text(frame, font, string, {x, y}, colour) do
    glyphs =
      for codepoint <- String.to_charlist(string),
          char = Font.char(font, codepoint),
          char != nil,
          do: char

    height = font.charheight
    width = glyphs |> Enum.map(&max(&1.advance, 0)) |> Enum.sum()

    if width > 0,
      do:
        stamp(
          frame,
          %{width: width, height: height, pixels: strip(glyphs, height, colour)},
          {x, y}
        ),
      else: frame
  end

  defp stamp(frame, strip, {left, top}) do
    rows = max(min(top + strip.height, frame.height) - max(top, 0), 0)
    first = max(left, 0)
    span = min(left + strip.width, frame.width) - first

    if rows == 0 or span <= 0,
      do: frame,
      else: %{frame | pixels: stamped(frame, strip, {left, top}, first, span)}
  end

  defp stamped(frame, strip, {left, top}, first, span) do
    row_bytes = frame.width * 4

    for y <- 0..(frame.height - 1), into: <<>> do
      row = binary_part(frame.pixels, y * row_bytes, row_bytes)

      if y < top or y >= top + strip.height do
        row
      else
        under = binary_part(row, first * 4, span * 4)
        above = binary_part(strip.pixels, ((y - top) * strip.width + first - left) * 4, span * 4)

        binary_part(row, 0, first * 4) <>
          lay(under, above) <>
          binary_part(row, (first + span) * 4, row_bytes - (first + span) * 4)
      end
    end
  end

  defp lay(under, above) do
    for {<<ur, ug, ub, ua>>, <<r, g, b, a>>} <- Enum.zip(words(under), words(above)),
        into: <<>> do
      <<div(r * a + ur * (255 - a), 255), div(g * a + ug * (255 - a), 255),
        div(b * a + ub * (255 - a), 255), 255 - div((255 - ua) * (255 - a), 255)>>
    end
  end

  defp words(binary), do: for(<<word::binary-4 <- binary>>, do: word)

  defp strip(glyphs, height, {r, g, b}) do
    cells = Enum.map(glyphs, &cell(&1, height))

    for row <- 0..(height - 1), cell <- cells, into: <<>> do
      for alpha <- elem(cell, row), into: <<>>, do: <<r, g, b, alpha>>
    end
  end

  defp cell(%{advance: advance} = char, height) do
    cover = coverage(char, height)

    for row <- 0..(height - 1) do
      for column <- 0..(max(advance, 0) - 1)//1, do: cover.(column, row)
    end
    |> List.to_tuple()
  end

  defp coverage(%{texture: nil}, _height), do: fn _x, _y -> 0 end

  defp coverage(%{plane: :grid} = char, height),
    do: sampled(char, {0, 0}, {height, height})

  defp coverage(char, _height), do: sampled(char, {char.left, char.top}, {char.bmw, char.bmh})

  defp sampled(%{texture: texture} = char, {left, top}, {width, height}) do
    sx = char.s0 * texture.width
    sy = char.t0 * texture.height
    sw = (char.s1 - char.s0) * texture.width
    sh = (char.t1 - char.t0) * texture.height

    fn x, y ->
      gx = x - left
      gy = y - top

      if gx < 0 or gy < 0 or gx >= width or gy >= height or width <= 0 or height <= 0,
        do: 0,
        else: alpha(texture, trunc(sx + gx * sw / width), trunc(sy + gy * sh / height))
    end
  end

  defp alpha(texture, x, y) when x >= 0 and y >= 0 and x < texture.width and y < texture.height,
    do: :binary.at(texture.pixels, (y * texture.width + x) * 4 + 3)

  defp alpha(_texture, _x, _y), do: 0
end
