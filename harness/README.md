# Offline client harness

Run the x64 DX11 SWG client on its own. No login server, no central server, no game server, no
Oracle. The client builds its own player, loads a planet's terrain and the static world, and runs.

This exists so client-side work — rendering, UI, input, animation, terrain, asset loading — can be
built and tested without standing up the server stack for every iteration.

## What you need

| | |
| --- | --- |
| Visual Studio 18 (toolset v145) | The 2022 MSBuild fails with `MSB8020: The build tools for v145 cannot be found`. |
| An existing SWG client installation | Supplies the `.tre` stack. **Not distributed here.** |
| Windows 10/11, x64 | |

## Three commands

```powershell
# 1. Build the client
.\scripts\Build-X64Client.ps1 -Configuration Release

# 2. Assemble a serverless runtime directory from your client installation
.\harness\New-OfflineRuntime.ps1 -AssetSource E:\SWG\_client -Destination E:\SWG\_offline

# 3. Run it
.\harness\Start-OfflineClient.ps1 -RuntimeRoot E:\SWG\_offline
```

Step 2 hardlinks the game data rather than copying it, so mirroring an 8 GB installation costs
almost no disk. The asset source is never written to.

## Changing what loads

Retarget without rebuilding the runtime:

```powershell
.\harness\Start-OfflineClient.ps1 -RuntimeRoot E:\SWG\_offline `
    -Scene terrain/naboo.trn -StartLocation -5000,0,4000
```

Or from inside the running client, with the client console:

```
/scene load naboo twilek_female
```

`/scene load <terrain> [species_gender]` tears down the current scene and builds a new one. It
needs no server either.

## The knobs

All of these live in `offline.cfg`, which `New-OfflineRuntime.ps1` writes into the runtime and
chains from `client.cfg`. It is included **last**, and the client's config accessors return the
last value entered for a key, so `offline.cfg` overrides `user.cfg` and `options.cfg`.

| `[ClientGame]` key | Effect |
| --- | --- |
| `groundScene` | Terrain to boot into, eg `terrain/tatooine.trn`. **Setting this is the entire opt-in for offline mode.** Clear it to get the normal login screen back. |
| `avatarSelection` | Player object template. Defaults to `object/creature/player/shared_human_male.iff`. |
| `playerName` | Name on the avatar. |
| `singlePlayerStartLocationX/Y/Z` | World start position. |
| `singlePlayerSnapToTerrain` | Default `1`. Drops the avatar onto the heightmap once terrain has loaded. Set `0` for interiors and space, where the heightmap is not the floor. |
| `disableWorldSnapshot` | Set `1` for bare terrain with no buildings or props. |
| `offlineSceneSelectButton` | Set `1` to expose the login screen's dev button in a PRODUCTION build, which opens the `/SceneSel` page. Only useful with `groundScene` cleared. |

## Scenes

Ground terrain lives at `terrain/<planet>.trn` in the tree file stack:

```
tatooine  naboo     corellia  rori      talus
dantooine dathomir  endor     lok       yavin4
tutorial  simple
```

Space scenes are `terrain/space_<name>.trn`. They load, but `singlePlayerSnapToTerrain` must be
`0` and the free-chase camera is not a flight rig, so treat space as unfinished here.

`New-OfflineRuntime.ps1` validates nothing about scene names — the client does, and it is fatal:
a `groundScene` that is not in the tree file stack aborts at startup with the path named.

## How it works

The single-player path was already in the shipped client and already correct. `GroundScene` has a
constructor that takes a terrain file and a player *template* rather than a network id, builds the
avatar locally through `ObjectTemplate::createObject`, and starts with `m_receivedSceneReady` set
because in single player there is no server to wait on.

What was missing was a way to reach it. The shipped route is the login screen's dev button, and
`SwgCuiLoginScreen` hides that button when `PRODUCTION == 1` — which is the only configuration
that links a client in this tree. The config-driven route existed too, in `Game::install`, but was
inside an `#if 0`.

