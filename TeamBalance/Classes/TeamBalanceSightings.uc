//=============================================================================
// TeamBalanceSightings
// One section per GUID in System\TeamBalanceSightings.ini:
//
//   [<guid> TeamBalanceSightings]
//   KnownNames=Brim|Brim2
//   KnownIPs=203.0.113.7|198.51.100.4
//   FirstSeen=2026-10-08 19:02
//   LastSeen=2026-10-08 21:40
//   TimesSeen=12
//
// TimesSeen counts maps the GUID appeared on. IPs are RAW: the admin script
// hashes them with a secret salt and discards the raw values.
//=============================================================================
class TeamBalanceSightings extends Object
    config(TeamBalanceSightings)
    PerObjectConfig;

var config string KnownNames;
var config string KnownIPs;
var config string FirstSeen;
var config string LastSeen;
var config int    TimesSeen;

function Record(string PlayerName, string IP, string Stamp)
{
    KnownNames = AddToken(KnownNames, SafeText(PlayerName));
    KnownIPs   = AddToken(KnownIPs, IP);
    if (FirstSeen == "")
        FirstSeen = Stamp;
    LastSeen = Stamp;
    TimesSeen++;
    SaveConfig();
}

static function string AddToken(string List, string Token)
{
    if (Token == "")
        return List;
    if (InStr("|" $ List $ "|", "|" $ Token $ "|") >= 0)
        return List;
    if (Len(List) > 300)
        return List;
    if (List == "")
        return Token;
    return List $ "|" $ Token;
}

// '|' is our list separator, so it can't appear inside a name.
static function string SafeText(string S)
{
    local int i;
    local string R, C;

    for (i = 0; i < Len(S); i++)
    {
        C = Mid(S, i, 1);
        if (C == "|")
            C = "_";
        R = R $ C;
    }
    return R;
}

defaultproperties
{
}
