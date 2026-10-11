defmodule ElixirHalfLife.Csqc.Consoles do
  @moduledoc """
  FTE's sub-consoles for the client and menu programs (`con_getset` 391, `con_printf`
  392, `con_draw` 393, `con_input` 394), kept by name in the host's `ext.consoles`, in
  the order they were made. The names `current` and `head` stand for the first console.

    * `con_printf(name, format, ...)` formats as `sprintf` and prints into the console,
      making it (titled with its name) when there is none: `\\n` ends a line, `\\r`
      starts the line again with the next character; a console keeps at most
      `con_maxlines` lines (1024 by default), dropping the oldest. Printing marks the
      console's text unseen.
    * `con_getset(name, field, value)` gives a field's old value as text (null for a
      console that does not exist) and sets it when `value` is given: `title`, `name`
      (set only when both are not empty), `next` (the next console's name, read only),
      `unseen`, `markup` (0 none, 1 parsed, 2 shown as written), `forceutf8`, `close`
      (non-zero removes the console; gives `0`), `clear` (gives `1` when empty;
      non-zero empties it), `hidden`, `linecount` (sets the unseen value, as FTE does)
      and `backimage`/`backvideomap` (the picture behind it).
    * `con_draw(name, position, size, fontsize)` draws the console's lines, newest at the
      bottom, scrolled back as `con_input` left it (`ElixirHalfLife.Csqc.Text.console/4`).
    * `con_input(name, event, a, b)` takes an input event: key down (0) with QuakeC key
      `a` scrolls back two lines on page up, the keypad's page up or the wheel up, forward
      on their downward keys, and returns 1; a right click on the top eight units removes
      the console; a click returns 1; any other key returns 0. Key up (1) returns 0. An
      absolute mouse position (3) is kept and returns 1. Focus (5) sets whether the
      console has the keyboard when `b` is 0 or more, returning 1.
  """

  alias ElixirHalfLife.Csqc.Text
  alias QuakeServer.{Args, Cvars, Keys}
  alias QuakeServer.Extensions.Format

  @scroll_up [:pgup, :kp_pgup, :mwheelup, :gp_left_thumb_up]
  @scroll_down [:pgdn, :kp_pgdn, :mwheeldown, :gp_left_thumb_down]
  @clicks [:touchtap, :touchslide, :touchlong, :mouse1, :mouse2]

  @doc "The builtins this module runs."
  @spec builtins() :: [integer()]
  def builtins, do: [391, 392, 393, 394]

  @doc "Run sub-console builtin `builtin`, one of `builtins/0`."
  @spec call(map(), integer(), non_neg_integer()) :: map()
  def call(s, 392, argc) do
    name = Args.str(s, 0)
    text = Format.sprintf(s, Args.str(s, 1), 2, argc)

    case find(s, name) do
      nil when name in ["current", "head"] -> s
      nil -> s |> put(new(name)) |> print(name, text)
      console -> print(s, console.name, text)
    end
  end

  def call(s, 391, argc) do
    value = if argc > 2, do: Args.str(s, 2), else: nil

    case find(s, Args.str(s, 0)) do
      nil -> Args.return(s, 0)
      console -> field(s, console, Args.str(s, 1), value)
    end
  end

  def call(s, 393, _argc) do
    case find(s, Args.str(s, 0)) do
      nil ->
        s

      console ->
        {x, y, _} = Args.vec(s, 1)
        {w, h, _} = Args.vec(s, 2)
        Text.console(s, visible(console), {x, y, w, h}, Args.num(s, 3))
    end
  end

  def call(s, 394, _argc) do
    case find(s, Args.str(s, 0)) do
      nil -> Args.return(s, 0.0)
      console -> input(s, console, Args.int(s, 1), Args.num(s, 2), Args.num(s, 3))
    end
  end

  defp new(name) do
    %{
      name: name,
      title: name,
      lines: [],
      current: "",
      cr: false,
      unseen: false,
      markup: 1,
      forceutf8: false,
      hidden: false,
      focused: false,
      backimage: "",
      scroll: 0,
      mouse: {0.0, 0.0}
    }
  end

  defp consoles(s), do: Map.get(s.ext, :consoles, [])

  defp find(s, name) when name in ["current", "head"], do: List.first(consoles(s))
  defp find(s, name), do: Enum.find(consoles(s), &(&1.name == name))

  defp put(s, console) do
    consoles = consoles(s)

    consoles =
      if Enum.any?(consoles, &(&1.name == console.name)),
        do: Enum.map(consoles, &if(&1.name == console.name, do: console, else: &1)),
        else: consoles ++ [console]

    %{s | ext: Map.put(s.ext, :consoles, consoles)}
  end

  defp remove(s, console),
    do: %{
      s
      | ext: Map.put(s.ext, :consoles, Enum.reject(consoles(s), &(&1.name == console.name)))
    }

  defp print(s, name, text) do
    console = find(s, name)
    console = if text == "", do: console, else: %{console | unseen: true}
    put(s, text |> String.codepoints() |> Enum.reduce(console, &char(&2, &1, max_lines(s))))
  end

  defp char(console, "\r", _max), do: %{console | cr: true}

  defp char(console, "\n", max) do
    lines = Enum.take([{console.current, console.markup} | console.lines], max)
    %{console | lines: lines, current: "", cr: false}
  end

  defp char(%{cr: true} = console, char, _max), do: %{console | current: char, cr: false}
  defp char(console, char, _max), do: %{console | current: console.current <> char}

  defp max_lines(%{cvars: %Cvars{} = cvars}) do
    case Cvars.fetch(cvars, "con_maxlines") do
      nil -> 1024
      cvar -> max(cvar.ival, 1)
    end
  end

  defp max_lines(_s), do: 1024

  defp visible(console) do
    [{console.current, console.markup} | console.lines]
    |> Enum.drop(console.scroll)
    |> Enum.reverse()
    |> Enum.map(fn {text, markup} -> {text, markup == 1} end)
  end

  defp field(s, console, "title", value),
    do: s |> Args.return(console.title) |> update(console, value, &%{&1 | title: &2})

  defp field(s, console, "name", value) do
    s = Args.return(s, console.name)

    if value && value != "" && console.name != "",
      do: s |> remove(console) |> put(%{console | name: value}),
      else: s
  end

  defp field(s, console, "next", _value) do
    case Enum.drop_while(consoles(s), &(&1.name != console.name)) do
      [_, next | _] -> Args.return(s, next.name)
      _ -> Args.return(s, 0)
    end
  end

  defp field(s, console, "unseen", value) do
    s
    |> Args.return(if(console.unseen, do: "1", else: "0"))
    |> update(console, value, &%{&1 | unseen: leading_integer(&2) != 0})
  end

  defp field(s, console, "markup", value) do
    s
    |> Args.return(Integer.to_string(console.markup))
    |> update(console, value, fn console, text ->
      %{console | markup: markup(leading_integer(text))}
    end)
  end

  defp field(s, console, "forceutf8", value) do
    s
    |> Args.return(if(console.forceutf8, do: "1", else: "0"))
    |> update(console, value, &%{&1 | forceutf8: leading_integer(&2) != 0})
  end

  defp field(s, console, "close", value) do
    s = Args.return(s, "0")
    if value && leading_integer(value) != 0, do: remove(s, console), else: s
  end

  defp field(s, console, "clear", value) do
    s = Args.return(s, if(console.lines == [], do: "1", else: "0"))

    if value && leading_integer(value) != 0,
      do: put(s, %{console | lines: [], current: "", cr: false, scroll: 0}),
      else: s
  end

  defp field(s, console, "hidden", value) do
    s
    |> Args.return(if(console.hidden, do: "1", else: "0"))
    |> update(console, value, &%{&1 | hidden: leading_integer(&2) != 0})
  end

  defp field(s, console, "linecount", value) do
    s
    |> Args.return(Integer.to_string(length(console.lines)))
    |> update(console, value, &%{&1 | unseen: leading_integer(&2) != 0})
  end

  defp field(s, console, name, value) when name in ["backimage", "backvideomap"] do
    s
    |> Args.return(console.backimage)
    |> update(console, value, &%{&1 | backimage: &2})
  end

  defp field(s, _console, _name, _value), do: s

  defp update(s, _console, nil, _fun), do: s
  defp update(s, console, value, fun), do: put(s, fun.(console, value))

  defp markup(0), do: 0
  defp markup(2), do: 2
  defp markup(_mode), do: 1

  defp input(s, console, 0, a, _b) do
    key = Keys.from_qc(trunc(a))

    cond do
      key in Enum.map(@clicks, &Keys.keynum/1) -> click(s, console, key)
      key in Enum.map(@scroll_up, &Keys.keynum/1) -> scroll(s, console, 2)
      key in Enum.map(@scroll_down, &Keys.keynum/1) -> scroll(s, console, -2)
      true -> Args.return(s, 0.0)
    end
  end

  defp input(s, console, 3, a, b),
    do: s |> put(%{console | mouse: {a, b}}) |> Args.return(1.0)

  defp input(s, console, 5, _a, b) when b >= 0,
    do: s |> put(%{console | focused: b != 0}) |> Args.return(1.0)

  defp input(s, _console, _event, _a, _b), do: Args.return(s, 0.0)

  defp click(s, console, key) do
    {_, y} = console.mouse
    right? = key in [Keys.keynum(:mouse2), Keys.keynum(:touchlong)]
    s = if right? and y < 8, do: remove(s, console), else: s
    Args.return(s, 1.0)
  end

  defp scroll(s, console, lines) do
    most = length(console.lines)
    scroll = (console.scroll + lines) |> max(0) |> min(most)
    s |> put(%{console | scroll: scroll}) |> Args.return(1.0)
  end

  defp leading_integer(text) do
    case Integer.parse(String.trim_leading(text)) do
      {number, _} -> number
      :error -> 0
    end
  end
end
