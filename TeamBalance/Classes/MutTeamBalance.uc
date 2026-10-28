//=============================================================================
// MutTeamBalance  (working title: MutSkillCTF)
// Version: 1.1.1
//
// REVISION HISTORY:
// v1.1.1 - Bug fixes:
//          * admin commands (!balance on / off / status) work in chat even
//            when bChatCommands is off; before, the chat watcher was not
//            started at all and only the "mutate" versions worked.
//          * commands typed in team chat are recognised too.
//          * ratings are read once. The v1.0.2 retry loop re-read the same
//            in-memory copy (the engine reads an ini file once per server
//            process), so it could never succeed; a failed load now logs the
//            checklist straight away.
//          * the version is shown in the startup log line and !balance status.
// v1.1.0 - Player notifications:
//          * messages show at the top of the screen, stacked under the CTF
//            notices, colored by team (bTopMessages). Needs the small client
//            package TeamBalanceMsg_V1, which the mutator adds to the package
//            map itself. Details (averages, reasons) always go to chat too.
//          * everyone is told, by name, when a player is queued to switch,
//            when the switch happens, and when it is cancelled (with reason).
//          * the player concerned is told privately, reminded each time they
//            respawn while still waiting (swaps), and told their new team again
//            when they first spawn on it. Private notices are sent last, so a
//            public message can no longer cover them.
//          * match start says "Teams are even" when nothing needs changing.
//          * messages go to each player directly; Level.Game.Broadcast shares
//            a 200-chars-per-second limit with chat and dropped them silently.
// v1.0.9 - Fixes for v1.0.8, which did not compile:
//          * the TeamChange stats line now goes through Level.Game.GameStats
//            (GameEvent is not a GameInfo function).
//          * a live player is never switched (switching kills the pawn, which
//            the stats log records as a suicide). The match-start pass runs
//            just after spawning, so it now moves players without a pawn at
//            once and queues the rest for their next death, like mid-match.
// v1.0.8 - Team moves are now written to the stats log. The stock game only
//          logs a "TeamChange" event when ChangeTeam is called with
//          bNewTeam=true (a player joining), and this mutator calls it with
//          false, so balance moves were invisible to OLStats and the bot
//          recorded players on their join team (e.g. a swapped player was
//          credited to the wrong team). ExecuteMove now logs the same event
//          the stock code does:  G <tab> TeamChange <tab> <playerid> <tab> <team>
// v1.0.7 - Ratings file diagnostics. The engine's ini reader runs before any
//          script code, so the game itself cannot skip a BOM; instead the log
//          now explains what is wrong whenever it can:
//          * full checklist of likely causes when 0 ratings load
//          * per-entry checks: bad GUID, duplicates, bad numbers, upper-case
//          * optional FormatVersion / GeneratedAt / ExpectedCount header lines
//            (written by validate_ratings.py) catch partly-read files
//          * ratings coverage line at match start (how many players known)
//          * admin command  !balance status  shows the same info in game
// v1.0.6 - In-game admin switch: a logged-in admin types  !balance off  or
//          !balance on  in chat (or "mutate balance off" / "mutate balance on"
//          in the console). It flips the Enabled setting and saves it, so it
//          stays that way across maps until switched back (and WebAdmin shows
//          it). Everyone sees "Team balancing: OFF (switched off)" within a
//          couple of seconds, and again at each match start.
// v1.0.5 - Fixes uncorrectable gaps on even teams (e.g. 3v3 sitting 10 points
//          apart, because mid-match swaps were disabled in v1.0.3):
//          * Escalation: when the gap exceeds Tolerance x EscalationFactor,
//            established players become movable and the per-player move cap
//            is raised by one.
//          * Deferred SWAPS: when escalated and teams are even, two players
//            (one per team) swap. The swap happens only when BOTH are dead at
//            the same moment, so team sizes never get out of step.
//          * The "no move found" log line now says why (sizes, movable count,
//            escalation threshold).
// v1.0.4 - Tuned for Instagib CTF (very fast respawns, very busy chat):
//          * Queued moves are checked every 0.25 s (was 0.5) so the short
//            window while a player is dead is not missed.
//          * bCenterMessages (default on): balance announcements and private
//            notices use center-screen text ('CriticalEvent') so they don't
//            scroll away in the death-message flood.
// v1.0.3 - Less disruptive moves (feedback from first live night):
//          * Mid-match moves are DEFERRED: the player is switched only while
//            dead/awaiting respawn, so nobody is killed and a flag carrier
//            can never be caught mid-carry. Cancelled after DeferredMoveTimeout.
//          * Mid-match, only recent joiners (JoinGraceSeconds) are movable;
//            established players move only at match start/warmup or to fix a
//            team-size gap of 2+.
//          * Max MaxMovesPerPlayer moves per player per map; one move per
//            pass; no swaps mid-match; a move must cut the gap by 25%+.
//          * No moves near the end of a match (EndGuardSeconds / GoalGuardCaps
//            / overtime).
//          * Moved players get a private message. MoveCooldown default 60.
// v1.0.2 - Ratings that load late (0 entries on the first map after a server
//          start) are now retried every poll for ~30 s; unknown-GUID logging
//          is held back until loading has settled; load attempts are logged.
// v1.0.1 - Fixed compile error in LoadRatings() ("Unrecognized type 
//          'RatingEntry' within 'TeamBalanceRatings'") by removing the local 
//          struct declaration and accessing PlayerRatings directly via default.
// v1.0.0 - Initial version.
//
// Rating-based team balancer for UT2004 CTF. Server-side only.
//   * Ratings are read from System\TeamBalanceRatings.ini (written daily by
//     the admin script, one line per GUID, roll-ups already applied).
//   * Every GUID seen is recorded in System\TeamBalanceSightings.ini for the
//     new-GUID / possible-alt report.
//   * Settings live in System\MutTeamBalance.ini and in WebAdmin.
//
// To add a new balancing type later: add a value to EBalanceMetric and a
// branch in MetricScore(). Everything else works on the resulting score.
//=============================================================================
class MutTeamBalance extends Mutator
    config(MutTeamBalance);

enum EBalanceMetric
{
    MU_ONLY,            // OpenSkill mu
    RATING_ONLY,        // OpenSkill ordinal (mu - 3*sigma), the file's Rating
    ELO_ONLY,           // Elo from the bot
    HYBRID,             // RatingWeight*Rating + EloWeight*Elo
    DYNAMIC_HYBRID      // like HYBRID, but Elo counts less for low-confidence players
};

const MaxMovesPerPass = 3;
const RecheckInterval = 30.0;
const PollInterval    = 0.25;  // fast tick: only watches queued moves
const SlowInterval    = 2.0;   // full roster/balance work
const NewPlayerSigma  = 8.333;
const Version         = "1.1.1";
const MsgPackage     = "TeamBalanceMsg_V1";  // must match the class'...' references below
const NoticeTimeout   = 30.0;  // give up on a "you are now on X" spawn notice after this

// TeamBalanceMessage switches (see that class for the text)
const MSG_QUEUED      = 0;     // + team
const MSG_MOVED       = 2;     // + team
const MSG_STAYS       = 4;     // + team
const MSG_SWAPQUEUED  = 6;
const MSG_SWAPPED     = 7;
const MSG_BALANCED    = 8;
const MSG_EVEN        = 9;
const MSG_ON          = 10;
const MSG_OFF         = 11;
const MSG_YOUQUEUED   = 20;    // + team
const MSG_YOUMOVED    = 22;    // + team
const MSG_YOUSTAY     = 24;    // + team
const MSG_YOUSWAP     = 26;    // + team

