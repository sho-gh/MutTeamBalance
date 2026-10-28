//=============================================================================
// TeamBalanceBH
// Watches say and team-say chat for !balance and !teams and hands it to the
// mutator. AcceptBroadcastText runs once per receiver, so we react only when
// the receiver is the sender (team chat reaches the sender too, since they
// are on their own team).
// The stock handler chain calls AcceptBroadcastText TWICE per receiver (once
// from the chain's own Accept, once from BroadcastText being passed down), so
// the same message in the same tick is handled only once.
//=============================================================================
class TeamBalanceBH extends BroadcastHandler;

var MutTeamBalance Mut;
var PlayerReplicationInfo LastSender;
var string LastMsg;
var float  LastTime;

function bool AcceptBroadcastText(PlayerController Receiver, PlayerReplicationInfo SenderPRI, out string Msg, optional name Type)
{
    if (Mut != None && (Type == 'Say' || Type == 'TeamSay') && SenderPRI != None
        && Receiver != None && Receiver.PlayerReplicationInfo == SenderPRI
        && !(SenderPRI == LastSender && Msg == LastMsg && Level.TimeSeconds == LastTime))
    {
        LastSender = SenderPRI;
        LastMsg    = Msg;
        LastTime   = Level.TimeSeconds;
        Mut.HandleChat(Receiver, Msg);
    }
    return Super.AcceptBroadcastText(Receiver, SenderPRI, Msg, Type);
}

defaultproperties
{
}
