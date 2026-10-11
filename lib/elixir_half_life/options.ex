defmodule ElixirHalfLife.Options do
  @moduledoc """
  The player's options, kept in their settings under `:options`, and the console
  commands that put them into effect as FreeHL's menu sets them.

    * `:sensitivity` — `sensitivity`, 0 to 10 (FTE's default 10), how far a pointer
      movement turns and looks
    * `:invert_mouse` — `m_pitch` negative, the pointer's up and down reversed
    * `:mouse_filter` — `m_filter`, each pointer movement averaged with the last
    * `:lookspring` — `lookspring`, the view drifting back level when the mouse look
      modifier is let go
    * `:lookstrafe` — `lookstrafe`, the pointer's sideways movement strafing while mouse
      look is on
    * `:autoaim` — `sv_aim` 0 on (the server aims shots at what is nearly ahead), 1 off
    * `:gamma` — `gamma` and `vid_gamma`, 0.05 to 1.0 (lower darker)
    * `:brightness` — `brightness` and `vid_brightness`, 0.0 to 1.0, white added to
      every pixel
    * `:fov` — `fov`, the horizontal field of view in degrees, 70 to 150
    * `:human_blood` — `violence_hblood`, blood shown where shots hit
    * `:hq_sound` — `loadas8bit` 0, sounds played at their own sample width rather than
      cut to 8 bits
    * `:picture_width` — the pixels across the client program draws its picture with,
      one of `picture_widths/0`: the width a client asking for the game's own size
      (`Cauldron2D.Drafter.Client.Picture`'s `native`) is given, and otherwise the most
      it draws before the picture is scaled to the pane

      commands = ElixirHalfLife.Options.client_commands(ElixirHalfLife.Options.defaults())
  """

  @defaults %{
    sensitivity: 10.0,
    invert_mouse: false,
    mouse_filter: false,
    lookspring: false,
    lookstrafe: false,
    autoaim: false,
    gamma: 1.0,
    brightness: 0.0,
    fov: 90,
    human_blood: true,
    hq_sound: true,
    picture_width: 480
  }
  @picture_widths [160, 240, 320, 400, 480, 640, 800, 960, 1280]

  @doc "Every option with its default."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc "The picture widths the player may choose, narrowest first."
  @spec picture_widths() :: [pos_integer()]
  def picture_widths, do: @picture_widths

  @doc "`options` over the defaults, so every option is present."
  @spec complete(map() | nil) :: map()
  def complete(nil), do: @defaults
  def complete(options), do: Map.merge(@defaults, options)

  @doc """
  The console commands that set the console variables for `options` as FreeHL's menu
  sets them, archived (`seta`): the mouse's (`sensitivity`, `m_pitch`, `m_filter`,
  `lookspring`, `lookstrafe`), the picture's and the sound's. The server, the client
  program and the menu share the variables (`ElixirHalfLife.Host`), so any console may
  run them.
  """
  @spec client_commands(map()) :: String.t()
  def client_commands(options) do
    options = complete(options)
    mouse = mouse(options)

    [
      "seta sensitivity #{number(mouse.sensitivity)}; seta m_pitch #{number(mouse.m_pitch)}",
      "seta m_filter #{flag(mouse.m_filter)}; seta lookspring #{flag(mouse.lookspring)}; seta lookstrafe #{flag(mouse.lookstrafe)}",
      "seta gamma #{number(options.gamma)}; seta vid_gamma #{number(options.gamma)}",
      "seta brightness #{number(options.brightness)}; seta vid_brightness #{number(options.brightness)}",
      "seta fov #{number(options.fov)}",
      "seta violence_hblood #{flag(options.human_blood)}",
      "seta loadas8bit #{flag(not options.hq_sound)}"
    ]
    |> Enum.join("\n")
  end

  @doc "The console commands that set the server's console variables for `options`."
  @spec server_commands(map()) :: String.t()
  def server_commands(options), do: "set sv_aim #{flag(not complete(options).autoaim)}"

  @doc "The mouse console variables for `options`, as `ElixirHalfLife.Movement` reads them."
  @spec mouse(map()) :: %{
          sensitivity: float(),
          m_pitch: float(),
          m_filter: boolean(),
          lookspring: boolean(),
          lookstrafe: boolean()
        }
  def mouse(options) do
    options = complete(options)

    %{
      sensitivity: options.sensitivity / 1,
      m_pitch: if(options.invert_mouse, do: -0.022, else: 0.022),
      m_filter: options.mouse_filter,
      lookspring: options.lookspring,
      lookstrafe: options.lookstrafe
    }
  end

  defp flag(true), do: "1"
  defp flag(false), do: "0"

  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(value), do: :erlang.float_to_binary(value / 1, decimals: 6)
end