// ---------------------------------------------------------------- settings
var config bool           bEnabled;
var config EBalanceMetric BalanceMetric;
var config float          EloWeight;
var config float          RatingWeight;
var config int            ChatCommandCooldown;
var config bool           bBalanceOnMatchStart;
var config int            MinPlayersForBalance;
var config float          DefaultUnknownRating;   // mu given to unknown GUIDs
var config float          DefaultUnknownSigma;
var config float          DefaultUnknownElo;
var config float          Tolerance;              // act only if team gap exceeds this
var config float          TargetGap;              // once acting, aim for this gap
var config int            MoveCooldown;           // seconds between automatic passes
var config bool           bTournamentMode;        // manual override: balancing off
var config bool           bAutoTournamentOnPassword;
var config bool           bDisableStockBalancing;
var config bool           bChatCommands;
var config bool           bAnnounce;
var config bool           bLogSightings;
var config int            MinPlayersToShowRatings;
var config int            JoinGraceSeconds;       // mid-match: only players newer than this can be moved
var config int            MaxMovesPerPlayer;      // per map
var config int            EndGuardSeconds;        // no moves in the last N seconds of a timed match
var config int            GoalGuardCaps;          // no moves when a team is within N caps of the goal score
var config int            DeferredMoveTimeout;    // give up on a queued move after N seconds
var config bool           bNotifyMoved;           // private message to moved players
var config bool           bCenterMessages;        // center-screen text instead of (fast-scrolling) chat
var config float          EscalationFactor;       // gap > Tolerance*this => established players can be moved (0 = never)
var config int            DeferredSwapTimeout;    // give up on a queued swap after N seconds
var config bool           bTopMessages;           // top-of-screen messages (clients download MsgPackage)

// ---------------------------------------------------------- runtime state
var array<string> CacheGuid;
var array<float>  CacheElo;
var array<float>  CacheMu;
var array<float>  CacheSigma;
var array<float>  CacheRating;

var array<Controller> GCtrl;     // current human roster
var array<float>      GScore;
var array<int>        GTeam;
var int   N0, N1;
var float Sum0, Sum1;

var array<string> SeenGuid;      // sightings written this map
var array<string> UnknownGuid;   // unknown GUIDs already logged this map

var bool  bWasActive, bWasWaiting;
var int   LastSig;
var string RatingsInfo;     // one-line summary for !balance status
var float LastActionTime, LastCmdTime, LastRecheck;
var PlayerController PendingPC;
var int   PendingCmd;            // 0 = !balance, 1 = !teams
var TeamBalanceBH BH;
var float LastSlowTick;

var array<int>   TrkID;          // per-player tracking (by PlayerID), per map
var array<float> TrkJoin;
var array<int>   TrkMoves;

var array<Controller> PendCtrl;  // queued moves, waiting for the player to die
var array<int>        PendTeam;
var array<float>      PendExpire;
var array<Controller> PendPartner;      // second player of a swap (None for a single move)
var array<int>        PendPartnerTeam;  // -1 when there is no partner
var array<Pawn>       PendPawn;         // pawn last seen for each queued player (respawn reminders)
var array<Pawn>       PendPartnerPawn;
var bool bEscalated;                    // this pass is dealing with a big gap

var array<PlayerController>      OutPC;     // private notices, sent at the end of each tick so they
var array<int>                   OutSwitch; // always arrive after any public announcement made in
var array<PlayerReplicationInfo> OutPRI1;   // the same tick (-1 switch = plain text, no top message)
var array<PlayerReplicationInfo> OutPRI2;
var array<string>                OutMsg;
var array<string>                OutDetail;
var array<byte>                  OutQuiet;  // 1 = screen only, no chat line (reminders)

var array<Controller> NoticeCtrl;       // moved players: told their new team again when they spawn
var array<int>        NoticeTeam;
var array<float>      NoticeExpire;

//=============================================================================
// Setup
//=============================================================================
function PreBeginPlay()
{
    Super.PreBeginPlay();
    // Only works during game init, which is when mutators are spawned.
    if (bTopMessages)
        AddToPackageMap(MsgPackage);
}

function PostBeginPlay()
{
    Super.PostBeginPlay();

    LoadRatings();
    LastCmdTime    = -10000.0;
    LastActionTime = -10000.0;
    LastSlowTick   = -10000.0;
    LastRecheck    = 0.0;
    bWasActive     = BalancingActive();
    bWasWaiting    = Level.Game.bWaitingToStartMatch;

    // Always watch chat: admin commands work even when bChatCommands is off
    // (HandleChat applies that setting to the player commands).
    if (Level.Game.BroadcastHandler != None)
    {
        BH = Spawn(class'TeamBalanceBH');
        BH.Mut = Self;
        Level.Game.BroadcastHandler.RegisterBroadcastHandler(BH);
    }

    if (bDisableStockBalancing && TeamGame(Level.Game) != None)
    {
        TeamGame(Level.Game).bBalanceTeams = false;
        TeamGame(Level.Game).bPlayersBalanceTeams = false;
    }

    SetTimer(PollInterval, true);
    Log("[TeamBalance] v" $ Version $ " started. Metric=" $ MetricName()
        $ " Tolerance=" $ Fmt1(Tolerance) $ " Target=" $ Fmt1(TargetGap)
        $ " MinPlayers=" $ MinPlayersForBalance
        $ " Active=" $ bWasActive);
}

function LoadRatings()
{
    local int i, j, k, n, nBad, nDup, nBadNum, nUpper, nDefault, nShown;
    local string G;
    local float Mu, Sg, Rt;

    CacheGuid.Length   = 0;
    CacheElo.Length    = 0;
    CacheMu.Length     = 0;
    CacheSigma.Length  = 0;
    CacheRating.Length = 0;

    n = class'TeamBalanceRatings'.default.PlayerRatings.Length;
    for (i = 0; i < n; i++)
    {
        G  = class'TeamBalanceRatings'.default.PlayerRatings[i].Guid;
        Mu = class'TeamBalanceRatings'.default.PlayerRatings[i].Mu;
        Sg = class'TeamBalanceRatings'.default.PlayerRatings[i].Sigma;
        Rt = class'TeamBalanceRatings'.default.PlayerRatings[i].Rating;

        if (G != Locs(G))
            nUpper++;
        if (!IsGuid(G))
        {
            nBad++;
            if (nShown < 5)
            {
                Log("[TeamBalance] WARNING: ratings entry #" $ (i + 1) $ " has a bad GUID '" $ G
                    $ "' (needs 32 hex characters) - entry ignored. A malformed line usually shows up like this.");
                nShown++;
            }
            continue;
        }
        if (Sg <= 0.0 || Mu < 0.0 || Mu > 60.0 || Abs(Rt - (Mu - 3.0 * Sg)) > 0.5)
            nBadNum++;
        if (Mu == DefaultUnknownRating && Sg >= 8.3)
            nDefault++;

        k = CacheGuid.Length;
        CacheGuid[k]   = Locs(G);
        CacheElo[k]    = class'TeamBalanceRatings'.default.PlayerRatings[i].Elo;
        CacheMu[k]     = Mu;
        CacheSigma[k]  = Sg;
        CacheRating[k] = Rt;
    }

    // ---- nothing usable loaded ----
    if (CacheGuid.Length == 0)
    {
        RatingsInfo = "NO RATINGS LOADED (all players treated as unknown)";
        LogRatingsFailure();
        return;
    }

    LastSig = -1;             // force a balance check with the real ratings
    Log("[TeamBalance] loaded " $ CacheGuid.Length $ " ratings");

    // duplicates (the first entry for a GUID wins)
    if (CacheGuid.Length <= 2000)
        for (i = 1; i < CacheGuid.Length; i++)
            for (j = 0; j < i; j++)
                if (CacheGuid[i] == CacheGuid[j]) { nDup++; break; }

    // optional integrity header written by validate_ratings.py
    if (class'TeamBalanceRatings'.default.FormatVersion == 0)
        Log("[TeamBalance] note: ratings file has no FormatVersion/ExpectedCount header lines (older script) - integrity check skipped");
    else
    {
        if (class'TeamBalanceRatings'.default.FormatVersion > 1)
            Log("[TeamBalance] WARNING: ratings file format version " $ class'TeamBalanceRatings'.default.FormatVersion
                $ " is newer than this mutator understands (1)");
        if (class'TeamBalanceRatings'.default.ExpectedCount != n)
            Log("[TeamBalance] WARNING: ratings file says it has " $ class'TeamBalanceRatings'.default.ExpectedCount
                $ " entries but the game read " $ n $ " - some lines were probably not understood (bad formatting?)");
    }

    if (nBad > 0)
        Log("[TeamBalance] WARNING: " $ nBad $ " ratings entries ignored because of a bad GUID");
    if (nDup > 0)
        Log("[TeamBalance] WARNING: " $ nDup $ " duplicate GUIDs in the ratings file (the first one is used)");
    if (nBadNum > 0)
        Log("[TeamBalance] WARNING: " $ nBadNum $ " entries have odd numbers (sigma <= 0, mu outside 0-60, or Rating not equal to Mu-3*Sigma)");
    if (nUpper > 0)
        Log("[TeamBalance] note: " $ nUpper $ " GUIDs were upper-case (handled automatically)");

    RatingsInfo = CacheGuid.Length $ " ratings (" $ (CacheGuid.Length - nDefault) $ " rated, " $ nDefault $ " at default)"
        $ ", generated " $ class'TeamBalanceRatings'.default.GeneratedAt
        $ ", problems: " $ (nBad + nDup + nBadNum);
    Log("[TeamBalance] ratings summary: " $ RatingsInfo);
}

