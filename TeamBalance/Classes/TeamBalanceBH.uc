//=============================================================================
// TeamBalanceBH
// Watches say and team-say chat for !balance and !teams and hands it to the
// mutator. AcceptBroadcastText runs once per receiver, so we react only when
// the receiver is the sender (one call per message; team chat reaches the
// sender too, since they are on their own team).
//=============================================================================
class TeamBalanceBH extends BroadcastHandler;

var MutTeamBalance Mut;

function bool AcceptBroadcastText(PlayerController Receiver, PlayerReplicationInfo SenderPRI, out string Msg, optional name Type)
{
    if (Mut != None && (Type == 'Say' || Type == 'TeamSay') && SenderPRI != None
        && Receiver != None && Receiver.PlayerReplicationInfo == SenderPRI)
    {
        Mut.HandleChat(Receiver, Msg);
    }
    return Super.AcceptBroadcastText(Receiver, SenderPRI, Msg, Type);
}

defaultproperties
{
}
