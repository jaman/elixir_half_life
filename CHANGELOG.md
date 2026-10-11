# Changelog

## Unreleased

### Changed

- The picture is drawn at the picture width in the game's options, now 480 pixels across
  by default, and the terminal scales it to the window (`native:1,swap`); `--picture`
  (or `CAULDRON_PICTURE`) chooses otherwise. The width option is therefore both the
  picture's sharpness and the cost of a frame.
- Joining no longer waits for the level to load: the server is asked to load it once the
  client program is running, behind the loading plaque. FreeHL's server, client and menu
  programs are compiled while the assets load (`Assets.load/2`), so a join never waits
  on a compile.
- A level that takes more than 60 seconds to start no longer crashes the client program
  when it is asked for a picture.

### Added

- `--mute` (or `CAULDRON_MUTE=1`): no sound.


### Changed

- `mix half_life` refuses an install without Half-Life's own `valve/halflife.wad` and
  `valve/maps/c0a0.bsp` (`Assets.load/2` returns `{:error, {:no_half_life, missing}}`);
  with FreeHL's files alone it started and then crashed.
- `Csqc.Sprites.polygon/5` is documented as it behaves: a frame the sprite lacks draws
  its frame 0, and it never returns `nil`.

### Added

- The menu program starts, and its `m_init` runs, before the level loads, as FTE starts
  the menu before any map; the menu's `sv_gameplayfix_setmodelsize_qw` and
  `sv_gameplayfix_setmodelrealbox` are set when the level spawns.
- The use key chooses its target as Half-Life's `CBasePlayer::PlayerUse` does
  (`ElixirHalfLife.PlayerUse`, run in place of FreeHL's
  `NSClientPlayer::InputUse_Down`): the train driven or stood on at its controls on a
  fresh press, otherwise the usable entity within 64 units of the player whose box lies
  most in view, above 0.7 along the view. Only entities Half-Life gives use caps
  (`ObjectCaps`) are chosen: a `func_door` without its use-only flag, a shootable
  button or a G-Man is not, though FreeHL gives each a `PlayerUse`. FreeHL's 64-unit line from the eye and its
  8-unit search at the line's end are gone; what happens to the chosen entity, the
  sounds and use held for chargers are FreeHL's.

- `F6` adds the current spot to `positions.txt` as a `setpos` line; `mix half_life
  --setpos "x y z [pitch yaw roll]"` starts the player there.