// Called when the ratings file gave no usable entries. The engine reads an
// ini file once per server process, so there is no point retrying.
function LogRatingsFailure()
{
    Log("[TeamBalance] ERROR: no ratings could be read. All players will be rated as unknown (default).");
    Log("[TeamBalance] A missing file and an empty/unreadable file look the same to the game. Check, in this order:");
    Log("[TeamBalance]   1) TeamBalanceRatings.ini exists, is named exactly that, and is in the same System folder as MutTeamBalance.ini");
    Log("[TeamBalance]   2) the first line is exactly [TeamBalance.TeamBalanceRatings]");
    Log("[TeamBalance]   3) the file has no hidden BOM and is plain ASCII with Windows (CRLF) line endings");
    Log("[TeamBalance]   4) every line looks like PlayerRatings=(Guid=\"32 hex\",Elo=0.0,Mu=25.0,Sigma=8.333,Rating=0.0)");
    Log("[TeamBalance]   5) the server was fully stopped and started after the file was uploaded");
}

static function bool IsGuid(string S)
{
    local int i;

    if (Len(S) != 32)
        return false;
    S = Locs(S);
    for (i = 0; i < 32; i++)
        if (InStr("0123456789abcdef", Mid(S, i, 1)) < 0)
            return false;
    return true;
}

// How many of the players currently connected have a real rating?
function LogRatingCoverage()
{
    local int i, nUnknown;
    local float Elo, Mu, Sg, Rt;

    for (i = 0; i < GCtrl.Length; i++)
        if (!LookupRating(Locs(PlayerController(GCtrl[i]).GetPlayerIDHash()), Elo, Mu, Sg, Rt))
            nUnknown++;
    Log("[TeamBalance] ratings coverage: " $ (GCtrl.Length - nUnknown) $ " of " $ GCtrl.Length
        $ " players have ratings; " $ nUnknown $ " treated as unknown");
}

// Admin-only in-game status line.
function ShowStatus(PlayerController PC)
{
    local string S;

    if (PC.PlayerReplicationInfo == None || !PC.PlayerReplicationInfo.bAdmin)
    {
        Tell(PC, "Only admins can use that.");
        return;
    }
    if (BalancingActive())
        S = "Balancing ON";
    else
        S = "Balancing OFF (" $ InactiveReason() $ ")";
    Tell(PC, "v" $ Version $ " | " $ S $ " | " $ MetricName() $ " | tolerance " $ Fmt1(Tolerance) $ " | ratings: " $ RatingsInfo);
}

//=============================================================================
// Active / tournament mode
//=============================================================================
function bool PasswordSet()
{
    return (Level.Game.AccessControl != None && Level.Game.AccessControl.RequiresPassword());
}

function bool BalancingActive()
{
    if (!bEnabled) return false;
    if (bTournamentMode) return false;
    if (bAutoTournamentOnPassword && PasswordSet()) return false;
    return true;
}

function string InactiveReason()
{
    if (!bEnabled) return "switched off";
    if (bTournamentMode) return "tournament mode";
    if (bAutoTournamentOnPassword && PasswordSet()) return "tournament mode - server password set";
    return "";
}

//=============================================================================
// Main loop
//=============================================================================
function Timer()
{
    ProcessDeferred();    // cheap; runs every tick so queued moves happen right at death
    ProcessNotices();

    if (Level.TimeSeconds - LastSlowTick >= SlowInterval)
    {
        LastSlowTick = Level.TimeSeconds;
        SlowTimer();
    }
    FlushTells();         // private notices last, after any public announcement
}

function SlowTimer()
{
    local bool bActive, bStart;
    local int Sig;

    bActive = BalancingActive();
    if (bActive != bWasActive)
    {
        bWasActive = bActive;
        AnnounceOnOff(bActive);
    }

    BuildRoster();
    if (bLogSightings)
        RecordSightings();

    bStart = (bWasWaiting && !Level.Game.bWaitingToStartMatch);
    bWasWaiting = Level.Game.bWaitingToStartMatch;

    if (bStart)
    {
        AnnounceOnOff(bActive);
        LogRatingCoverage();
    }

    ProcessPending();

    if (!bActive || Level.Game.bGameEnded)
        return;

    Sig = RosterSignature();
    if (bStart && bBalanceOnMatchStart)
    {
        RunBalance(true, false);
        LastRecheck = Level.TimeSeconds;
    }
    else if ((Sig != LastSig || Level.TimeSeconds - LastRecheck >= RecheckInterval)
             && Level.TimeSeconds - LastActionTime >= MoveCooldown)
    {
        RunBalance(false, false);
        LastRecheck = Level.TimeSeconds;
    }
    LastSig = Sig;
}

function int RosterSignature()
{
    local int i, Sig;

    Sig = GCtrl.Length * 1000;
    for (i = 0; i < GCtrl.Length; i++)
        if (GCtrl[i] != None && GCtrl[i].PlayerReplicationInfo != None)
            Sig += GCtrl[i].PlayerReplicationInfo.PlayerID;
    return Sig;
}

//=============================================================================
// Roster + scores
//=============================================================================
function int BuildRoster()
{
    local Controller C;
    local PlayerController PC;
    local int n;

    GCtrl.Length  = 0;
    GScore.Length = 0;
    GTeam.Length  = 0;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        PC = PlayerController(C);
        if (PC == None || PC.PlayerReplicationInfo == None)
            continue;
        if (PC.PlayerReplicationInfo.bOnlySpectator || PC.PlayerReplicationInfo.bBot)
            continue;
        if (PC.PlayerReplicationInfo.Team == None)
            continue;

        n = GCtrl.Length;
        TrackIndex(PC.PlayerReplicationInfo.PlayerID);   // remembers when we first saw them
        GCtrl[n]  = C;
        GTeam[n]  = PC.PlayerReplicationInfo.Team.TeamIndex;
        GScore[n] = ScoreFor(PC);
    }
    return GCtrl.Length;
}

function float ScoreFor(PlayerController PC)
{
    local string Hash;
    local float Elo, Mu, Sigma, Rating;

    Hash = Locs(PC.GetPlayerIDHash());
    if (!LookupRating(Hash, Elo, Mu, Sigma, Rating))
        NoteUnknown(Hash, PC.PlayerReplicationInfo.PlayerName);
    return MetricScore(Elo, Mu, Sigma, Rating);
}

function bool LookupRating(string Hash, out float Elo, out float Mu, out float Sigma, out float Rating)
{
    local int i;

    for (i = 0; i < CacheGuid.Length; i++)
    {
        if (CacheGuid[i] == Hash)
        {
            Elo = CacheElo[i];  Mu = CacheMu[i];
            Sigma = CacheSigma[i];  Rating = CacheRating[i];
            return true;
        }
    }
    // Unknown GUID: same numbers the bot gives a never-rated player.
    Mu     = DefaultUnknownRating;
    Sigma  = DefaultUnknownSigma;
    Elo    = DefaultUnknownElo;
    Rating = Mu - 3.0 * Sigma;
    return false;
}

function NoteUnknown(string Hash, string PlayerName)
{
    local int i;

    if (Hash == "")
        return;
    for (i = 0; i < UnknownGuid.Length; i++)
        if (UnknownGuid[i] == Hash)
            return;
    UnknownGuid[UnknownGuid.Length] = Hash;
    Log("[TeamBalance] unknown GUID " $ Hash $ " (" $ PlayerName $ ") - using default rating");
}

