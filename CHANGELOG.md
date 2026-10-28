# Changelog

Versions 1.0.6 to 1.1.1 have not yet been tested on a live server.

## 1.1.1

- Admin commands (`!balance on`, `off`, `status`) work in chat even when
  `bChatCommands` is off. Before, nothing watched chat at all in that case,
  and only the `mutate` versions worked.
- Commands typed in team chat are recognised.
- The ratings file is read once. The retry loop added in 1.0.2 re-read the
  same in-memory copy (the engine reads an ini file once per server process),
  so it could never succeed. A failed load now logs the checklist straight away.
- The version is shown in the startup log line and in `!balance status`.
- WebAdmin text for `bAnnounce` corrected: it controls all public messages
  (screen and chat), not just chat.
- The game's own "players can't join the bigger team" rule
  (`bPlayersBalanceTeams`) stays on; the mutator lifts it only for the instant
  it moves someone. Before, `bDisableStockBalancing` switched it off for the
  whole map, so players could stack a team or switch straight back after a
  move, and a WebAdmin save could write "off" into `UT2004.ini` permanently.
  `bDisableStockBalancing` is removed, and bot balancing (`bBalanceTeams`)
  is no longer touched.
- Numbers in chat, `!teams`, `!balance status` and the server log no longer
  carry a stray `.00` ("avg 31.2.00"). Found by starting a local server.
- Chat command replies no longer appear twice (the game passes each chat
  message through the handler chain twice).
- `[TeamBalance]` chat lines no longer show the receiving player's own name in
  front, as if they had typed them. Clearer wording for the cooldown,
  admin-only and too-few-players replies.
- Moves made during warmup no longer count toward `MaxMovesPerPlayer`; the
  counts are reset when the match starts.
- WebAdmin: "Enable !balance / !teams" listed with the other chat settings.
- On-screen notices are white with only the team name in team colour (were
  fully red, blue or yellow, the same colours as the CTF flag alerts). The
  chat line and server log stay plain text. `TeamBalanceMsg_V1` was rebuilt
  for this before its first release.
- Ratings upload script `Tools/GetPlayerRankings.ps1` added (replaces
  `validate_ratings.py`):
  - alt GUIDs get the numbers of the member's most-played GUID; before, an
    unused alt could override a main account with a negative Rating, leaving
    that player rated as unknown;
  - numbers always use `.` as the decimal point;
  - unreadable player files are logged instead of skipped silently;
  - uploads only when something changed, to a temporary name that is then
    renamed over the live file; optional FTPS;
  - FTP login and paths moved to a config file that is not in git.

## 1.1.0

- Player notices at the top of the screen, under the CTF notices, in team
  colour (`bTopMessages`). Needs the small client package `TeamBalanceMsg_V1`,
  which the mutator registers for download itself. Details always go to chat.
- Everyone is told, by name, when a player is queued to switch, when the
  switch happens, and when it is cancelled (with the reason).
- The player concerned is told privately, reminded each respawn while
  waiting for a swap, and told their new team again when they first spawn.
- Match start says "Teams are even" when nothing needs changing.
- Messages are sent to each player directly. `Level.Game.Broadcast` shares a
  200-characters-per-second limit with chat and dropped them silently.

## 1.0.9

- Fixes 1.0.8, which did not compile: the `TeamChange` stats line now goes
  through `Level.Game.GameStats`.
- A living player is never switched (switching kills the pawn, which the
  stats log records as a suicide). At match start, players without a pawn
  move at once and the rest are queued for their next death.

## 1.0.8

- Team moves are written to the stats log as a `TeamChange` event. Before,
  balance moves were invisible to OLStats, so the stats bot credited players
  to their join team.

## 1.0.7

- Ratings file diagnostics in the server log: a checklist when no ratings
  load; per-entry checks for bad GUIDs, duplicates, odd numbers and upper-case
  GUIDs; optional `FormatVersion` / `GeneratedAt` / `ExpectedCount` header
  lines to catch partly-read files; ratings coverage at each match start.
- Admin command `!balance status`.

## 1.0.6

- Admin switch: `!balance off` / `!balance on` in chat (or `mutate balance
  off/on`). Saved, so it lasts across maps.

## 1.0.5 (last version tested live)

- Escalation: when the gap exceeds `Tolerance × EscalationFactor`,
  established players can be moved and the per-player limit goes up by one.
- Deferred swaps for even teams: both players switch only when both are dead
  at the same moment.
- The "no move found" log line says why.

## 1.0.4

- Tuned for Instagib CTF: queued moves checked every 0.25 s; center-screen
  messages (`bCenterMessages`) so notices don't scroll away.

## 1.0.3

- Mid-match moves wait until the player is dead; cancelled after
  `DeferredMoveTimeout`.
- Mid-match, only recent joiners can be moved (or anyone, to fix a team-size
  difference of 2 or more).
- Per-player move limit per map, one move per pass, no mid-match swaps, a move
  must cut the gap by 25%.
- No moves near the end of a match or in overtime.
- Moved players get a private message.

## 1.0.2

- Ratings load retried for about 30 s after a server start (removed in 1.1.1:
  it could never work).

## 1.0.1

- Fixed a compile error in `LoadRatings()`.

## 1.0.0

- First version.
