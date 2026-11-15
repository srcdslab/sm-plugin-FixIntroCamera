# FixIntroCamera

Counter-Strike: Source only.

When a player joins, CS:S shows the map's intro camera behind the MOTD: the player is put on the first
`point_viewcontrol` that has a target and looks at that target. On a dedicated server the view first
faces the wrong way (angles `0 0 0`), and is only corrected 6 seconds later.

## Cause

`CCSPlayer::MoveToNextIntroCamera()` sets the view with `SnapEyeAngles()` from `ClientActive`, which
asks the engine to send the angles to the client (`pl.fixangle`). The client is still loading and sends
no commands yet, so the server runs `CBasePlayer::RunNullCommand()` every tick, and that clears
`pl.fixangle` before the angles are sent. The client's first real command then carries its default view
(`0 0 0`), until the game snaps the view again 6 seconds later.

## Fix

The plugin hooks `CBasePlayer::PlayerRunCommand` (DHooks) on each human player from `ClientPutInServer`.
On the first real command of the player, who is still on the intro camera, it sends the camera angles
again (`TeleportEntity`). For up to two seconds it also replaces the angles of the commands that were
already in flight. Then it removes the hook, so nothing runs per command afterwards.

The camera angles are read on the first command the player runs, and kept in `[-180, 180]` like a client
sends them. The game computes them in `[0, 360)`, so a camera looking slightly up has a pitch like `352.9`:
anticheats that clamp the pitch to 89 (Lilac) would otherwise turn the view straight down. The plugin also
writes these angles into the null commands run while the client loads, for the same reason.

## Install

Copy `addons/sourcemod/plugins/FixIntroCamera.smx` and `addons/sourcemod/gamedata/FixIntroCamera.games.txt`.
Needs DHooks (bundled with SourceMod 1.11+). No config.