// ---- the one place that turns bot data into a balancing score ------------
function float MetricScore(float Elo, float Mu, float Sigma, float Rating)
{
    local float Conf;

    if (BalanceMetric == MU_ONLY)      return Mu;
    if (BalanceMetric == RATING_ONLY)  return Rating;
    if (BalanceMetric == ELO_ONLY)     return Elo;
    if (BalanceMetric == HYBRID)       return RatingWeight * Rating + EloWeight * Elo;

    // DYNAMIC_HYBRID: confidence is 0 for a brand-new player (sigma at its
    // starting value) and approaches 1 as sigma shrinks. Elo is scaled by it.
    Conf = FClamp(1.0 - Sigma / NewPlayerSigma, 0.0, 1.0);
    return RatingWeight * Rating + EloWeight * Elo * Conf;
}

//=============================================================================
// Team math (works on the GTeam / GScore arrays)
//=============================================================================
function Recompute()
{
    local int i;

    Sum0 = 0.0;  Sum1 = 0.0;  N0 = 0;  N1 = 0;
    for (i = 0; i < GTeam.Length; i++)
    {
        if (GTeam[i] == 0) { Sum0 += GScore[i]; N0++; }
        else               { Sum1 += GScore[i]; N1++; }
    }
}

// Gap in AVERAGE score per player (fair for odd team sizes).
function float Gap()
{
    local float A0, A1;

    Recompute();
    if (N0 > 0) A0 = Sum0 / N0;
    if (N1 > 0) A1 = Sum1 / N1;
    return Abs(A0 - A1);
}

function int IAbs(int V)
{
    if (V < 0) return -V;
    return V;
}

function int TrackIndex(int PlayerID)
{
    local int i;

    for (i = 0; i < TrkID.Length; i++)
        if (TrkID[i] == PlayerID)
            return i;
    i = TrkID.Length;
    TrkID[i]    = PlayerID;
    TrkJoin[i]  = Level.TimeSeconds;
    TrkMoves[i] = 0;
    return i;
}

function bool IsPending(Controller C)
{
    local int i;

    for (i = 0; i < PendCtrl.Length; i++)
        if (PendCtrl[i] == C || PendPartner[i] == C)
            return true;
    return false;
}

function int RosterIndexOf(Controller C)
{
    local int i;

    for (i = 0; i < GCtrl.Length; i++)
        if (GCtrl[i] == C)
            return i;
    return -1;
}

// bAnyone = true at match start / warmup, or when fixing a team-size gap.
// bAnyone = true at match start / warmup, when escalated, or when fixing a team-size gap.
function bool Movable(int i, bool bAnyone)
{
    local int T, Cap;

    if (GCtrl[i] == None || GCtrl[i].PlayerReplicationInfo == None)
        return false;
    if (GCtrl[i].PlayerReplicationInfo.HasFlag != None)   // never queue a flag carrier
        return false;
    if (IsPending(GCtrl[i]))
        return false;
    T = TrackIndex(GCtrl[i].PlayerReplicationInfo.PlayerID);
    Cap = MaxMovesPerPlayer;
    if (bEscalated)
        Cap++;
    if (TrkMoves[T] >= Cap)
        return false;
    if (!bAnyone && Level.TimeSeconds - TrkJoin[T] > JoinGraceSeconds)
        return false;
    return true;
}

function int CountMovable()
{
    local int i, n;

    for (i = 0; i < GCtrl.Length; i++)
        if (Movable(i, bEscalated))
            n++;
    return n;
}

// True when moving people would be unwelcome: overtime, last minutes of a
// timed match, or a team one capture from the goal score.
function bool NearEnd()
{
    local GameReplicationInfo GRI;
    local int i;

    if (Level.Game.bOverTime)
        return true;
    GRI = Level.Game.GameReplicationInfo;
    if (GRI == None)
        return false;
    if (EndGuardSeconds > 0 && GRI.TimeLimit > 0 && GRI.RemainingTime < EndGuardSeconds)
        return true;
    if (GoalGuardCaps > 0 && GRI.GoalScore > 0)
    {
        for (i = 0; i < 2; i++)
            if (GRI.Teams[i] != None && GRI.GoalScore - GRI.Teams[i].Score <= GoalGuardCaps)
                return true;
    }
    return false;
}

// Finds the single move or swap that lowers the gap the most.
// Size rule: teams must stay within 1 player of each other.
// Finds the best move (and, at match start/warmup only, the best swap).
// Size rule: teams must stay within 1 player of each other.
// Finds the best move (and, at match start/warmup or when escalated, the best swap).
// Size rule: teams must stay within 1 player of each other.
function bool FindBestAction(float GapNow, bool bFull, out int BestA, out int BestB)
{
    local int i, j, D0, D;
    local float G, BestG;
    local bool bFound, bOpen;

    Recompute();
    D0 = IAbs(N0 - N1);
    bOpen = (bFull || bEscalated || D0 > 1);
    if (D0 > 1)     BestG = 100000.0;         // size problem: any fixing move will do
    else if (bFull) BestG = GapNow - 0.05;    // match start: any real improvement
    else            BestG = GapNow * 0.75;    // mid-match: must cut the gap by 25%+
    bFound = false;

    // single moves
    for (i = 0; i < GCtrl.Length; i++)
    {
        if (!Movable(i, bOpen)) continue;
        GTeam[i] = 1 - GTeam[i];
        G = Gap();
        D = IAbs(N0 - N1);
        GTeam[i] = 1 - GTeam[i];
        if (D > 1 && D >= D0) continue;
        if (G < BestG) { BestG = G; BestA = i; BestB = -1; bFound = true; }
    }

    // swaps: match start / warmup (immediate) or escalated (deferred, both must be dead)
    if ((bFull || bEscalated) && D0 <= 1)
    {
        for (i = 0; i < GCtrl.Length; i++)
        {
            if (GTeam[i] != 0 || !Movable(i, true)) continue;
            for (j = 0; j < GCtrl.Length; j++)
            {
                if (GTeam[j] != 1 || !Movable(j, true)) continue;
                GTeam[i] = 1;  GTeam[j] = 0;
                G = Gap();
                GTeam[i] = 0;  GTeam[j] = 1;
                if (G < BestG) { BestG = G; BestA = i; BestB = j; bFound = true; }
            }
        }
    }

    Recompute();
    return bFound;
}

// Actually switches a player's team. Callers make sure it is a good moment
// (dead/awaiting respawn, or match start/warmup).
function bool ExecuteMove(Controller C, int NewTeam, out string MovedText)
{
    local int T;

    if (C == None || C.PlayerReplicationInfo == None)
        return false;
    // Never switch a live pawn: the game would have to kill it, and that is
    // logged as a suicide (K line with no killer, -1 self_frag). Live players
    // are queued instead and switched at their next death.
    if (C.Pawn != None)
        return false;
    if (!Level.Game.ChangeTeam(C, NewTeam, false))
        return false;
    // Stock code logs this only for new joiners (bNewTeam=true); do it ourselves
    // so OLStats / the stats bot see the move. GameEvent is not on GameInfo,
    // so go to the stats actor directly.
    if (Level.Game.GameStats != None)
        Level.Game.GameStats.GameEvent("TeamChange", string(NewTeam), C.PlayerReplicationInfo);

    T = TrackIndex(C.PlayerReplicationInfo.PlayerID);
    TrkMoves[T]++;
    MovedText = MovedText $ " | moved " $ C.PlayerReplicationInfo.PlayerName $ " to " $ TeamName(NewTeam);
    if (bNotifyMoved && PlayerController(C) != None)
    {
        TellMsg(PlayerController(C), MSG_YOUMOVED + NewTeam, C.PlayerReplicationInfo, None, "", "");
        AddSpawnNotice(C, NewTeam);    // say it again when they spawn on the new team
    }
    return true;
}

function bool MovePlayer(int Idx, int NewTeam, out string MovedText)
{
    if (!ExecuteMove(GCtrl[Idx], NewTeam, MovedText))
        return false;
    GTeam[Idx] = NewTeam;
    return true;
}

