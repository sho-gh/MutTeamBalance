MutTeamBalance (working title: MutSkillCTF)
Rating-based CTF team balancer for UT2004. Server-side only.

STATUS: v1.1.1. Compiles (UCC 3374, 0 errors / 0 warnings); v1.0.8 did not.
Last version tested live: v1.0.5. v1.0.6 - v1.1.1 are untested in game.
The version is printed in the startup log line and in !balance status.

------------------------------------------------------------------------------
INSTALL
------------------------------------------------------------------------------
Two packages:
  TeamBalance          the mutator. Server only; clients never download it.
                       All ini section headers use [TeamBalance.<ClassName>].
  TeamBalanceMsg_V1    one small message class (~6 KB) that draws the
                       top-of-screen messages. Clients download it. The
                       mutator adds it to the package map itself, so it needs
                       no ServerPackages line.

1. Copy TeamBalance\Classes\*.uc into UT2004\TeamBalance\Classes\ and
   TeamBalanceMsg_V1\Classes\*.uc into UT2004\TeamBalanceMsg_V1\Classes\.
2. UT2004\System\UT2004.ini, [Editor.EditorEngine], in this order:
       EditPackages=TeamBalanceMsg_V1
       EditPackages=TeamBalance
3. Delete the old System\TeamBalance.u (and TeamBalanceMsg_V1.u if rebuilding
   it), run "ucc make" from System.
4. Server: copy BOTH .u files to System\. Add the mutator:
   TeamBalance.MutTeamBalance. Do NOT add TeamBalance to ServerPackages.
5. If the server uses a download redirect, upload TeamBalanceMsg_V1.u.uz2
   ("ucc compress TeamBalanceMsg_V1.u") there too.
6. Put the generated TeamBalanceRatings.ini in UT2004\System\.

REBUILDING TeamBalanceMsg_V1: every build gets a new package GUID, and a
client holding an older build of the same name cannot join. Only rebuild it
when the message text changes, and then release it as TeamBalanceMsg_V2:
rename the folder and class package, change MsgPackage and the
class'TeamBalanceMsg_V1.TeamBalanceMessage' references in MutTeamBalance.uc,
and the EditPackages line. TeamBalance itself can be rebuilt freely.

Files the game uses (all in System\):
  MutTeamBalance.ini         settings (also edited by WebAdmin)
  TeamBalanceRatings.ini     ratings, written ONLY by the admin script
  TeamBalanceSightings.ini   written ONLY by the mutator

------------------------------------------------------------------------------
RATINGS FILE (what the admin script must produce)
------------------------------------------------------------------------------
One line per GUID, plain ASCII, no BOM, under this header:

  [TeamBalance.TeamBalanceRatings]
  PlayerRatings=(Guid="<32 hex, lowercase>",Elo=0.0,Mu=25.0,Sigma=8.333,Rating=0.0)

* Same field names as the bot's FFN_Player_Ranking export; drop Name, change
  the header, lowercase the GUIDs (one in the current export is uppercase).
* ROLL-UPS: write one line for EVERY GUID of a profile, all carrying that
  profile's Elo/Mu/Sigma/Rating. In the current export, alt GUIDs sit at the
  25.0 / 8.333 default, so they must be overwritten from the profile.
  If an alt GUID has its own separate history, the registered profile wins.
* Rating = Mu - 3*Sigma.
* RECOMMENDED: run validate_ratings.py as the last step before upload. It
  strips a hidden BOM, converts UTF-16, fixes line endings, lower-cases GUIDs,
  drops names and duplicates, refuses a file with errors or far fewer entries
  than last time, and adds three header lines the mutator uses as a check:
      FormatVersion=1
      GeneratedAt=2026-10-21 10:49 UTC
      ExpectedCount=321
  Upload OUTPUT only if its exit code is 0.
* The game reads this file once, when the server process starts; a map
  change does not re-read it. Restart the server after each upload.

------------------------------------------------------------------------------
SIGHTINGS FILE (what the report script reads)
------------------------------------------------------------------------------
  [<guid> TeamBalanceSightings]
  KnownNames=Brim|Brim2
  KnownIPs=203.0.113.7|198.51.100.4     <- RAW IPs, no port
  FirstSeen=2026-10-08 19:02
  LastSeen=2026-10-08 21:40
  TimesSeen=12                           <- number of maps seen on

Hash the IPs with a secret salt on the laptop and discard the raw values.
Compare against the registered-GUID list to report new GUIDs and likely alts
(shared names, matching IP hashes, GUIDs never online together).

------------------------------------------------------------------------------
HOW BALANCING WORKS
------------------------------------------------------------------------------
* Humans only (bots and spectators ignored). Runs at MinPlayersForBalance or
  more players (default 3).
* Each player gets a score from BalanceMetric:
    MU_ONLY         Mu
    RATING_ONLY     Rating (Mu - 3*Sigma)
    ELO_ONLY        Elo
    HYBRID          RatingWeight*Rating + EloWeight*Elo
    DYNAMIC_HYBRID  RatingWeight*Rating + EloWeight*Elo*Confidence
                    Confidence = clamp(1 - Sigma/8.333, 0, 1), so Elo counts
                    less for low-confidence players. (This is my reading of
                    "dynamic"; change MetricScore() if you meant something else.)
* Teams are compared by AVERAGE score per player. Sizes must stay within 1.
* Nothing happens unless the gap exceeds Tolerance.
* MATCH START / WARMUP (before the match is live): full pass. Anyone can be
  moved, swaps allowed, up to 3 moves, until the gap is at or below TargetGap.
  Players with no pawn (warmup) move at once; players who are alive (the
  match-start pass runs just after spawning) are queued and switched at their
  next death. A live player is never switched, because switching kills the
  pawn and the stats log records that as a suicide.
