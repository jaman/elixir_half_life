defmodule ElixirHalfLife.Menu do
  @moduledoc """
  The in-game menu: FreeHL's Configuration pages (`ElixirHalfLife.Menu.Pages`) as the
  player moves through them, changing the settings `Cauldron2D.Client.Game`'s
  `menu_event/3` keeps.

      menu = ElixirHalfLife.Menu.open(settings)
      %{menu: menu, settings: settings} = ElixirHalfLife.Menu.event(menu, {:key, :down}, settings)

  `event/3` returns what `menu_event/3` returns; the menu holds the settings it shows
  (`:settings`). Keys: `↑`/`↓` (and the wheel) move, `Enter` (and the left button)
  chooses, `←`/`→` change a switch, slider or choice, `Esc` (and the right button) goes
  back to the page before, closing the menu from the main page. On a key binding
  `Enter` waits for a key, mouse button or wheel notch to bind to the action — `Esc`
  cancels, `Backspace` clears the action — and `Backspace` or `Delete` clears it at
  once. A key bound to an action is taken from any other, and an action that has two
  keys loses both before the new one is added, as FreeHL's controls page binds. Use
  defaults puts back the bindings of the settings' preset. Quit asks first, then leaves
  the world. Options change in the settings' `:options` (`ElixirHalfLife.Options`), the
  sound effect volume in `:sfx`.
  """

  alias Cauldron2D.Input
  alias ElixirHalfLife.Menu.Pages
  alias ElixirHalfLife.Options

  defstruct page: :main, cursor: %{}, grab: nil, settings: %{}

  @type t :: %__MODULE__{
          page: atom(),
          cursor: %{atom() => non_neg_integer()},
          grab: atom() | nil,
          settings: map()
        }

  @doc "The menu as the menu key opens it: the main page."
  @spec open(map()) :: t()
  def open(settings), do: %__MODULE__{settings: settings}

  @doc "The cursor's place on the menu's page."
  @spec cursor(t()) :: non_neg_integer()
  def cursor(%__MODULE__{} = menu), do: Map.get(menu.cursor, menu.page, first(menu.page))

  @doc "Take one event; see the module documentation for what comes back."
  @spec event(t(), term(), map()) :: map()
  def event(%__MODULE__{grab: action} = menu, event, settings) when action != nil,
    do: grab(menu, action, event, settings)

  def event(%__MODULE__{} = menu, event, settings) do
    case key_of(event) do
      nil -> stay(menu, settings)
      key -> key(menu.page, key, menu, settings)
    end
  end

  defp key_of({:key, key}), do: key
  defp key_of({:key, key, _mods}), do: key
  defp key_of({:mouse, %{type: :scroll, direction: :up}}), do: :up
  defp key_of({:mouse, %{type: :scroll, direction: :down}}), do: :down
  defp key_of({:mouse, %{type: :mouse_down, button: :left}}), do: :enter
  defp key_of({:mouse, %{type: :mouse_down, button: :right}}), do: :escape
  defp key_of(_event), do: nil

  defp key(:quit, key, _menu, settings) when key in [:enter, :y],
    do: %{menu: nil, settings: settings, leave: true, sounds: [sound("launch_select2.wav")]}

  defp key(:quit, _key, menu, settings), do: back(menu, settings)
  defp key(_page, :escape, menu, settings), do: back(menu, settings)
  defp key(_page, :up, menu, settings), do: move(menu, -1, settings)
  defp key(_page, :down, menu, settings), do: move(menu, 1, settings)
  defp key(_page, :enter, menu, settings), do: choose(item(menu), menu, settings)
  defp key(_page, :left, menu, settings), do: change(item(menu), -1, menu, settings)
  defp key(_page, :right, menu, settings), do: change(item(menu), 1, menu, settings)

  defp key(_page, clear, menu, settings) when clear in [:backspace, :delete],
    do: clear(item(menu), menu, settings)

  defp key(_page, _key, menu, settings), do: stay(menu, settings)

  defp back(menu, settings) do
    case Pages.parent(menu.page) do
      nil -> %{menu: nil, settings: settings, sounds: [sound("launch_dnmenu1.wav")]}
      parent -> stay(%{menu | page: parent}, settings, "launch_dnmenu1.wav")
    end
  end

  defp item(menu), do: Enum.at(Pages.items(menu.page), cursor(menu))

  defp move(menu, step, settings) do
    items = Pages.items(menu.page)
    next = next_choosable(items, cursor(menu), step, length(items))
    stay(%{menu | cursor: Map.put(menu.cursor, menu.page, next)}, settings)
  end

  defp next_choosable(_items, at, _step, 0), do: at

  defp next_choosable(items, at, step, left) do
    next = Integer.mod(at + step, length(items))

    if Pages.choosable?(Enum.at(items, next)),
      do: next,
      else: next_choosable(items, next, step, left - 1)
  end

  defp first(page),
    do: Pages.items(page) |> Enum.find_index(&Pages.choosable?/1) |> Kernel.||(0)

  defp choose({:open, _label, page}, menu, settings),
    do: stay(%{menu | page: page}, settings, "launch_upmenu1.wav")

  defp choose({:done, _label}, menu, settings), do: back(menu, settings)

  defp choose({:resume, _label}, _menu, settings),
    do: %{menu: nil, settings: settings, sounds: [sound("launch_select2.wav")]}

  defp choose({:quit, _label}, menu, settings),
    do: stay(%{menu | page: :quit}, settings, "launch_upmenu1.wav")

  defp choose({:defaults, _label}, menu, settings),
    do: stay(menu, defaults(settings), "launch_select2.wav")

  defp choose({:bind, _label, action}, menu, settings),
    do: stay(%{menu | grab: action}, settings, "launch_select2.wav")

  defp choose({:check, _label, _option} = item, menu, settings),
    do: change(item, 1, menu, settings)

  defp choose(_item, menu, settings), do: stay(menu, settings)

  defp change({:check, _label, option}, _step, menu, settings),
    do:
      stay(menu, put_option(settings, option, not option(settings, option)), "launch_select2.wav")

  defp change({:slider, _label, option, {low, high, step}}, direction, menu, settings) do
    value = option(settings, option) + direction * step
    value = value |> max(low) |> min(high) |> round_like(step)
    stay(menu, put_option(settings, option, value), "launch_select2.wav")
  end

  defp change({:choice, _label, option, choices}, direction, menu, settings) do
    index = Enum.find_index(choices, &(&1 == option(settings, option))) || 0
    value = Enum.at(choices, (index + direction) |> max(0) |> min(length(choices) - 1))
    stay(menu, put_option(settings, option, value), "launch_select2.wav")
  end

  defp change({:volume, _label}, direction, menu, settings) do
    level = (settings.sfx + direction * 0.05) |> max(0.0) |> min(1.0) |> Float.round(2)
    stay(menu, %{settings | sfx: level}, "launch_select2.wav")
  end

  defp change(_item, _direction, menu, settings), do: stay(menu, settings)

  defp clear({:bind, _label, action}, menu, settings),
    do: stay(menu, unbind(settings, action), "launch_select2.wav")

  defp clear(_item, menu, settings), do: stay(menu, settings)

  defp round_like(value, step) when is_integer(step), do: round(value)
  defp round_like(value, _step), do: Float.round(value / 1, 2)

  defp option(settings, option), do: Map.fetch!(Options.complete(settings.options), option)

  defp put_option(settings, option, value),
    do: %{settings | options: Map.put(Options.complete(settings.options), option, value)}

  defp defaults(settings) do
    keymaps = ElixirHalfLife.Client.keymaps()

    %{
      settings
      | bindings: Keyword.get(keymaps, settings.preset, Keyword.fetch!(keymaps, :keyboard))
    }
  end

  defp grab(menu, action, event, settings) do
    case {key_of_grab(event), Input.spec_of(event)} do
      {:escape, _spec} ->
        stay(%{menu | grab: nil}, settings)

      {:backspace, _spec} ->
        stay(%{menu | grab: nil}, unbind(settings, action))

      {_key, nil} ->
        stay(menu, settings)

      {_key, spec} ->
        stay(%{menu | grab: nil}, bind(settings, action, spec), "launch_select2.wav")
    end
  end

  defp key_of_grab({:key, key}), do: key
  defp key_of_grab({:key, key, _mods}), do: key
  defp key_of_grab(_event), do: nil

  defp bind(settings, action, spec) do
    freed = Map.new(settings.bindings, fn {other, keys} -> {other, List.delete(keys, spec)} end)
    keys = Map.get(freed, action, [])
    keys = if length(keys) >= 2, do: [], else: keys
    %{settings | bindings: Map.put(freed, action, keys ++ [spec])}
  end

  defp unbind(settings, action),
    do: %{settings | bindings: Map.put(settings.bindings, action, [])}

  defp stay(menu, settings), do: %{menu: %{menu | settings: settings}, settings: settings}

  defp stay(menu, settings, name),
    do: %{menu: %{menu | settings: settings}, settings: settings, sounds: [sound(name)]}

  defp sound(name), do: {:menu_sound, name}
end