// ---- deferred (mid-match) moves ------------------------------------------
function QueueMove(int Idx, int NewTeam)
{
    local int n;

    n = PendCtrl.Length;
    PendCtrl[n]         = GCtrl[Idx];
    PendTeam[n]         = NewTeam;
    PendPartner[n]      = None;
    PendPartnerTeam[n]  = -1;
    PendExpire[n]       = Level.TimeSeconds + DeferredMoveTimeout;
    PendPawn[n]         = GCtrl[Idx].Pawn;
    PendPartnerPawn[n]  = None;
    AnnounceMsg(MSG_QUEUED + NewTeam, GCtrl[Idx].PlayerReplicationInfo, None, "", "");
    if (bNotifyMoved && PlayerController(GCtrl[Idx]) != None)
        TellMsg(PlayerController(GCtrl[Idx]), MSG_YOUQUEUED + NewTeam, GCtrl[Idx].PlayerReplicationInfo, None, "", "");
}

// Two players, one per team. Executed only when both are dead at the same time.
function QueueSwap(int A, int B)
{
    local int n;

    n = PendCtrl.Length;
    PendCtrl[n]         = GCtrl[A];
    PendTeam[n]         = 1 - GTeam[A];
    PendPartner[n]      = GCtrl[B];
    PendPartnerTeam[n]  = 1 - GTeam[B];
    PendExpire[n]       = Level.TimeSeconds + DeferredSwapTimeout;
    PendPawn[n]         = GCtrl[A].Pawn;
    PendPartnerPawn[n]  = GCtrl[B].Pawn;
    AnnounceMsg(MSG_SWAPQUEUED, GCtrl[A].PlayerReplicationInfo, GCtrl[B].PlayerReplicationInfo, "", "");
    if (bNotifyMoved)
    {
        TellMsg(PlayerController(GCtrl[A]), MSG_YOUSWAP + 1 - GTeam[A],
            GCtrl[A].PlayerReplicationInfo, GCtrl[B].PlayerReplicationInfo, "", "");
        TellMsg(PlayerController(GCtrl[B]), MSG_YOUSWAP + 1 - GTeam[B],
            GCtrl[B].PlayerReplicationInfo, GCtrl[A].PlayerReplicationInfo, "", "");
    }
}

function RemovePending(int i)
{
    PendCtrl.Remove(i, 1);
    PendTeam.Remove(i, 1);
    PendExpire.Remove(i, 1);
    PendPartner.Remove(i, 1);
    PendPartnerTeam.Remove(i, 1);
    PendPawn.Remove(i, 1);
    PendPartnerPawn.Remove(i, 1);
}

// Drops a queued move/swap and tells everyone the player(s) stay put, and why.
function CancelPending(int i, string Reason)
{
    NotifyStays(PendCtrl[i], Reason);
    if (PendPartnerTeam[i] >= 0)
        NotifyStays(PendPartner[i], Reason);
    RemovePending(i);
}

function NotifyStays(Controller C, string Reason)
{
    local int T;

    if (C == None || C.PlayerReplicationInfo == None || C.PlayerReplicationInfo.Team == None)
        return;    // left the server or went to spectate
    T = C.PlayerReplicationInfo.Team.TeamIndex;
    AnnounceMsg(MSG_STAYS + T, C.PlayerReplicationInfo, None, "", Reason);
    if (bNotifyMoved && PlayerController(C) != None)
        TellMsg(PlayerController(C), MSG_YOUSTAY + T, C.PlayerReplicationInfo, None, "", Reason);
}

// A queued player who has respawned (e.g. waiting for a swap partner to die)
// is reminded once per new life.
function RemindIfRespawned(int i)
{
    local Controller C, P;

    C = PendCtrl[i];
    P = PendPartner[i];
    if (C.Pawn != None && C.Pawn != PendPawn[i])
    {
        PendPawn[i] = C.Pawn;
        RemindPending(C, PendTeam[i], P, PendPartnerTeam[i] >= 0);
    }
    if (PendPartnerTeam[i] >= 0 && P.Pawn != None && P.Pawn != PendPartnerPawn[i])
    {
        PendPartnerPawn[i] = P.Pawn;
        RemindPending(P, PendPartnerTeam[i], C, true);
    }
}

function RemindPending(Controller C, int NewTeam, Controller Partner, bool bSwap)
{
    if (!bNotifyMoved || PlayerController(C) == None)
        return;
    if (bSwap)
        TellMsg(PlayerController(C), MSG_YOUSWAP + NewTeam, C.PlayerReplicationInfo,
            Partner.PlayerReplicationInfo, "", "", true);
    else
        TellMsg(PlayerController(C), MSG_YOUQUEUED + NewTeam, C.PlayerReplicationInfo, None, "", "", true);
}

// ---- "you are now on X" again when a moved player spawns -------------------
function AddSpawnNotice(Controller C, int Team)
{
    local int n;

    n = NoticeCtrl.Length;
    NoticeCtrl[n]   = C;
    NoticeTeam[n]   = Team;
    NoticeExpire[n] = Level.TimeSeconds + NoticeTimeout;
}

function ProcessNotices()
{
    local int i;
    local Controller C;

    i = 0;
    while (i < NoticeCtrl.Length)
    {
        C = NoticeCtrl[i];
        if (C != None && C.PlayerReplicationInfo != None && Level.TimeSeconds <= NoticeExpire[i])
        {
            if (C.Pawn == None)
            {
                i++;
                continue;
            }
            TellMsg(PlayerController(C), MSG_YOUMOVED + NoticeTeam[i], C.PlayerReplicationInfo, None, "", "", true);
        }
        NoticeCtrl.Remove(i, 1);
        NoticeTeam.Remove(i, 1);
        NoticeExpire.Remove(i, 1);
    }
}

function ProcessDeferred()
{
    local int i, idx, jdx, D0, D;
    local float GapBefore, GapAfter;
    local bool bGo, bPair, bOk;
    local Controller C, P;
    local string MovedText;

    i = 0;
    while (i < PendCtrl.Length)
    {
        C = PendCtrl[i];
        P = PendPartner[i];
        bPair = (PendPartnerTeam[i] >= 0);

        if (C == None || C.PlayerReplicationInfo == None || C.PlayerReplicationInfo.Team == None
            || (bPair && (P == None || P.PlayerReplicationInfo == None || P.PlayerReplicationInfo.Team == None)))
        {
            CancelPending(i, "player left");    // tells whoever is still here
            continue;
        }
        if (Level.Game.bGameEnded)
        {
            RemovePending(i);    // nobody cares any more
            continue;
        }
        if (!BalancingActive())
        {
            CancelPending(i, "balancing switched off");
            continue;
        }
        if (NearEnd())
        {
            CancelPending(i, "too late in the match");
            continue;
        }
        if (Level.TimeSeconds > PendExpire[i])
        {
            CancelPending(i, "timed out");
            continue;
        }
        if (C.Pawn != None || (bPair && P.Pawn != None))    // someone still alive: keep waiting
        {
            RemindIfRespawned(i);
            i++;
            continue;
        }

        // Everyone involved is dead and waiting to respawn: nothing is lost by switching now.
        // Re-check that it is still useful with the current roster.
        BuildRoster();
        idx = RosterIndexOf(C);
        jdx = -1;
        if (bPair)
            jdx = RosterIndexOf(P);
        bGo = false;
        if (idx >= 0 && GTeam[idx] != PendTeam[i] && (!bPair || (jdx >= 0 && GTeam[jdx] != PendPartnerTeam[i])))
        {
            GapBefore = Gap();
            D0 = IAbs(N0 - N1);
            GTeam[idx] = 1 - GTeam[idx];
            if (bPair) GTeam[jdx] = 1 - GTeam[jdx];
            GapAfter = Gap();
            D = IAbs(N0 - N1);
            GTeam[idx] = 1 - GTeam[idx];
            if (bPair) GTeam[jdx] = 1 - GTeam[jdx];
            if (D <= 1 || D < D0)
            {
                if (D0 > 1 || GapAfter < GapBefore - 0.05)
                    bGo = true;
            }
        }

        MovedText = "";
        bOk = false;
        if (bGo)
        {
            bOk = ExecuteMove(C, PendTeam[i], MovedText);
            if (bOk && bPair)
                ExecuteMove(P, PendPartnerTeam[i], MovedText);
        }
        if (bOk)
        {
            BuildRoster();
            LastActionTime = Level.TimeSeconds;
            if (bPair)
                AnnounceMsg(MSG_SWAPPED, C.PlayerReplicationInfo, P.PlayerReplicationInfo, "", TeamSummary());
            else
                AnnounceMsg(MSG_MOVED + PendTeam[i], C.PlayerReplicationInfo, None, "", TeamSummary());
            RemovePending(i);
        }
        else
            CancelPending(i, "no longer needed");
    }
}