This harness changes three things:

- **`Game::install`** boots the single-player scene when `[ClientGame] groundScene` is set, before
  the splash and login screen are ever activated. Both the terrain file and the avatar template
  are checked against the tree file stack up front, so a typo fails immediately and by name
  instead of somewhere deep in scene load.
- **`GroundScene`'s single-player constructor** snaps the avatar to terrain height after `init()`.
  The configured start location's Y defaults to 0, which is below ground on every shipped
  heightmap, so an offline start used to spawn the player inside the terrain unless the operator
  already knew the exact height to type.
- **`SwgCuiLoginScreen`** gates the dev button on config rather than hiding it unconditionally in
  PRODUCTION. Default is still hidden, so a shipping client is unchanged.

Everything else — the renderer, the UI, terrain streaming, asset loading, animation, collision —
is the stock client.

## What does not work offline

The client is doing everything locally, so anything that is genuinely the server's job is absent,
not broken:

- **No NPCs, no spawns, no AI.** Creature and NPC population comes from the server.
- **No chat, mail, guilds, group, commerce, missions, quests.**
- **No combat.** Commands round-trip through the server's command queue.
- **No persistence.** Nothing is saved between runs; the avatar is rebuilt from its template.
- **No character customization.** The avatar comes from a template with no customization applied.
  Species and gender are the `avatarSelection` template you pick.
- **Buildings are exterior-only in practice.** Cells and portals load, but the server normally
  owns cell permissions, so expect interiors to be inconsistent.
- **Parts of the HUD have nothing to read.** The `PlayerObject` "ghost" — the object carrying
  skills, xp, waypoints, collections, the friends list — is created and sent by the server, so
  `Game::getPlayerObject()` returns null offline. Mediators that guard for that degrade quietly;
  ones that do not can fault when opened. This is the single most likely source of a crash in
  offline mode, and it is a UI panel you opened rather than the scene itself.

Terrain, static world objects, appearance, animation, sound, particles, shaders and the UI are all
client-side and all work.

## Diagnostics

`logs\warning.log` in the runtime directory is the whole record. `DEBUG_REPORT_LOG` and
`DEBUG_WARNING` compile out of PRODUCTION, which is the only configuration that links a client, so
anything that needs to be visible in a real run has to be a plain `WARNING` — the offline boot
reports its terrain and avatar that way.

`Start-OfflineClient.ps1 -TailLog` follows the log until the client exits.

Two DX11 diagnostics carry over from the renderer port and work offline:

| `[Direct3d11]` key | Effect |
| --- | --- |
| `debugScreenshotFrame=<N>` | Writes a TGA through the shipping image writer at frame N. Occlusion-proof, unlike a desktop grab. |
| `debugRenderDocFrame=<N>` | Triggers a RenderDoc capture from inside the backend. No window focus needed. |

## Notes

- **Launch with the working directory set to the runtime root.** The graphics backend is loaded as
  `.\gl11_r.dll`, CWD-relative. `Start-OfflineClient.ps1` does this for you.
- **Deploy the exe and the backend DLL together, always.** They share the `Gl_api` vtable and the
  `clientGraphics` headers. A stale exe against a fresh `gl11_r.dll` gives garbage pointers that
  look exactly like a renderer bug.
- **`.cfg` files must not have a byte order mark.** The config parser does not skip one, and a BOM
  makes the first section header unreadable — which fails before any logging exists, so it
  presents as a silent crash. PowerShell's `Out-File` and `Set-Content` write a BOM by default;
  the harness scripts write UTF-8 without one explicitly.
- **Identify a running client by its directory, not its executable name.** These binaries get
  renamed per server and several unrelated SWG clients commonly coexist on one machine.
  ```powershell
  Get-Process | Where-Object { $_.Path -like "E:\SWG\_offline\*" }
  ```
  Close with `CloseMainWindow()` rather than a force kill, so shutdown work completes.
