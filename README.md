# MutTeamBalance

A rating-based team balancer for **Unreal Tournament 2004 Capture the Flag**.
It keeps teams even by moving players between them using each player's skill
rating, and it tells everyone what it is doing.

It is a server-side mutator. Players download only one small message package
(about 6 KB), which draws the balancing notices at the top of the screen.

**Version 1.1.1** (see [CHANGELOG.md](CHANGELOG.md)). Builds with UCC 3374
(0 errors, 0 warnings). The last version tested on a live server is 1.0.5;
**1.0.6 to 1.1.1 have not yet been tested in a game.**

## Contents

- [Where the ratings come from](#where-the-ratings-come-from)
- [Installing](#installing)
- [How balancing works](#how-balancing-works)
- [What players see](#what-players-see)
- [Commands](#commands)
- [Settings](#settings)
- [Files](#files)
- [Ratings file format](#ratings-file-format)
- [Server log messages](#server-log-messages)
- [Stats log](#stats-log)
- [Building from source](#building-from-source)
- [License](#license)

## Where the ratings come from

Ratings come from the [FlawsFightNight](https://github.com/Theinfection91/FlawsFightNight)
Discord bot, which reads the server's OLStats log files and keeps an
OpenSkill rating (Mu, Sigma) and an Elo rating for every player.

```
UT2004 server ──OLStats logs──▶ FlawsFightNight bot ──player profiles──▶
  Tools\GetPlayerRankings.ps1 ──TeamBalanceRatings.ini (FTP)──▶ UT2004 server
```

[`Tools/GetPlayerRankings.ps1`](Tools/GetPlayerRankings.ps1) runs on the PC
that hosts the bot. Every 2 minutes it:

1. reads the bot's player profiles and member profiles;
2. gives every GUID registered to one member the same numbers, taken from
   that member's most-played GUID (lowest Sigma), so a player can't dodge
   balancing on an alt;
3. checks the result (enough entries, no sudden drop, pure ASCII, correct
   header) and writes `TeamBalanceRatings.ini`;
4. if anything changed, uploads it to the game server's `System` folder by
   FTP, under a temporary name that is then renamed, so the server never
   reads a half-written file.

Its settings, including the FTP login, go in `Tools\GetPlayerRankings.config.psd1`.
Copy [`GetPlayerRankings.config.example.psd1`](Tools/GetPlayerRankings.config.example.psd1)
to that name and fill it in. The real file is ignored by git, so it can't be committed.

> **The game reads the ratings file only when the server process starts.**
> A map change does not re-read it. Restart the server to pick up new ratings,
> for example once a day.

## Installing

There are two packages:

| Package | What it is | Who needs it |
|---|---|---|
| `TeamBalance` | The mutator | Server only. Do **not** add it to `ServerPackages`. |
| `TeamBalanceMsg_V1` | One message class that draws the top-of-screen notices | Downloaded by players. The mutator registers it for download itself, so no `ServerPackages` line is needed. |

On the server:

1. Copy `TeamBalance.u`, `TeamBalance.ucl` and `TeamBalanceMsg_V1.u` into `System\`.
2. If the server uses a download redirect, upload `TeamBalanceMsg_V1.u.uz2`
   there as well (`ucc compress TeamBalanceMsg_V1.u` creates it).
3. Add the mutator `TeamBalance.MutTeamBalance`, either on the command line
   (`?Mutator=TeamBalance.MutTeamBalance`) or in WebAdmin, where it is listed
   as **Team Balance (Rating)**.
4. Put `TeamBalanceRatings.ini` in `System\` (the upload script does this).

No `UT2004.ini` changes are needed on the server. If players don't see the
top-of-screen notices, add `ServerPackages=TeamBalanceMsg_V1` under
`[Engine.GameEngine]` as a fallback. A 64-bit server reads
`UT2004-Win64.ini` instead.

## How balancing works

**Who counts.** Human players only; bots and spectators are ignored.
Nothing happens with fewer than `MinPlayersForBalance` players (default 3).

**Player score.** Each player gets a score from `BalanceMetric`:

| Metric | Score |
|---|---|
| `MU_ONLY` | Mu |
| `RATING_ONLY` | Rating (Mu − 3 × Sigma) |
| `ELO_ONLY` | Elo |
| `HYBRID` | RatingWeight × Rating + EloWeight × Elo |
| `DYNAMIC_HYBRID` (default) | RatingWeight × Rating + EloWeight × Elo × Confidence, where Confidence = clamp(1 − Sigma / 8.333, 0, 1). Elo counts less for players with few games. |

Players missing from the ratings file are scored as a new player
(`DefaultUnknownRating`/`Sigma`/`Elo`, by default Mu 25, Sigma 8.333, Elo 0).

**When it acts.** Teams are compared by their **average** score per player,
and team sizes always stay within one of each other. Nothing happens unless
the gap between the averages is more than `Tolerance`. Once it acts, it aims
to bring the gap down to `TargetGap`.

**No one is killed by a move.** Switching a living player kills their pawn,
and the stats log records that as a suicide. So a living player is never
switched: the move is queued and happens the next time that player is dead
(waiting to respawn). This also means a flag carrier is never moved mid-carry.

**At match start and in warmup** (full pass):

- anyone can be moved, swaps are allowed, up to 3 moves, until the gap is at
  or below `TargetGap`;
- players without a pawn move at once; players already alive are queued
  for their next death.

**During a match** (gentle):

- only recent joiners (within `JoinGraceSeconds`, default 90 s) can be moved;
  established players move only to fix a team-size difference of 2 or more;
- one move per pass, and it must cut the gap by at least 25%;
- the move waits for the player's next death and is cancelled after
  `DeferredMoveTimeout` (60 s) or if it is no longer useful;
- each player is moved at most `MaxMovesPerPlayer` times per map (default 1);
- automatic passes are at least `MoveCooldown` seconds apart (default 60);
- no moves in the last `EndGuardSeconds` of a timed match (default 180), in
  overtime, or when a team is within `GoalGuardCaps` captures of winning (default 1).

**Escalation.** If the gap is more than `Tolerance × EscalationFactor`
(default 4.0 × 1.5 = 6.0), established players can be moved too, the
per-player limit goes up by one, and even teams (such as 3 v 3) can be fixed
by a **swap**: one player from each team, switched only when both are dead
at the same moment, so team sizes never get out of step. A queued swap is
cancelled after `DeferredSwapTimeout` (90 s). `EscalationFactor=0` turns
escalation off.

**Tournament mode.** Balancing is off while a game password is set
(`bAutoTournamentOnPassword`) or when `bTournamentMode` is on.

## What players see

With `bTopMessages` on (the default), notices appear at the top of the
screen, under the game's own CTF notices ("You have the flag…"), in team
colour. Each notice also goes to the chat feed with the details, such as the
team averages (shown only with `MinPlayersToShowRatings` or more players,
default 6) or the reason for a cancellation.

| Everyone sees (needs `bAnnounce`) | The player concerned sees (needs `bNotifyMoved`) |
|---|---|
| *X will switch to Blue at their next death* | *You will switch to BLUE at your next death* |
| *X moved to Blue to balance the teams* | *You are now on BLUE* (repeated when they first spawn) |
| *X stays on Red - team switch cancelled* | *Team switch cancelled - you stay on RED* |
| *X and Y will swap teams when both are dead* | *You will swap to BLUE with Y when you are both dead* (repeated each respawn while waiting) |
| *X and Y swapped teams to balance them* | |
| *Teams balanced* / *Teams are even* / *Team balancing: ON / OFF* | |

With `bTopMessages` off, notices use center-screen text if `bCenterMessages`
is on, or the chat feed only if both are off.

## Commands

Type these in normal or team chat, or as `mutate …` in the console
(for example `mutate balance status`).

| Command | Who | What it does |
|---|---|---|
| `!balance` | Everyone | Check the teams now and balance them if the gap is over `Tolerance`. |
| `!teams` | Everyone | Show the current team gap. |
| `!balance status` | Admins | Version, on/off state, metric, tolerance and a summary of the loaded ratings. |
| `!balance off` / `!balance on` | Admins | Turn automatic balancing off or on. Saved, so it lasts across maps until switched back. |

`!balance` and `!teams` share a server-wide cooldown (`ChatCommandCooldown`)
and can be turned off with `bChatCommands`. The admin commands always work.

## Settings

All settings are in WebAdmin under **Team Balance**, or in
`System\MutTeamBalance.ini` under `[TeamBalance.MutTeamBalance]`. Changes are
expected to apply from the next map (not yet confirmed in testing).

| Setting | Default | Meaning |
|---|---|---|
| `bEnabled` | True | Master switch for automatic balancing. |
| `bTournamentMode` | False | Never move players. |
| `bAutoTournamentOnPassword` | True | Treat a password-protected server as a tournament and leave teams alone. |
| `BalanceMetric` | DYNAMIC_HYBRID | How a player's score is calculated (see above). |
| `RatingWeight` | 1.0 | Weight of Rating in the hybrid metrics. |
| `EloWeight` | 0.1 | Weight of Elo in the hybrid metrics. |
| `Tolerance` | 4.0 | Act only when the team averages differ by more than this. |
| `TargetGap` | 2.0 | When acting, aim for a gap at or below this. |
| `MinPlayersForBalance` | 3 | Minimum human players for balancing to run. |
| `MinPlayersToShowRatings` | 6 | Below this, announcements show only the gap, not the team averages. |
| `bBalanceOnMatchStart` | True | Run a full pass when the match goes live. |
| `MoveCooldown` | 60 | Seconds between automatic passes. |
| `JoinGraceSeconds` | 90 | During a match, only players who joined within this many seconds can be moved. |
| `MaxMovesPerPlayer` | 1 | Moves per player per map. |
| `EndGuardSeconds` | 180 | No moves in the last N seconds of a timed match. |
| `GoalGuardCaps` | 1 | No moves when a team is within N captures of the goal score. |
| `DeferredMoveTimeout` | 60 | Cancel a queued move after N seconds. |
| `EscalationFactor` | 1.5 | Escalate when the gap exceeds Tolerance × this; 0 = never. |
| `DeferredSwapTimeout` | 90 | Cancel a queued swap after N seconds. |
| `bNotifyMoved` | True | Tell players privately when they are queued, moved or cancelled. |
| `bTopMessages` | True | Show notices at the top of the screen (players download `TeamBalanceMsg_V1`). |
| `bCenterMessages` | True | When top messages are off, use center-screen text instead of chat only. |
| `bAnnounce` | True | Show balancing news to everyone, on screen and in chat. When off, only the players being moved are told. |
| `bChatCommands` | True | Allow the `!balance` and `!teams` player commands. |
| `ChatCommandCooldown` | 60 | Seconds between uses of the player commands (server-wide). |
| `bLogSightings` | True | Record each GUID's names and IP addresses in `TeamBalanceSightings.ini`. |
| `bDisableStockBalancing` | True | Turn off the game's own team balancing. |
| `DefaultUnknownRating` | 25.0 | Mu for players not in the ratings file. |
| `DefaultUnknownSigma` | 8.333 | Sigma for players not in the ratings file. |
| `DefaultUnknownElo` | 0.0 | Elo for players not in the ratings file. |

`Tolerance` and `TargetGap` are in score units, so retune them if you change
`BalanceMetric`. The defaults were chosen for `DYNAMIC_HYBRID`.

## Files

All in the server's `System\` folder:

| File | Written by | Contents |
|---|---|---|
| `MutTeamBalance.ini` | WebAdmin / the mutator | Settings |
| `TeamBalanceRatings.ini` | `GetPlayerRankings.ps1` only | Player ratings |
| `TeamBalanceSightings.ini` | The mutator only | Names and IPs seen for each GUID |

The ratings and sightings files hold player GUIDs and IP addresses. They are
in `.gitignore`; never commit them.

### Sightings file

One section per GUID, used to spot new GUIDs and likely alts (shared names,
shared IPs):

```ini
[0123456789abcdef0123456789abcdef TeamBalanceSightings]
KnownNames=Player|Player2
KnownIPs=203.0.113.7|198.51.100.4
FirstSeen=2026-10-08 19:02
LastSeen=2026-10-08 21:40
TimesSeen=12
```

`KnownIPs` are raw addresses (no port). `TimesSeen` counts maps. Whoever
processes this file should hash the IPs with a secret salt and discard the
raw values. The report that reads it is not part of this repository.

## Ratings file format

`GetPlayerRankings.ps1` produces this; the format is listed here for anyone
writing their own generator.

```ini
[TeamBalance.TeamBalanceRatings]
FormatVersion=1
GeneratedAt=2026-10-21 10:49 UTC
ExpectedCount=321
PlayerRatings=(Guid="0123456789abcdef0123456789abcdef",Elo=7.96,Mu=25,Sigma=8.333,Rating=0)
```

- Plain ASCII, **no BOM**, Windows (CRLF) line endings. The game's ini reader
  silently skips anything else, and the mutator can't work around it.
- One `PlayerRatings` line per GUID; GUIDs are 32 lower-case hex characters.
- Every GUID of a player with alts gets its own line with that player's numbers.
- Numbers use `.` as the decimal point, whatever the PC's region settings.
- `Rating` = Mu − 3 × Sigma.
- `FormatVersion`, `GeneratedAt` and `ExpectedCount` are optional, but they
  let the mutator detect a partly-read file.

## Server log messages

All lines start with `[TeamBalance]`.

| Line | Meaning |
|---|---|
| `v1.1.1 started. Metric=…` | Mutator loaded; shows the version and main settings. |
| `loaded N ratings` | Ratings file read successfully. |
| `ratings summary: …` | Rated vs default entries, date generated, problems found. |
| `ERROR: no ratings could be read` | Followed by a 5-point checklist: file missing or misnamed, wrong header, BOM or encoding, bad line format, server not restarted. A missing file and an unreadable file look the same to the game. |
| `WARNING: …` | Bad GUIDs, duplicates, odd numbers, or `ExpectedCount` not matching what was read. |
| `ratings coverage: N of M players have ratings` | At each match start. |
| `unknown GUID … - using default rating` | Once per GUID per map. |

Admins can see the same summary in game with `!balance status`.

## Stats log

Every team move the mutator makes is written to the OLStats log as

```
G <tab> TeamChange <tab> <playerid> <tab> <team>      (0 = Red, 1 = Blue)
```

This is the same event the game writes when a player joins a team; a swap
writes two lines. Stats tools should use the **latest** `TeamChange` for each
player, so moved players are credited to the team they actually played for.
No suicide or kill line is written for a move.

## Building from source

1. Copy `TeamBalance\Classes\*.uc` to `UT2004\TeamBalance\Classes\` and
   `TeamBalanceMsg_V1\Classes\*.uc` to `UT2004\TeamBalanceMsg_V1\Classes\`.
2. In `UT2004\System\UT2004.ini`, section `[Editor.EditorEngine]`, add, in
   this order, after the existing `EditPackages` lines:
   ```ini
   EditPackages=TeamBalanceMsg_V1
   EditPackages=TeamBalance
   ```
3. Delete the old `System\TeamBalance.u`, then run `ucc make` from `System\`.

**Don't rebuild `TeamBalanceMsg_V1` unless its text changes.** Every build
gets a new package GUID, and a player holding an older build of the same name
can't join. If the message text must change, release it under a new name
(`TeamBalanceMsg_V2`): rename the folder, change `MsgPackage` and the
`class'TeamBalanceMsg_V1.TeamBalanceMessage'` references in
`MutTeamBalance.uc`, and update the `EditPackages` line. `TeamBalance` itself
can be rebuilt freely.

## License

Released into the public domain under [The Unlicense](LICENSE): use, change
and share it freely, with no conditions.