- `ElixirHalfLife.Csqc.Animation`: a studio entity the server sent whose `frame1time`
  the client program never sets is posed by GoldSrc's client rule
  (`StudioEstimateFrame`) from the server's animation: `time + (now - animtime) *
  framerate` seconds into its sequence, a looping sequence wrapping every `frames - 1`
  frames, one that does not loop held below `frames - 1.001`. The cycler helicopter in
  c0a0b turns its rotors; entities FreeHL's client times itself (monsters, players,
  the view model) are posed as before.

- FTE's menu builtin table (`ElixirHalfLife.MenuProgram.Builtins`): every number and
  name FreeHL's `menu.dat` imports runs FTE's menu behaviour — its own builtins
  (`MenuProgram.Engine`: `checkextension`, `objerror`, `bprint`, `msprint`, `cprint`,
  `isserver`, `clientcount`, `clientstate`, `crash`, `changelevel`, `localsound`,
  `getmousepos`, `setkeydest`, `getkeydest`, `registercommand`, `clipboard_get`, the
  `crypto_` builtins; `MenuProgram.Entities`: `clearscene`, `etof`, `ftoe`, the
  `findchain` builtins, `setmodel`, `precache_model`, `getmodelindex`, `setorigin`,
  `validstring`, the `altstr_` builtins), its console variable builtins, the drawing,
  key, client, server browser, sub-console and video builtins it shares with the client
  program, and the rest as the server's under the server's numbers. A builtin bound by
  name gets whatever FTE's table gives that name. An unimplemented builtin stops the
  menu as FTE's `PF_Fixme` does.
- The menu program starts as FTE's `MP_Init` starts it: `m_init` runs, then the
  commands it queued; a menu program error shuts the menu down as FTE's `Menu_Abort`
  does (`ElixirHalfLife.MenuProgram.aborted/1`).
- Client and menu builtins shared under the client program's numbers:
  `ElixirHalfLife.Csqc.Keys` (`keynumtostring`, `stringtokeynum`, `getkeybind`,
  `findkeysforcommand`, `findkeysforcommandex`, `setkeybind`, `getbindmaps`,
  `setbindmaps` over the console's key bindings), `Csqc.Client` (`cprint`, `isdemo`,
  `isserver`, local user info, `clipboard_set`, `setwindowcaption`, `setmousetarget`,
  `getmousetarget`, `getresolution` with FTE's own mode list, `getgamedirinfo`,
  `getpackagemanagerinfo`), `Csqc.Servers` (the server browser, with no servers),
  `Csqc.Consoles` (`con_getset`, `con_printf`, `con_draw`, `con_input`) and
  `Csqc.Media` (the `gecko_` and `cin_` builtins, with no video decoder).
- `ElixirHalfLife.GameDirs`: the games and mods FTE lists for the install.
- The host chooses the game as FTE's `FS_ChangeGame` does: `com_fullgamename` and
  `com_protocolname` are `Rad-Therapy`, `fs_game` is `valve`, with the paths in
  `fs_gamepath`, `fs_basepath` and `fs_homepath`.
- `ElixirHalfLife.Csqc.Text.console/4`: console lines drawn into a box.
- Replies to `uri_get` reach the client program before each `CSQC_UpdateView`, and the
  menu program before each loading screen.

- FTE's command numbering for prediction: commands count from 1 for the whole
  connection (the first two carry no buttons), `CSQC_Input_Frame` runs with
  `clientcommandframe` the command's number and `input_sequence` set, the last 64 sent
  commands are kept with their send times, `servercommandframe` is the last command the
  server acknowledged in a packet, and `getinputstate` gives a kept command, or for
  `clientcommandframe` the command still being gathered (the last one sent while it
  covers no time, its time the time since that send), so FreeHL replays the commands
  the server has not run yet.
- `ElixirHalfLife.CommandClock`: when a command is sent and how many whole milliseconds
  it covers, as FTE's `CL_SendCmd` works it out (`cl_netfps`, the server's `maxfps`,
  the fraction carried, at most 200).
- Console variables the server took over are released when a level's serverdata
  arrives and on disconnect, as FTE's `CL_ClearState` and `CL_Disconnect` do.

- The in-game menu (Esc): FreeHL's Configuration pages (controls and key bindings,
  advanced controls, audio, video options and modes, content control), each option
  taking effect, with the picture resolution changeable live; the framework's settings
  on F2.
- FTE's fonts and text (`ElixirHalfLife.Csqc.Text`, `ElixirHalfLife.FontFile`): FreeHL's
  TrueType and CFF fonts, its text fields and markup; the credits and game text draw.
- The loading screen, drawn by FreeHL's menu program (`ElixirHalfLife.MenuProgram`) while
  a level loads.
- `ElixirHalfLife.Sound`, FTE's sound channels and stereo placement for one listener,
  as commands for keyed voices.
- FreeHL single player in the terminal: assets from the Steam install and FreeHL's
  package, the server program on `QuakeServer`, the client program on its own world
  with the scene, screen, message, input and sound builtins, studio model and sprite
  drawing, the `mix half_life` task.
- FTE's host startup (`ElixirHalfLife.Host`): one console variable table for the
  game's server, client program and menu, the engine variables registered and the
  startup configs run in FTE's order (`default.cfg`, `config.cfg` or its refusal,
  `fte.cfg`, `autoexec.cfg`), so FreeHL's `default.cfg` values hold everywhere. A new
  game runs `set skill N; maxplayers 1` as FreeHL's menu does.
- `ElixirHalfLife.Assets.depth/1`: where a file is in the search order, as FTE's
  `COM_FDepthFile` counts it.
- The client program's `cvar` gives the 2D size for `vid_conwidth` and
  `vid_conheight`, and the menu's console variable builtins run under the menu's own
  numbers with FTE's DarkPlaces name mapping (`ElixirHalfLife.Csqc.Cvars`).
- `ElixirHalfLife.Options` also sets `sensitivity`, `m_pitch`, `m_filter`, `lookspring`
  and `lookstrafe`.

### Changed

- The client program's key names come from `QuakeServer.Keys` and its key bindings
  from the console; `Csqc.Input` no longer keeps `:binds`.

### Fixed

- - `Z` turns walking on and off with each press on every terminal.
Barney in c0a0e walks to the tram button and then to the retina scanner and opens
  the doors there, instead of stopping halfway down the walkway and playing his door
  sequences on the spot: the server's `vectoangles` keeps fractions of a degree as
  FTE's does, so monsters turning less than a degree a frame still turn.
- The tram ride's c0a0a plays its narration (`tride/c0a0_tr_dest.wav`) while the tram
  keeps moving: entity references carried from c0a0 are translated by Half-Life's level
  transition rule (`QuakeServer.EntityTable`), so the tram's timer from c0a0 restores as
  null instead of as the narration trigger's entity.
- - The loading picture is "LOADING..." over the last rendered game frame, with no fill.
A level is joined as FTE's client joins one: `changing` stops every sound channel;
  the serverdata shuts the last level's client program down (`CSQC_Shutdown`, its
  channels stopped) before the next starts; the new program starts with the level's name
  as the world's `message`, the server's sound list, FTE's `CSQC_Init` arguments (1,
  `"FTE QW"`, 10700), its `init` and `initents`, and the physics clock at 0.1; the
  server's static entities, static sounds and player info are read before the client
  begins, and the player enters the level only then (`QuakeServer.Runner.begin/3`).
  Packets of another level are dropped; a program started for a level already left is
  released.
- The client reads `svc_spawnstatic`, `svc_spawnstaticsound`,
  `svcfte_spawnstaticsound2` and `svc_updateuserinfo` (`ElixirHalfLife.Csqc.Parse`).

- The client knows the server's sound list and particle effect list (FTE's
  `svcfte_soundlistshort` and `svcfte_precache`, `ElixirHalfLife.Csqc.Precaches`):
  `soundnameforindex` names the server's sounds, so looping `ambient_generic` sounds
  (the apache rotors in c0a0b) start on the client's channels.
- The server's particle effects run on the client (`svcfte_pointparticles`,
  `svcfte_pointparticles1`, `svcfte_trailparticles`, `ElixirHalfLife.Csqc.ServerParticles`),
  with FTE's density fade by distance: sparks, explosions and breakables show.
- Sounds started with `SOUNDFLAG_FOLLOW` (64) follow their client entity each frame
  (`ElixirHalfLife.Sound.follow/2`), as FTE's `SND_Spatialize` moves them.
- Reading a packet sets the program's `time` and leaves `cltime` as the frame set it.
- The first load shows FreeHL's "LOADING..." over black, not the console background art.
- `r_uploadimage` takes FTE's arguments (name, width, height, data, size, format).
- The vote box no longer shows: `serverkey` gives null for an unset key, and the keys
  the engine answers itself (`constate`, `pausestate` and the rest).
- Sound is FTE's: the client keeps the channels (`ElixirHalfLife.Csqc.Sounds` on
  `ElixirHalfLife.Sound`), the server's sounds arrive in its packets, `soundupdate`,
  `stopsound`, `getsoundtime` and `getchannellevel` work on the channels, each channel is
  re-placed for the view every frame, and the game plays them as keyed sounds placed by
  level (so other sounds no longer push announcements out).
- The client program reads the server's info keys as the server sets them.
- The client program and the game never wait on the server: packets arrive as
  messages, events through the runner's table; a picture before the first level is
  black.
- The client program reads each packet as FTE's client does: reliable messages, then
  entity updates, then the datagram (`ElixirHalfLife.Csqc.Parse`); prints reach
  `CSQC_Parse_Print` a line at a time, centerprints `CSQC_Parse_CenterPrint`, stuffed
  text `CSQC_Parse_StuffCmd`.
- Sound entities (`ambient_generic`, `PVSF_USEPHS`) are on the client when their
  sentence events arrive, so the events are no longer dropped as out of sight.
- Brush models are traced with FTE's hull choice (`Assets.hull/2`).
- The client program's `view_angles` follow the player's turning, so the view turns.
- The view turns with a train the player rides (`fixangle` 2).
- Level changes carry the player and what rides with them by the landmark.
- The server program runs in a `QuakeServer.Runner` on its own clock; the client program
  is its subscriber and builds each level's program in its own process.
- Monsters and other models the server precached are drawn: the client program uses the
  server's model numbers.
- The player's own body is not drawn in first person (`RF_EXTERNALMODEL`).
- The client program's surface cache belongs to its own process.
- The client program takes the server's world when it draws (`Runner.snapshot/1`), so
  a train the player rides is where the server has it and the view stays inside it.
- Each game file is read once (`Assets.read/1`), file listings are kept by prefix
  (`Assets.list/1`), and a map's neighbours, with their models and sounds, are read in
  the background while the level is played (`Assets.prefetch/1`).
- Assets made at the same time for different keys no longer wait on one another.
- The client program's memory is released when a new level starts.
- The client program's own sounds are played: characters' speech, footsteps and the
  sounds of their animations.
- Input is turned into a command once per client frame, as FTE's client does; the game no
  longer waits on a frame being drawn.
- Light styles reach the client program, so lights flicker, pulse and switch as set.