// True when nobody in the action has a live pawn, so it can happen right away.
function bool CanApplyNow(int A, int B)
{
    if (GCtrl[A].Pawn != None)
        return false;
    if (B >= 0 && GCtrl[B].Pawn != None)
        return false;
    return true;
}

function bool ApplyAction(int A, int B, out string MovedText)
{
    if (!MovePlayer(A, 1 - GTeam[A], MovedText))
        return false;
    if (B >= 0)
        MovePlayer(B, 1 - GTeam[B], MovedText);
    return true;
}

//=============================================================================
// One balancing pass
//=============================================================================
function RunBalance(bool bMatchStart, bool bAnnounceAlways)
{
    local int Moves, MaxMoves, A, B, nNow, nQueued, FirstTeam;
    local float GapNow, Limit;
    local string MovedText, Note;
    local bool bFull;
    local Controller FirstA, FirstB;

    if (BuildRoster() < MinPlayersForBalance)
        return;

    // Full pass (immediate moves, swaps allowed) only at match start / warmup.
    bFull = (bMatchStart || Level.Game.bWaitingToStartMatch);

    if (!bFull && NearEnd())
    {
        if (bAnnounceAlways)
            Announce("Teams are not changed this late in the match.");
        else
            Log("[TeamBalance] end-of-match guard - no moves");
        return;
    }
    if (!bFull && PendCtrl.Length > 0)
        return;    // a move is already waiting for its player to die

    GapNow = Gap();
    if (bMatchStart) Limit = TargetGap;
    else             Limit = Tolerance;

    // Big gap mid-match: relax the joiner-only rule and allow deferred swaps.
    bEscalated = (!bFull && EscalationFactor > 0.0 && GapNow > Tolerance * EscalationFactor);

    if (IAbs(N0 - N1) <= 1 && GapNow <= Limit)
    {
        if (bAnnounceAlways || bMatchStart)
            AnnounceMsg(MSG_EVEN, None, None, "", TeamSummary());
        else
            Log("[TeamBalance] checked, within tolerance - " $ TeamSummary());
        return;
    }

    if (bFull) MaxMoves = MaxMovesPerPass;
    else       MaxMoves = 1;

    for (Moves = 0; Moves < MaxMoves; Moves++)
    {
        GapNow = Gap();
        if (IAbs(N0 - N1) <= 1 && GapNow <= TargetGap)
            break;
        if (!FindBestAction(GapNow, bFull, A, B))
            break;
        if (bFull && CanApplyNow(A, B))
        {
            if (nNow == 0)
            {
                FirstA = GCtrl[A];
                FirstTeam = 1 - GTeam[A];
                if (B >= 0)
                    FirstB = GCtrl[B];
            }
            if (!ApplyAction(A, B, MovedText))
                break;
            nNow++;
        }
        else if (bFull)
        {
            // Alive (players have just spawned at match start): switch them at
            // their next death. Plan the following steps as if it had happened.
            if (B >= 0)
                QueueSwap(A, B);
            else
                QueueMove(A, 1 - GTeam[A]);
            GTeam[A] = 1 - GTeam[A];
            if (B >= 0)
                GTeam[B] = 1 - GTeam[B];
            nQueued++;
        }
        else
        {
            if (B >= 0)
                QueueSwap(A, B);
            else
                QueueMove(A, 1 - GTeam[A]);
            LastActionTime = Level.TimeSeconds;    // QueueMove/QueueSwap announced it
            return;
        }
    }

    if (nNow > 0 || nQueued > 0)
    {
        LastActionTime = Level.TimeSeconds;
        BuildRoster();    // undo the planned (queued) changes in GTeam
        // Queued ones were announced by name as they were queued.
        if (nNow == 1 && FirstB != None)
            AnnounceMsg(MSG_SWAPPED, FirstA.PlayerReplicationInfo, FirstB.PlayerReplicationInfo, "", TeamSummary());
        else if (nNow == 1)
            AnnounceMsg(MSG_MOVED + FirstTeam, FirstA.PlayerReplicationInfo, None, "", TeamSummary());
        else if (nNow > 1)
            AnnounceMsg(MSG_BALANCED, None, None, "", TeamSummary() $ MovedText);
    }
    else if (bAnnounceAlways)
        Announce("No suitable move available", TeamSummary());
    else
    {
        if (bEscalated) Note = " (escalated)";
        Log("[TeamBalance] gap " $ Fmt1(GapNow) $ " over tolerance " $ Fmt1(Tolerance)
            $ " but no move found: " $ N0 $ "v" $ N1 $ ", movable=" $ CountMovable()
            $ ", escalates at gap " $ Fmt1(Tolerance * EscalationFactor) $ Note);
    }
}

function string TeamSummary()
{
    local float A0, A1;

    Recompute();
    if (N0 > 0) A0 = Sum0 / N0;
    if (N1 > 0) A1 = Sum1 / N1;

    if (N0 + N1 >= MinPlayersToShowRatings)
        return "Red (" $ N0 $ ") avg " $ Fmt1(A0) $ " | Blue (" $ N1 $ ") avg " $ Fmt1(A1)
             $ " | gap " $ Fmt1(Abs(A0 - A1)) $ " | tolerance " $ Fmt1(Tolerance);

    return "Red (" $ N0 $ ") v Blue (" $ N1 $ ") | gap " $ Fmt1(Abs(A0 - A1))
         $ " | tolerance " $ Fmt1(Tolerance);
}

//=============================================================================
// Chat commands:  !balance  (run a check now)   !teams  (show current gap)
// Also available as console commands:  mutate balance / mutate teams
//=============================================================================
function HandleChat(PlayerController PC, string Msg)
{
    local string M;

    if (PC == None)
        return;
    M = Locs(Msg);

    if (M == "!balance status")
    {
        ShowStatus(PC);
        return;
    }

    // Admin switch: works even if the player chat commands are disabled.
    if (M == "!balance off" || M == "!balance on")
    {
        SetAdminSwitch(PC, M == "!balance on");
        return;
    }

    if (!bChatCommands)
        return;
    if (M != "!balance" && M != "!teams")
        return;

    if (Level.TimeSeconds - LastCmdTime < ChatCommandCooldown)
    {
        Tell(PC, "Please wait "
            $ (ChatCommandCooldown - int(Level.TimeSeconds - LastCmdTime)) $ "s before using that again.");
        return;
    }
    LastCmdTime = Level.TimeSeconds;
    PendingPC = PC;
    if (M == "!teams") PendingCmd = 1;
    else               PendingCmd = 0;
}

// Turns automatic balancing on/off for admins. Saved, so it survives map changes.
function SetAdminSwitch(PlayerController PC, bool bOn)
{
    if (PC.PlayerReplicationInfo == None || !PC.PlayerReplicationInfo.bAdmin)
    {
        Tell(PC, "Only admins can turn team balancing on or off.");
        return;
    }
    bEnabled = bOn;
    SaveConfig();
    if (bOn)
    {
        Tell(PC, "Team balancing is now ON.");
        Log("[TeamBalance] switched ON by admin " $ PC.PlayerReplicationInfo.PlayerName);
    }
    else
    {
        Tell(PC, "Team balancing is now OFF. Type !balance on to turn it back on.");
        Log("[TeamBalance] switched OFF by admin " $ PC.PlayerReplicationInfo.PlayerName);
    }
}

function Mutate(string MutateString, PlayerController Sender)
{
    if (Locs(MutateString) == "balance" || Locs(MutateString) == "teams"
        || Locs(MutateString) == "balance off" || Locs(MutateString) == "balance on"
        || Locs(MutateString) == "balance status")
        HandleChat(Sender, "!" $ MutateString);
    Super.Mutate(MutateString, Sender);
}

