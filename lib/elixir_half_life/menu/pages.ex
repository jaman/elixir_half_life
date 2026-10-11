defmodule ElixirHalfLife.Menu.Pages do
  @moduledoc """
  The pages of the in-game menu and the items on each, following FreeHL's menu
  (Nuclide's `menu-fn`): the main menu, Configuration and its Controls, Advanced
  controls, Audio, Video, Video options, Video modes and Content control pages, and the
  quit question.

  An item is one of:

    * `{:open, label, page}` — goes to another page
    * `{:done, label}` — back to the page this one was opened from
    * `{:resume, label}`, `{:quit, label}`, `{:defaults, label}` — resume play, ask to
      quit, put the key bindings back to the preset's
    * `{:check, label, option}` — a switch of the player's options
    * `{:slider, label, option, {low, high, step}}` — a number of the player's options
    * `{:choice, label, option, choices}` — one of `choices` for an option
    * `{:volume, label}` — the sound effects level (`:sfx`), 0.0 to 1.0
    * `{:bind, label, action}` — the keys bound to one of the game's actions
    * `{:heading, label}` — a title within a page; never chosen

      ElixirHalfLife.Menu.Pages.items(:audio)
  """

  alias ElixirHalfLife.Options

  @parents %{
    configuration: :main,
    controls: :configuration,
    advanced_controls: :controls,
    audio: :configuration,
    video: :configuration,
    video_options: :video,
    video_modes: :video,
    content_control: :configuration,
    quit: :main
  }

  @titles %{
    main: "HALF-LIFE",
    configuration: "CONFIGURATION",
    controls: "CONTROLS",
    advanced_controls: "ADVANCED CONTROLS",
    audio: "AUDIO",
    video: "VIDEO",
    video_options: "VIDEO OPTIONS",
    video_modes: "VIDEO MODES",
    content_control: "CONTENT CONTROL",
    quit: "QUIT"
  }

  @bindings [
    {:heading, "Movement"},
    {:bind, "Move forward", :forward},
    {:bind, "Move back", :back},
    {:bind, "Turn left", :turn_left},
    {:bind, "Turn right", :turn_right},
    {:bind, "Move left (strafe)", :strafe_left},
    {:bind, "Move right (strafe)", :strafe_right},
    {:bind, "Jump", :jump},
    {:bind, "Duck", :crouch},
    {:bind, "Swim up", :swim_up},
    {:bind, "Swim down", :swim_down},
    {:bind, "Look up", :look_up},
    {:bind, "Look down", :look_down},
    {:bind, "Look straight ahead", :center_view},
    {:bind, "Strafe modifier", :strafe},
    {:bind, "Mouse look modifier", :mouse_look},
    {:bind, "Keyboard look modifier", :klook},
    {:bind, "Use items", :use},
    {:heading, "Combat"},
    {:bind, "Primary attack", :fire},
    {:bind, "Secondary attack", :alt_fire},
    {:bind, "Reload weapon", :reload},
    {:bind, "Walk", :walk},
    {:bind, "Flashlight", :flashlight},
    {:bind, "Weapon category 1", :weapon_1},
    {:bind, "Weapon category 2", :weapon_2},
    {:bind, "Weapon category 3", :weapon_3},
    {:bind, "Weapon category 4", :weapon_4},
    {:bind, "Weapon category 5", :weapon_5},
    {:bind, "Weapon category 6", :weapon_6},
    {:bind, "Previous weapon", :prev_weapon},
    {:bind, "Next weapon", :next_weapon},
    {:bind, "Last weapon used", :last_weapon},
    {:heading, "Miscellaneous"},
    {:bind, "Take screen shot", :screenshot},
    {:heading, "Pointer"},
    {:bind, "Pointer moves left", :pointer_left},
    {:bind, "Pointer moves right", :pointer_right},
    {:bind, "Pointer moves up", :pointer_up},
    {:bind, "Pointer moves down", :pointer_down}
  ]

  @doc "The items of `page`, top to bottom."
  @spec items(atom()) :: [tuple()]
  def items(:main),
    do: [{:resume, "Resume game"}, {:open, "Configuration", :configuration}, {:quit, "Quit"}]

  def items(:configuration),
    do: [
      {:open, "Controls", :controls},
      {:open, "Audio", :audio},
      {:open, "Video", :video},
      {:open, "Content control", :content_control},
      {:done, "Done"}
    ]

  def items(:controls),
    do:
      [
        {:defaults, "Use defaults"},
        {:open, "Advanced controls", :advanced_controls},
        {:done, "Done"}
      ] ++ @bindings

  def items(:advanced_controls),
    do: [
      {:check, "Reverse mouse", :invert_mouse},
      {:check, "Lookspring", :lookspring},
      {:check, "Lookstrafe", :lookstrafe},
      {:check, "Mouse filter", :mouse_filter},
      {:check, "Auto-aim", :autoaim},
      {:slider, "Mouse sensitivity", :sensitivity, {0.0, 10.0, 0.5}},
      {:done, "Done"}
    ]

  def items(:audio),
    do: [
      {:volume, "Sound effect volume"},
      {:check, "High quality sound", :hq_sound},
      {:done, "Done"}
    ]

  def items(:video),
    do: [
      {:open, "Video options", :video_options},
      {:open, "Video modes", :video_modes},
      {:done, "Done"}
    ]

  def items(:video_options),
    do: [
      {:slider, "Gamma", :gamma, {0.05, 1.0, 0.05}},
      {:slider, "Glare reduction", :brightness, {0.0, 1.0, 0.05}},
      {:slider, "Field of view", :fov, {70, 150, 5}},
      {:done, "Done"}
    ]

  def items(:video_modes),
    do: [
      {:choice, "Picture resolution", :picture_width, Options.picture_widths()},
      {:done, "Done"}
    ]

  def items(:content_control),
    do: [{:check, "Human blood", :human_blood}, {:done, "Done"}]

  def items(:quit), do: []

  @doc "The page `page` was opened from; `nil` for the main menu."
  @spec parent(atom()) :: atom() | nil
  def parent(page), do: Map.get(@parents, page)

  @doc "The title drawn over `page`."
  @spec title(atom()) :: String.t()
  def title(page), do: Map.fetch!(@titles, page)

  @doc "Whether `item` can be chosen with the cursor."
  @spec choosable?(tuple()) :: boolean()
  def choosable?({:heading, _label}), do: false
  def choosable?(_item), do: true
end