* DURING A MATCH (v1.0.3, gentler):
  - Only recent joiners (JoinGraceSeconds, default 90) can be moved. Established
    players move only to fix a team-size gap of 2 or more.
  - One move per pass, no swaps, and it must cut the gap by at least 25%.
  - The move is DEFERRED: it waits until that player dies, then switches them
    while they are dead, so nobody is killed and a flag carrier can't be
    caught mid-carry. It is cancelled after DeferredMoveTimeout (60 s), or if
    it is no longer useful when the player dies.
  - A player is moved at most MaxMovesPerPlayer (1) times per map.
  - No moves in the last EndGuardSeconds (180) of a timed match, in overtime,
    or when a team is within GoalGuardCaps (1) of the goal score.
  - Automatic passes are at least MoveCooldown (60) seconds apart.
  - Players get a private message when they are moved (bNotifyMoved).
  - ESCALATION (v1.0.5): if the gap exceeds Tolerance x EscalationFactor
    (default 1.5 x 4.0 = 6.0), established players become movable, the
    per-player cap goes up by one, and EVEN teams (e.g. 3v3) can be fixed by a
    deferred SWAP: one player from each team, switched only when both are dead
    at the same moment (so team sizes never get out of step). Queued swaps are
    cancelled after DeferredSwapTimeout (90 s). EscalationFactor=0 turns this off.
* MESSAGES (v1.1.0): with bTopMessages (default on) balancing messages show at
  the top of the screen, stacked under the CTF notices ("You have the flag..."),
  in team colour. Every message also goes to chat with the details (team
  averages are shown only at MinPlayersToShowRatings or more players).
    Everyone sees:  X will switch to Blue at their next death / X moved to Blue
                    / X stays on Red - team switch cancelled (reason in chat)
                    / X and Y will swap / X and Y swapped / Teams are even
                    / Team balancing: ON / OFF
    The player sees: You will switch to BLUE at your next death / You are now
                    on BLUE (again when they first spawn) / Team switch
                    cancelled - you stay on RED / swap notices naming the
                    partner, repeated each respawn while waiting.
  With bTopMessages off: center-screen text if bCenterMessages, else chat only.
* Unknown GUIDs get DefaultUnknownRating as MU (default 25), with
  DefaultUnknownSigma and DefaultUnknownElo, i.e. the same numbers as a
  never-rated player in the bot's file. They are logged once per map.
* Tolerance and TargetGap are in SCORE units, so retune them if you change
  BalanceMetric. Defaults (4.0 / 2.0) were picked for DYNAMIC_HYBRID using the
  305-GUID export.

TOURNAMENT MODE: balancing is off when a game password is set
(bAutoTournamentOnPassword) or when bTournamentMode=True (WebAdmin).

CHAT: with MinPlayersToShowRatings or more players, announcements show team
averages; below that they show only the gap and tolerance.
  Teams balanced: Red (4) avg 31.2 | Blue (4) avg 30.8 | gap 0.4 | tolerance 4.0 | moved Brim to Blue
Commands (shared cooldown ChatCommandCooldown): !balance (check now, moves
only if over tolerance) and !teams (show current gap). Also "mutate balance"
and "mutate teams" from the console. Commands work in normal or team chat.
bChatCommands=False turns off these two player commands only; the admin
commands below always work.

STATS LOG (v1.0.8): every team move the mutator makes is written to the OLStats
stats log as  G <tab> TeamChange <tab> <playerid> <tab> <team>  (0 = Red, 1 = Blue),
the same event the stock game writes when a player joins. A swap writes two lines.
Before v1.0.8 these moves were not logged, so the stats bot kept players on their
join team. The stats bot must apply the LATEST TeamChange per player.

LOG MESSAGES ABOUT THE RATINGS FILE (v1.0.7): the game's ini reader runs before
any script code, so the mutator cannot skip a BOM itself. Instead it explains
problems in the server log, all prefixed [TeamBalance]:
  loaded N ratings                   success
  ratings summary: ...               rated vs default entries, problems found
  ERROR: no ratings could be read    followed by a 5-point checklist
                                     (file missing/misnamed, wrong header, BOM or
                                     encoding, bad line format, server not restarted)
  WARNING ... bad GUID / duplicates / odd numbers / ExpectedCount mismatch
  ratings coverage: N of M players have ratings   (at each match start)
A missing file and an unreadable file look identical to the game.
Admins can type  !balance status  in chat for the same summary in game.

ADMIN SWITCH (v1.0.6): a logged-in admin types  !balance off  or  !balance on
in chat (or "mutate balance off" / "mutate balance on" in the console). It
flips the Enabled setting and saves it, so it persists across maps until
switched back, and WebAdmin shows it. Non-admins get a polite refusal.

WEBADMIN: all settings appear under "Team Balance". Changes should apply from
the next map load.

------------------------------------------------------------------------------
VERIFY AT COMPILE (written from memory of the UT2004 API)
------------------------------------------------------------------------------
* PlayerController.GetPlayerIDHash(), GetPlayerNetworkAddress()
* GameInfo.ChangeTeam(Controller, int, bool), Pawn.PlayerChangedTeam()
* PlayerReplicationInfo.HasFlag, .bBot, .bOnlySpectator
* BroadcastHandler.AcceptBroadcastText signature, RegisterBroadcastHandler()
* AccessControl.RequiresPassword()
* v1.0.3: GameInfo.bOverTime, GameReplicationInfo.TimeLimit / RemainingTime /
  GoalScore / Teams[i].Score, dynamic array Remove(index, count)
* TeamGame.bBalanceTeams / bPlayersBalanceTeams
* PlayInfo.AddSetting() argument order and the "Select" option format
* Struct-array config parsing of the PlayerRatings lines
