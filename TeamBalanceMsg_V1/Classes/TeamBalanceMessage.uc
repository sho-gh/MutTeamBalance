//=============================================================================
// TeamBalanceMessage
// Client-side message for MutTeamBalance. Draws at the top of the screen in
// the same stack as the CTF notices ("You have the flag, return to base!"),
// so a new message appears under the ones already showing.
//
// This is the only class clients download. The mutator adds this package to
// the package map itself (AddToPackageMap), so no ServerPackages line is
// needed. Every rebuild gives the package a new GUID and clients holding an
// old copy cannot join, so a changed build MUST be released under a new
// package name (TeamBalanceMsg_V2, ...) and the mutator's reference updated.
//
// Text is fixed per switch; %1 / %2 are the related players' names.
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
var color RedColor, BlueColor, NeutralColor;

static function string GetString(
    optional int Switch,
    optional PlayerReplicationInfo RelatedPRI_1,
    optional PlayerReplicationInfo RelatedPRI_2,
    optional Object OptionalObject
    )
{
    local string S;

    if (Switch < 0 || Switch >= ArrayCount(default.Text))
        return "";
    S = default.Text[Switch];
    if (RelatedPRI_1 != None)
        ReplaceText(S, "%1", RelatedPRI_1.PlayerName);
    if (RelatedPRI_2 != None)
        ReplaceText(S, "%2", RelatedPRI_2.PlayerName);
    return S;
}

// Team-specific messages (even switch = Red, odd = Blue) take the team's colour.
static function color GetColor(
    optional int Switch,
    optional PlayerReplicationInfo RelatedPRI_1,
    optional PlayerReplicationInfo RelatedPRI_2
    )
{
    if ((Switch >= 0 && Switch <= 5) || Switch >= 20)
    {
        if (Switch % 2 == 0)
            return default.RedColor;
        return default.BlueColor;
    }
    return default.NeutralColor;
}

// "You" messages a size bigger than news about other players.
static function int GetFontSize(int Switch, PlayerReplicationInfo RelatedPRI1, PlayerReplicationInfo RelatedPRI2, PlayerReplicationInfo LocalPlayer)
{
    if (Switch >= 20)
        return 1;
    return 2;
}

defaultproperties
{
    Text(0)="%1 will switch to Red at their next death"
    Text(1)="%1 will switch to Blue at their next death"
    Text(2)="%1 moved to Red to balance the teams"
    Text(3)="%1 moved to Blue to balance the teams"
    Text(4)="%1 stays on Red - team switch cancelled"
    Text(5)="%1 stays on Blue - team switch cancelled"
    Text(6)="%1 and %2 will swap teams when both are dead"
    Text(7)="%1 and %2 swapped teams to balance them"
    Text(8)="Teams balanced - details in chat"
    Text(9)="Teams are even"
    Text(10)="Team balancing: ON"
    Text(11)="Team balancing: OFF"
    Text(12)="Team changes will happen at the players' next deaths"
    Text(20)="You will switch to RED at your next death"
    Text(21)="You will switch to BLUE at your next death"
    Text(22)="You are now on RED"
    Text(23)="You are now on BLUE"
    Text(24)="Team switch cancelled - you stay on RED"
    Text(25)="Team switch cancelled - you stay on BLUE"
    Text(26)="You will swap to RED with %2 when you are both dead"
    Text(27)="You will swap to BLUE with %2 when you are both dead"

    RedColor=(R=255,G=64,B=64,A=255)
    BlueColor=(R=80,G=140,B=255,A=255)
    NeutralColor=(R=255,G=255,B=0,A=255)

    bIsSpecial=True
    bIsConsoleMessage=False
    bFadeMessage=True
    Lifetime=6
    DrawColor=(R=255,G=255,B=0,A=255)
    StackMode=SM_Down
    PosY=0.100000
    FontSize=2
}