function ProcessPending()
{
    if (PendingPC == None)
        return;

    if (!BalancingActive())
        Tell(PendingPC, "Team balancing is off (" $ InactiveReason() $ ").");
    else if (BuildRoster() < MinPlayersForBalance)
        Tell(PendingPC, "Needs at least " $ MinPlayersForBalance $ " human players.");
    else if (PendingCmd == 1)
        Tell(PendingPC, TeamSummary());
    else
        RunBalance(false, true);

    PendingPC = None;
}

//=============================================================================
// Sightings (raw IP is written; the admin script hashes it and discards it)
//=============================================================================
function RecordSightings()
{
    local int i, k;
    local bool bSeen;
    local string Hash, Addr, IP;
    local PlayerController PC;
    local TeamBalanceSightings S;

    for (i = 0; i < GCtrl.Length; i++)
    {
        PC = PlayerController(GCtrl[i]);
        if (PC == None) continue;
        Hash = Locs(PC.GetPlayerIDHash());
        if (Hash == "") continue;

        bSeen = false;
        for (k = 0; k < SeenGuid.Length; k++)
            if (SeenGuid[k] == Hash) { bSeen = true; break; }
        if (bSeen) continue;
        SeenGuid[SeenGuid.Length] = Hash;

        Addr = PC.GetPlayerNetworkAddress();     // "ip:port" - drop the port
        k = InStr(Addr, ":");
        if (k >= 0) IP = Left(Addr, k);
        else        IP = Addr;

        S = new(None, Hash) class'TeamBalanceSightings';
        S.Record(PC.PlayerReplicationInfo.PlayerName, IP, Timestamp());
    }
}

//=============================================================================
// Helpers
//=============================================================================
// Every message goes two ways: a short line on screen, and a chat line that
// adds Details (team averages, reasons) and stays in the chat history.
// On screen: with bTopMessages, a TeamBalanceMessage at the top (plain-text
// replies such as !teams go to chat only); otherwise center-screen text when
// bCenterMessages.
// Messages are sent to each player directly: Level.Game.Broadcast shares a
// 200-characters-per-second budget with player chat and silently drops the rest.
function SendNotice(PlayerController PC, int Switch, PlayerReplicationInfo P1, PlayerReplicationInfo P2,
                    string Msg, string Details, bool bQuiet)
{
    if (PC == None)
        return;
    if (bTopMessages)
    {
        if (Switch >= 0)
            PC.ReceiveLocalizedMessage(class'TeamBalanceMsg_V1.TeamBalanceMessage', Switch, P1, P2);
    }
    else if (bCenterMessages)
        PC.ClientMessage(Msg, 'CriticalEvent');
    if (bQuiet)
        return;
    if (Details != "")
        Msg = Msg $ " | " $ Details;
    PC.ClientMessage("[TeamBalance] " $ Msg, 'Event');
}

// Public message with a TeamBalanceMessage switch (-1 = text only).
// Msg may be left empty; it is then the switch's text.
function AnnounceMsg(int Switch, PlayerReplicationInfo P1, PlayerReplicationInfo P2, string Msg, string Details)
{
    local Controller C;

    if (Switch >= 0 && Msg == "")
        Msg = class'TeamBalanceMsg_V1.TeamBalanceMessage'.static.GetString(Switch, P1, P2);
    if (bAnnounce)
        for (C = Level.ControllerList; C != None; C = C.NextController)
            if (PlayerController(C) != None)
                SendNotice(PlayerController(C), Switch, P1, P2, Msg, Details, false);
    if (Details != "")
        Log("[TeamBalance] " $ Msg $ " | " $ Details);
    else
        Log("[TeamBalance] " $ Msg);
}

function Announce(string Msg, optional string Details)
{
    AnnounceMsg(-1, None, None, Msg, Details);
}

function AnnounceOnOff(bool bOn)
{
    if (bOn)
        AnnounceMsg(MSG_ON, None, None, "", "");
    else
        AnnounceMsg(MSG_OFF, None, None, "", InactiveReason());
}

// Private message to one player. Held until the end of the tick (FlushTells)
// so it lands after any public message sent in the same tick.
function TellMsg(PlayerController PC, int Switch, PlayerReplicationInfo P1, PlayerReplicationInfo P2,
                 string Msg, string Details, optional bool bQuiet)
{
    local int n;

    if (PC == None)
        return;
    if (Switch >= 0 && Msg == "")
        Msg = class'TeamBalanceMsg_V1.TeamBalanceMessage'.static.GetString(Switch, P1, P2);
    n = OutPC.Length;
    OutPC[n]     = PC;
    OutSwitch[n] = Switch;
    OutPRI1[n]   = P1;
    OutPRI2[n]   = P2;
    OutMsg[n]    = Msg;
    OutDetail[n] = Details;
    if (bQuiet) OutQuiet[n] = 1;
    else        OutQuiet[n] = 0;
}

function Tell(PlayerController PC, string Msg, optional string Details)
{
    TellMsg(PC, -1, None, None, Msg, Details);
}

function FlushTells()
{
    local int i;

    for (i = 0; i < OutPC.Length; i++)
        SendNotice(OutPC[i], OutSwitch[i], OutPRI1[i], OutPRI2[i], OutMsg[i], OutDetail[i], OutQuiet[i] != 0);
    OutPC.Length     = 0;
    OutSwitch.Length = 0;
    OutPRI1.Length   = 0;
    OutPRI2.Length   = 0;
    OutMsg.Length    = 0;
    OutDetail.Length = 0;
    OutQuiet.Length  = 0;
}

function string MetricName()
{
    if (BalanceMetric == MU_ONLY)     return "MU_ONLY";
    if (BalanceMetric == RATING_ONLY) return "RATING_ONLY";
    if (BalanceMetric == ELO_ONLY)    return "ELO_ONLY";
    if (BalanceMetric == HYBRID)      return "HYBRID";
    return "DYNAMIC_HYBRID";
}

static function string TeamName(int T)
{
    if (T == 0) return "Red";
    return "Blue";
}

static function string Fmt1(float V)
{
    local int I;
    local string Sign;

    I = Round(V * 10.0);
    if (I < 0) { Sign = "-"; I = -I; }
    return Sign $ (I / 10) $ "." $ (I % 10);
}

static function string PadTwo(int V)
{
    if (V < 10) return "0" $ V;
    return string(V);
}

function string Timestamp()
{
    return Level.Year $ "-" $ PadTwo(Level.Month) $ "-" $ PadTwo(Level.Day) $ " "
         $ PadTwo(Level.Hour) $ ":" $ PadTwo(Level.Minute);
}

