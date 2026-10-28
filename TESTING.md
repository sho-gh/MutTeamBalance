# Test checklist

For the first live test of a new version. Versions 1.0.6 to 1.1.1 have not
been tested in a game yet. Balancing ignores bots, so at least 3 human
players are needed (separate PCs or accounts).

## Before starting

- [ ] `TeamBalance.u`, `TeamBalance.ucl` and `TeamBalanceMsg_V1.u` in the
      server's `System\`; `TeamBalanceMsg_V1.u.uz2` on the redirect, if used.
- [ ] `bPlayersBalanceTeams=True` under `[UnrealGame.TeamGame]` in the
      server's ini (older versions could have saved it as `False`).
- [ ] `TeamBalanceRatings.ini` uploaded, then the server restarted.
- [ ] Server log shows `[TeamBalance] v1.1.1 started` and `loaded N ratings`.

## In game

- [ ] Players can join; the client downloads `TeamBalanceMsg_V1`.
- [ ] `!balance status` (as admin) shows the version and the ratings summary.
- [ ] `!balance off` / `!balance on` work in normal and in team chat, also
      with `bChatCommands=False`.
- [ ] `!teams` and `!balance` work for normal players and respect the cooldown.
- [ ] Each `[TeamBalance]` reply appears once, without your own name in front.
- [ ] Match start: living players are queued ("will switch at their next
      death") and switch when they die. Note how many queued moves are
      cancelled as "no longer needed" when several are queued at once.
- [ ] Top-of-screen notices share the stack with the CTF notices ("You have
      the flag..."), one per line, no overlap; the details line appears in chat.
- [ ] Notices are white with the team name in red/blue. Watch the fade at the
      end: if the coloured word stays solid while the white text fades, note it
      (fallback: plain white text).
- [ ] With a custom HUD mod (e.g. UTComp), if the server or players use one,
      the notices still appear in the right place.
- [ ] On a 4:3 screen, a long notice with long player names doesn't run into
      the chat text at the top left.
- [ ] Count the notices per move (ours + the game's own "joined the Blue
      team" message): is it too many?
- [ ] A moved player cannot switch straight back to the bigger team.
- [ ] Players moved in warmup can still be moved at match start.
- [ ] Mid-match: a late joiner is queued and moved at their death; no moves
      in the last 3 minutes or near the goal score.
- [ ] Even teams with a big gap (over 6.0): a swap is queued and happens
      when both players are dead at the same time.

## Afterwards

- [ ] Stats log: every move has a `TeamChange` line, and **no** suicide
      (`K` line with killer -1, or `self_frag`) for a moved player.
- [ ] The stats bot credits moved players to their new team.
- [ ] WebAdmin: change a setting, check it applies from the next map.
- [ ] Bot PC: `UploadHistory.log` shows "Upload Complete", then "No rating
      changes" on later runs, and the file arrives on the server.
- [ ] Send the server log and stats log for review.
