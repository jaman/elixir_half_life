# ElixirHalfLife

Half-Life, played in a terminal, with every line of the engine in Elixir. The game code is
[FreeHL](https://github.com/eukara/freehl) (ISC licence, built on Nuclide for the FTE
engine), compiled QuakeC run on this repository's QuakeC virtual machine. The data comes
from your own copy of Half-Life.

```sh
mix deps.get
mix half_life --dir "/path/to/Half-Life" --freehl /path/to/freehl
mix half_life --dir "/path/to/Half-Life" --freehl /path/to/freehl --map c1a0 --skill 2
```

`--dir` is the Half-Life install, the directory holding `valve` (Steam's
`steamapps/common/Half-Life`). `--freehl` is a directory holding FreeHL's release package
`package_valve.pk3` (from FreeHL's releases page) or its unpacked files. `HALF_LIFE_DIR`
and `FREEHL_DIR` set them too. The install must hold Half-Life's own `valve/halflife.wad`
and `valve/maps/c0a0.bsp`; without them the game does not start. No Half-Life data is
included.

On a terminal that keeps images (kitty, Ghostty, WezTerm, iTerm2) the picture is drawn
at the picture width chosen in the game's options (480 pixels across to begin with) and the terminal scales it to the window, so a small font gives more
room without a blurrier picture. `--picture` (or `CAULDRON_PICTURE`, or
`config :cauldron_2d_drafter, picture: "..."` in a `config/runtime.exs`) chooses
otherwise, with any of these comma separated: `native` draws at the game's own size times
the largest whole number that fits the window, `native:N` at `N` times, `size:WxH`
sets the size itself, `png` sends each frame as a PNG (about a third smaller, for play
over ssh, at more CPU), `swap` replaces each frame without a blank between, and `none`
draws at the window's cells instead. The default is `native:1,swap`.

The picture width in the game's options is the width the picture is drawn at under
`native`, so it sets both the sharpness and the cost of a frame: the client program
spends about 80 ms a frame on the game code whatever the size, and then more the more
pixels it draws, so 320 to 480 pixels across plays at around 8 to 10 frames a second and
960 across at about 4. Under `none` that width is only a cap on what the window's cells
ask for.

## How it runs

Two QuakeC programs run, as they would under FTE:

* **The server program, `progs.dat`,** runs on `QuakeServer`, in a process of its own on
  its own clock (`QuakeServer.Runner`): a physics frame once at least 13 ms have passed,
  as long as has passed, as FTE's host runs them. It spawns the map's entities through
  FreeHL's own `CheckSpawn`, runs every entity's thinking and physics, moves the player
  itself from the latest command, and follows level changes by their landmarks.
* **The client program, `csprogs.dat`,** runs on its own world of the same map
  (`ElixirHalfLife.Csqc`, in its own process, `ElixirHalfLife.ClientProgram`). Each
  time it draws it takes the server's world as it stands (`Runner.snapshot/1`), as an
  FTE client takes its snapshot. It hears
  every entity the server sends and the server's events, turns the player's input, and
  draws each frame: it sets the view and chooses the entities, and the engine draws them
  (`Csqc.Render`). Then it draws its own HUD over the top (`Csqc.Screen`).

What the engine draws:

* the world in full colour, each texture with its own palette, lit by the map's
  red-green-blue lightmaps;
* see-through `{` textures;
* rotating brush entities;
* studio models posed by their sequences, bone controllers, blends, body groups and
  skins, or by the program's own skeleton objects;
* sprites;
* skyboxes from `gfx/env`;
* the program's polygons.

Half-Life's fonts, sprite frames, TGA, BMP and WAD pictures serve the HUD.

## Keys

| Key | Action |
| --- | --- |
| `W` `S` or `↑` `↓` | forward, back |
| `A` `D` | strafe |
| `←` `→` | turn |
| `T` `G` or `PgUp` `PgDn` | look up, down |
| `C` or `End` | look straight ahead |
| `F` / `V` | fire / alternate fire |
| `Space` / `X` | jump / crouch |
| `E` | use |
| `R` | reload |
| `L` | flashlight |
| `Z` | walking: each press turns it on or off |
| `Q` / `Tab` | previous / next weapon |
| `1`–`6` | weapon slot |

The mouse preset adds turning and looking by moving the mouse, firing and alternate firing
on the buttons, and weapon changes on the wheel. A controller works as listed in
`ElixirHalfLife.Client`.

## What is not here yet

* FreeHL's main menu (`menu.dat`, a third QuakeC program): `Esc` leaves the game instead
* sounds the client program plays itself (the server's sounds play)
* particle effects, dynamic lights, decals, and hit detection against studio model
  hitboxes
* saving and loading

The game itself (`ElixirHalfLife.Game`, on Cauldron's world at 20 steps a second) only
turns the held keys into commands, passes them through the client program's input hook
to the server, and places the server's sounds; neither program waits on the other.

## Speed

Both programs run as Elixir compiled from their QuakeC (`QuakeC.Compiler`), compiled the
first time and cached. On one Apple M-series machine a physics frame of c0a0, with its
NPCs thinking, takes about 7 ms, inside FTE's 13 ms frame; a client frame at 320 by 200
takes 15 to 70 ms, most of it relighting surfaces whose light styles changed.

Starting a level takes about a second for the server program and a little more for the
client program, once the map's files are read. Most of the server's second is FreeHL
reading its sound definitions: each sound precached reads the definition files line by
line in QuakeC, about 150 000 lines a level, as it does under FTE. A level's neighbours
are read in the background while it is played, so a level change finds its map, models
and sounds already parsed.

## Licence

GPL-2.0-or-later, as it runs on `quake_server`. FreeHL is ISC. Half-Life's data belongs
to Valve and is read only from your own copy.
