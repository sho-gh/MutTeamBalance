//=============================================================================
// TeamBalanceMessage
// Client-side message for MutTeamBalance. Draws at the top of the screen in
// the same stack as the CTF notices ("You have the flag, return to base!"),
// so messages never overlap: each gets its own line, in arrival order.
//
// This is the only class clients download. The mutator adds this package to
// the package map itself (AddToPackageMap), so no ServerPackages line is
// needed. Every rebuild gives the package a new GUID and clients holding an
// old copy cannot join, so a changed build MUST be released under a new
// package name (TeamBalanceMsg_V2, ...) and the mutator's reference updated.
//
// Text is fixed per switch; %1 / %2 are the related players' names, %t the
// team name. On screen the text is white and only the team name is in team
// colour, so it can't be mistaken for the yellow/red CTF flag alerts.
// GetString (used by the server for the chat line and the log) stays plain.
//   0- 1  %1 will switch to Red/Blue           (queued move, everyone)
//   2- 3  %1 moved to Red/Blue                 (done, everyone)
//   4- 5  %1 stays on Red/Blue                 (cancelled, everyone)
//   6     %1 and %2 will swap                  (queued swap, everyone)
//   7     %1 and %2 swapped                    (done, everyone)
//   8-12  general announcements                (everyone)
//  20-27  "you" messages                       (the player concerned)
//=============================================================================
class TeamBalanceMessage extends LocalMessage;

var localized string Text[28];
var localized string TeamNames[2], TeamNamesCaps[2];
var color TeamColors[2], TextColor;

// True for switches whose text names a team (even = Red, odd = Blue).
static function bool HasTeam(int Switch)
{
    return (Switch >= 0 && Switch <= 5) || (Switch >= 20 && Switch <= 27);
}

static function string TeamWord(int Switch)
{
    if (Switch >= 20)
        return default.TeamNamesCaps[Switch & 1];
    return default.TeamNames[Switch & 1];
}

// Plain text: chat line and server log.
static function string GetString(
    optional int Switch,
    optional PlayerReplicationInfo RelatedPRI_1,
    optional PlayerReplicationInfo RelatedPRI_2,
    optional Object OptionalObject
    )
{
    return BuildString(Switch, RelatedPRI_1, RelatedPRI_2, false);
}

static function string BuildString(int Switch, PlayerReplicationInfo P1, PlayerReplicationInfo P2, bool bColored)
{
    local string S, White;

    if (Switch < 0 || Switch >= ArrayCount(default.Text))
        return "";
    S = default.Text[Switch];
    if (bColored)
        White = class'GameInfo'.static.MakeColorCode(default.TextColor);
    // White after each name: a name may carry its own colour codes.
    if (P1 != None)
        ReplaceText(S, "%1", P1.PlayerName $ White);
    if (P2 != None)
        ReplaceText(S, "%2", P2.PlayerName $ White);
    if (HasTeam(Switch))
    {
        if (bColored)
            ReplaceText(S, "%t", class'GameInfo'.static.MakeColorCode(default.TeamColors[Switch & 1])
                $ TeamWord(Switch) $ White);
        else
            ReplaceText(S, "%t", TeamWord(Switch));
    }
    return S;
}

// On screen: hand the HUD the coloured text instead of GetString's plain one.
static function ClientReceive(
    PlayerController P,
    optional int Switch,
    optional PlayerReplicationInfo RelatedPRI_1,
    optional PlayerReplicationInfo RelatedPRI_2,
    optional Object OptionalObject
    )
{
    local string S;

    S = BuildString(Switch, RelatedPRI_1, RelatedPRI_2, true);
    if (P.myHUD != None)
        P.myHUD.LocalizedMessage(default.Class, Switch, RelatedPRI_1, RelatedPRI_2, OptionalObject, S);
    if (P.DemoViewer != None)
        P.DemoViewer.myHUD.LocalizedMessage(default.Class, Switch, RelatedPRI_1, RelatedPRI_2, OptionalObject, S);
}

static function color GetColor(
    optional int Switch,
    optional PlayerReplicationInfo RelatedPRI_1,
    optional PlayerReplicationInfo RelatedPRI_2
    )
{
    return default.TextColor;
}

// "You" messages a size bigger (Big, like "You have the flag"); others Small.
static function int GetFontSize(int Switch, PlayerReplicationInfo RelatedPRI1, PlayerReplicationInfo RelatedPRI2, PlayerReplicationInfo LocalPlayer)
{
    if (Switch >= 20)
        return 1;
    return 2;
}

defaultproperties
{
    Text(0)="%1 will switch to %t at their next death"
    Text(1)="%1 will switch to %t at their next death"
    Text(2)="%1 moved to %t to balance the teams"
    Text(3)="%1 moved to %t to balance the teams"
    Text(4)="%1 stays on %t - team switch cancelled"
    Text(5)="%1 stays on %t - team switch cancelled"
    Text(6)="%1 and %2 will swap teams when both are dead"
    Text(7)="%1 and %2 swapped teams to balance them"
    Text(8)="Teams balanced - details in chat"
    Text(9)="Teams are even"
    Text(10)="Team balancing: ON"
    Text(11)="Team balancing: OFF"
    Text(12)="Team changes will happen at the players' next deaths"
    Text(20)="You will switch to %t at your next death"
    Text(21)="You will switch to %t at your next death"
    Text(22)="You are now on %t"
    Text(23)="You are now on %t"
    Text(24)="Team switch cancelled - you stay on %t"
    Text(25)="Team switch cancelled - you stay on %t"
    Text(26)="You will swap to %t with %2 when you are both dead"
    Text(27)="You will swap to %t with %2 when you are both dead"
    TeamNames(0)="Red"
    TeamNames(1)="Blue"
    TeamNamesCaps(0)="RED"
    TeamNamesCaps(1)="BLUE"

    TeamColors(0)=(R=255,G=64,B=64,A=255)
    TeamColors(1)=(R=80,G=140,B=255,A=255)
    TextColor=(R=255,G=255,B=255,A=255)

    bIsSpecial=True
    bIsConsoleMessage=False
    bFadeMessage=True
    Lifetime=6
    DrawColor=(R=255,G=255,B=255,A=255)
    StackMode=SM_Down
    PosY=0.100000
    FontSize=2
}