//=============================================================================
// WebAdmin
//=============================================================================
static function FillPlayInfo(PlayInfo PlayInfo)
{
    Super.FillPlayInfo(PlayInfo);

    PlayInfo.AddSetting("Team Balance", "bEnabled",                 "Enabled",                      0, 10, "Check");
    PlayInfo.AddSetting("Team Balance", "bTournamentMode",          "Tournament mode (balancing off)", 0, 20, "Check");
    PlayInfo.AddSetting("Team Balance", "bAutoTournamentOnPassword","Auto tournament mode when password set", 0, 30, "Check");
    PlayInfo.AddSetting("Team Balance", "BalanceMetric",            "Balance metric",               0, 40, "Select",
        "MU_ONLY;Mu only;RATING_ONLY;Rating (mu-3sigma);ELO_ONLY;Elo only;HYBRID;Hybrid (Rating+Elo);DYNAMIC_HYBRID;Dynamic hybrid");
    PlayInfo.AddSetting("Team Balance", "RatingWeight",             "Rating weight",                0, 50, "Text", "8;0.0:100.0");
    PlayInfo.AddSetting("Team Balance", "EloWeight",                "Elo weight",                   0, 60, "Text", "8;0.0:100.0");
    PlayInfo.AddSetting("Team Balance", "Tolerance",                "Tolerance (avg gap before acting)", 0, 70, "Text", "8;0.0:1000.0");
    PlayInfo.AddSetting("Team Balance", "TargetGap",                "Target gap after balancing",   0, 80, "Text", "8;0.0:1000.0");
    PlayInfo.AddSetting("Team Balance", "MinPlayersForBalance",     "Min human players to balance", 0, 90, "Text", "3;1:32");
    PlayInfo.AddSetting("Team Balance", "MinPlayersToShowRatings",  "Min players to show team ratings", 0, 100, "Text", "3;1:32");
    PlayInfo.AddSetting("Team Balance", "bBalanceOnMatchStart",     "Balance at match start",       0, 110, "Check");
    PlayInfo.AddSetting("Team Balance", "MoveCooldown",             "Seconds between auto passes",  0, 120, "Text", "4;0:600");
    PlayInfo.AddSetting("Team Balance", "JoinGraceSeconds",         "Mid-match: only players newer than this (s) can be moved", 0, 125, "Text", "4;0:3600");
    PlayInfo.AddSetting("Team Balance", "MaxMovesPerPlayer",        "Max moves per player per map", 0, 126, "Text", "3;0:10");
    PlayInfo.AddSetting("Team Balance", "EndGuardSeconds",          "No moves in the last N seconds", 0, 127, "Text", "4;0:3600");
    PlayInfo.AddSetting("Team Balance", "GoalGuardCaps",            "No moves when a team is within N caps of goal", 0, 128, "Text", "3;0:10");
    PlayInfo.AddSetting("Team Balance", "DeferredMoveTimeout",      "Cancel a queued move after N seconds", 0, 129, "Text", "4;0:3600");
    PlayInfo.AddSetting("Team Balance", "EscalationFactor",         "Big-gap escalation (x tolerance, 0 = off)", 0, 130, "Text", "5;0.0:20.0");
    PlayInfo.AddSetting("Team Balance", "DeferredSwapTimeout",      "Cancel a queued swap after N seconds", 0, 130, "Text", "4;0:3600");
    PlayInfo.AddSetting("Team Balance", "bNotifyMoved",             "Tell moved players why", 0, 131, "Check");
    PlayInfo.AddSetting("Team Balance", "bTopMessages",             "Show messages at the top of the screen", 0, 132, "Check");
    PlayInfo.AddSetting("Team Balance", "bCenterMessages",          "Show messages center-screen (if not at the top)", 0, 133, "Check");
    PlayInfo.AddSetting("Team Balance", "bChatCommands",            "Enable !balance / !teams",     0, 130, "Check");
    PlayInfo.AddSetting("Team Balance", "ChatCommandCooldown",      "Chat command cooldown (s)",    0, 140, "Text", "4;0:600");
    PlayInfo.AddSetting("Team Balance", "bAnnounce",                "Announce in chat",             0, 150, "Check");
    PlayInfo.AddSetting("Team Balance", "bLogSightings",            "Record GUID sightings",        0, 160, "Check");
    PlayInfo.AddSetting("Team Balance", "bDisableStockBalancing",   "Turn off stock team balancing",0, 170, "Check");
    PlayInfo.AddSetting("Team Balance", "DefaultUnknownRating",     "Default mu for unknown GUIDs", 0, 180, "Text", "8;0.0:100.0");
    PlayInfo.AddSetting("Team Balance", "DefaultUnknownSigma",      "Default sigma for unknown GUIDs", 0, 190, "Text", "8;0.0:100.0");
    PlayInfo.AddSetting("Team Balance", "DefaultUnknownElo",        "Default Elo for unknown GUIDs",0, 200, "Text", "8;0.0:10000.0");
}

static event string GetDescriptionText(string PropName)
{
    switch (PropName)
    {
        case "bEnabled":                  return "Master switch for automatic balancing.";
        case "bTournamentMode":           return "Manual override: never move players. Also turns on automatically when a server password is set (see next option).";
        case "bAutoTournamentOnPassword": return "Treat a password-locked server as a tournament and leave teams alone.";
        case "BalanceMetric":             return "How a player's strength is scored. DYNAMIC_HYBRID = Rating plus Elo, with Elo counting less for low-confidence (high sigma) players.";
        case "RatingWeight":              return "Weight of the OpenSkill Rating (mu-3sigma) in HYBRID metrics.";
        case "EloWeight":                 return "Weight of Elo in HYBRID metrics.";
        case "Tolerance":                 return "Teams are only rebalanced if their average score per player differs by more than this. Scale depends on the metric.";
        case "TargetGap":                 return "When rebalancing, keep going until the average gap is at or below this.";
        case "MinPlayersForBalance":      return "Balancing runs only with at least this many human players (bots and spectators not counted).";
        case "MinPlayersToShowRatings":   return "Below this many players, chat announcements show only the gap, not team averages.";
        case "bBalanceOnMatchStart":      return "Run a full balance pass when the match goes live.";
        case "MoveCooldown":              return "Minimum seconds between automatic balancing passes.";
        case "JoinGraceSeconds":          return "During a match, only players who joined within this many seconds can be moved. Everyone is movable at match start and during warmup.";
        case "MaxMovesPerPlayer":         return "A player is moved at most this many times per map.";
        case "EndGuardSeconds":           return "No automatic moves in the last N seconds of a timed match (and none in overtime).";
        case "GoalGuardCaps":             return "No automatic moves when either team is within N captures of the goal score.";
        case "DeferredMoveTimeout":       return "Mid-match moves wait until the player dies. If it hasn't happened after this many seconds, the move is cancelled.";
        case "EscalationFactor":          return "When the team gap exceeds Tolerance times this, established players can be moved and even teams can be fixed by a swap. 0 turns escalation off.";
        case "DeferredSwapTimeout":       return "A queued swap happens only when both players are dead at the same moment. Cancelled after this many seconds.";
        case "bNotifyMoved":              return "Send a private message to a player who is moved or about to be.";
        case "bTopMessages":              return "Show balancing messages at the top of the screen, under the CTF notices. Clients download a small package (TeamBalanceMsg_V1) for this. Applies from the next map. Details always go to chat as well.";
        case "bCenterMessages":           return "Only used when top-of-screen messages are off: show balancing messages as center-screen text. Turn both off to use the chat feed only.";
        case "bChatCommands":             return "Let players type !balance (check now) and !teams (show gap). Admin commands (!balance on/off/status) work either way.";
        case "ChatCommandCooldown":       return "Seconds between uses of the chat commands (server-wide).";
        case "bAnnounce":                 return "Broadcast balancing results and mode changes to chat.";
        case "bLogSightings":             return "Record each GUID's names and IPs for the new-GUID/alt report.";
        case "bDisableStockBalancing":    return "Switch off the game's own team balancing while this mutator runs.";
        case "DefaultUnknownRating":      return "Mu assigned to GUIDs missing from the ratings file (never-rated players use 25).";
        case "DefaultUnknownSigma":       return "Sigma assigned to unknown GUIDs.";
        case "DefaultUnknownElo":         return "Elo assigned to unknown GUIDs.";
    }
    return Super.GetDescriptionText(PropName);
}

defaultproperties
{
    FriendlyName="Team Balance (Rating)"
    Description="Balances CTF teams using OpenSkill/Elo ratings from the community stats bot. Server-side only."
    GroupName="TeamBalance"

    bEnabled=True
    BalanceMetric=DYNAMIC_HYBRID
    EloWeight=0.10
    RatingWeight=1.00
    ChatCommandCooldown=60
    bBalanceOnMatchStart=True
    MinPlayersForBalance=3
    DefaultUnknownRating=25.0
    DefaultUnknownSigma=8.333
    DefaultUnknownElo=0.0
    Tolerance=4.0
    TargetGap=2.0
    MoveCooldown=60
    bTournamentMode=False
    bAutoTournamentOnPassword=True
    bDisableStockBalancing=True
    bChatCommands=True
    bAnnounce=True
    bLogSightings=True
    MinPlayersToShowRatings=6
    JoinGraceSeconds=90
    MaxMovesPerPlayer=1
    EndGuardSeconds=180
    GoalGuardCaps=1
    DeferredMoveTimeout=60
    bNotifyMoved=True
    bCenterMessages=True
    bTopMessages=True
    EscalationFactor=1.5
    DeferredSwapTimeout=90
}