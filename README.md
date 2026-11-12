# Forever Groups

Automatic groups for dungeons and group quests on WoW Forever, peer-to-peer over a hidden addon channel.

## Layout

- `core/` – pure Lua 5.1, no WoW API: protocol, queue, matchmaking, election, proposals, engine
- `wow/` – thin WoW layer: hidden channel, send queue, invites, `/fg` commands (`/dq` still works); `wow/ui/` window and proposal popup;
  the main window is `wow/ui/window.lua` plus its parts in `wow/ui/window/` (shared, card, setup, quests, tabs)
- `tests/helpers/wowmock.lua` has no `require`, like WoW: a module loaded before one it uses fails the tests
- `probe/DungeonQueueProbe/` – phase 0 API probe addon (`/dqp help`)
- `tests/` – busted specs; `tests/helpers/sim.lua` simulates engines on a shared channel,
  `tests/helpers/wowmock.lua` loads the full addon (per the .toc) into mocked WoW clients

## How the network behaves

All clients join the hidden channel `DungeonQueueNet` (the old name, kept so older versions still meet) (realm-wide). Queued players re-send their entry every 45 s.
The matchmaker is the queued player whose client has been online longest (ties by name), so the role stays with a
stable client. The three likeliest matchmakers also send a keep-alive (`v2|K`) every 10 s; one that is silent for 25 s
is skipped and the next takes over. Any message of a player counts as alive in both queues (dungeons and questing),
and a keep-alive is only sent when the client sent nothing else in the last 10 s, so a player in both queues sends
one stream of keep-alives, not two. A client that joins asks for the state (`v2|S`); queued players answer with their
entry and re-send the open proposals they made or answered, so the newcomer knows who is reserved. Proposals resolve
on every client, so they complete even if the matchmaker disappears.

Every message speaks only for the player WoW names as its sender: a queue entry whose first member is someone else
is ignored, answers count for the sender only, and a party's queue status is only taken from the party leader. A
player who sends more than 20 messages in a burst, or more than one per second for a while, is ignored for 5 minutes and
taken out of the queue (`core/ratelimit.lua`); a normal client never gets near that, since its own send queue allows
6 at once and 1 per second.

Who is online: every message counts as a sign of life, each client announces itself (its version) when it
connects and every 5 minutes, and when a newcomer connects the others answer with their announcement a random
moment later: at most one per client every 10 s (a planned one serves every newcomer until it goes out), and with
more than 10 online only about 10 of them, the rest showing up at their next announcement (`wow/presence.lua`).
The same answers tell an older client that it is behind. Hovering "Connected" lists them; `/dq online` prints them.

Clients announce their version on login (`DQV|0.8.0|v2`, outside the `v2|` protocol so a client that only speaks an
old protocol still understands it). When an older client announces itself, a few newer ones answer (each waits a random moment and stays quiet once two others did). A client
warns its player once at least two other players run a newer version (one player cannot trigger it with a made-up
version), says so in the window's connection line, and repeats the warning on every login until the player updates.
A change that breaks the protocol bumps `Protocol.VERSION`; old clients then ignore the new messages and are told
they can no longer be matched with players who updated.

## Development

Lua 5.1, luacheck and busted are installed locally in `.lua51/`
(`uvx hererocks .lua51 --lua 5.1 --luarocks latest`, then `luarocks install luacheck busted luacov`).

```sh
.lua51/bin/busted                 # run tests
.lua51/bin/luacheck .             # lint
.lua51/bin/busted --coverage && .lua51/bin/luacov   # coverage report in luacov.report.out
SOAK_SEED=7 SOAK_STEPS=2000 .lua51/bin/busted tests/soak_spec.lua   # a longer random session
python3 scripts/package.py        # dist/ForeverGroups-<version>.zip with only what the .toc loads
```

`tests/soak_spec.lua` runs ten simulated players doing random things in both queues (joining, leaving, answering
proposals, logging out) and checks after every step that nobody is stuck: no queue held without a proposal in the
other, no proposal open past its deadline, no popup without a proposal or proposal without a popup. The mock keeps
Group Finder results secret during chat-messaging lockdown (`World.SECRET`), as Midnight does.

In game, `/dq selftest` tells which client features Forever Groups can use, and `/dq bugreport` opens the version,
the self-test, the addon's last errors (kept by a chained error handler, `wow/diagnostics.lua`) and the log, ready
to copy.

## In game

`/dq` (or the AddOns menu at the minimap) opens the window: role, party roles (party leader), dungeons, Join/Leave.

`/dq join <tank|healer|dps> [auto | dungeon, ...]`, `/dq leave`, `/dq status`, `/dq dungeons`,
`/dq accept`, `/dq decline`, `/dq invite`, `/dq debug`, `/dq log [n]`,
`/dq style <relaxed | learning | serious | expert>`, `/dq progress`.
`/dq slots <t> <h> <d>` shrinks the group for testing with fewer players (only the matchmaker's setting counts).

### Playstyle

Under the roles the player picks one of the four playstyles of WoW's Group Finder: Relaxed (first, and the default),
Learning, Serious or Expert (the words come from `GetGeneralPlaystyleString`). Learning and Relaxed players are grouped
together, and so are Serious and Expert ones; the two camps never are (an entry without a playstyle, from the protocol's point of view, goes with everyone)
(`core/playstyles.lua`). The playstyle travels in the queue entry, the matchmaker keeps each group within one camp,
and a client turns down a proposal that mixes them. The proposal popup, the status and the party message name the
group's playstyles, the one most players picked first (on a tie the calmer one).

The Group Finder side uses WoW's own field (`generalPlaystyle` of a search result, Enum.LFGEntryGeneralPlaystyle):
groups are only asked and players only invited when their playstyle fits (a listing without a readable one is kept),
the "looking" counts only count those, and Forever Groups's own listing gets the group's playstyle (Relaxed when nobody
has one; WoW requires one). Adding the playstyle changed the protocol to `v2`, so clients up to 0.7.0 no longer
take part and are told to update.

### Spec

Forever has one specialization per class, with the three Classic talent trees side by side in one retail-style
talent tree (`C_ClassTalents` / `C_Traits`). A talent's column (its x position: below 4000, below 8000, above) tells
its tree, and the tree with the most points is the player's spec (`core/specs.lua`, `wow/spec.lua`; a tie means no
spec). The spec never takes part in matchmaking. When the spec changes (or the first time), its roles are ticked
(Feral ticks Tank and DPS); after that the player's own ticks stay, so a healer can still queue as DPS. Queueing with
roles that fit none of the spec gives a warning, nothing more. The spec travels in the queue entry ("SHAMAN2"), so
the proposal popup and the group card show it for players with Forever Groups, and the whispers the addon sends name
it ("Level 20 Enhancement Shaman (DPS) here, could you invite me…", "Inviting you now. I'm the Enhancement Shaman.").

### Quests tab

The window has two tabs at the top: Dungeons and Quests. The Quests tab lists the group and elite quests in the quest
log outside dungeons: quests WoW tags Group (`C_QuestLog.GetQuestTagInfo`, tagID `Enum.QuestTag.Group`) or suggests
a group size for (`suggestedGroup`); Dungeon, Raid and PvP quests and quests under a dungeon's header are left out.
Every listed quest is ticked until the player unticks it. "Find questing group" queues the player with the chosen
roles; a party leader queues the whole party (members keep their party roles) for the ticked quests the party is
not already big enough for, and a party that changes leaves the questing queue. Playstyles do not apply to quests.
A `/reload` keeps the place in the questing queue (`charDb.questQueue`).

The questing queue is a second engine (`wow/questqueue.lua`) with its own messages: the dungeon protocol under the
prefix `q1|` (`Protocol.QUESTS`), where a group has at most one tank and one healer and the rest DPS. A queue entry
lists quest keys (`176-3`: quest 176 for a group of 3, the size WoW suggests or 3) where a dungeon entry lists
dungeons. `core/questmatch.lua` anchors a group on the longest waiting player and one of its quests, takes players
who share more of its quests first, then healers, then by waiting time, and keeps the playstyle camps apart; the
group is complete at the quest's size.

Once a group forms, a small Quest progress window (`wow/ui/progresswindow.lua`) shows how far everyone is (its
`-` button folds it to its title bar; the card's "Quest progress »" link and `/dq progress` show or hide it; its
place and folding are saved): for a questing group its quest(s), for a dungeon group the player's quests for that dungeon. Members
with Forever Groups send their progress in hidden PARTY addon messages (`v1|QP|questID:done/total:complete,...`, or
`questID:t` once turned in; `wow/questgroup.lua`); members without it show "?". When the player has turned in a
questing group's quests, a popup asks whether to leave the group.

While queued, the questing queue also uses WoW's Group Finder (`wow/questfinder.lua`): it searches the "Quests &
Zones" category (one activity per zone, matched by name to the quest log's zone headers) for the zones of the queued
quests, on the click that queues and then on key presses like the dungeon side. Players listed alone in a quest's
zone are invited at once with a whisper that names the quest and offers to share it ("Inviting you for Hogger
(Elwynn Forest, group of 3). I can share the quest."); the entry then narrows to that quest with the invited roles
reserved, invitees who join become members, and the group is complete at the quest's size. A solo player with
nobody to invite asks the leader of a listed group in the zone that still has room. The group is listed in its
zone while it needs players, unless a dungeon group needs the (single) listing. Zone results are kept apart from the
dungeon results, so a zone search never empties the dungeon side.

A player can wait in both queues. While one of them has a group proposal for the player, the other steps out (the
others see a leave) and comes back at the same place if that proposal fails (`Engine:setHeld`); once a group forms,
the other queue is left.

### Status

A small bar (under the minimap by default; drag to move, click to open the window) shows what is going on whenever
something is: queue time and roles, a proposal and its countdown, waiting for the leader's invite, inviting your
group, Group Finder invites, or "Group complete!". The window shows the same status. Party members who have the
addon see what their leader's queue does ("Your party is queued by X", proposals, the formed group) through
`v2|G|...` messages on the PARTY addon channel.

### Find group

One button. The click queues you for Forever Groups players and searches WoW's Group Finder at the same time; both
sources fill the group, whichever is first. Queued Forever Groups players who could share a group are merged at once (a
partial group); a player with no partner in sight fills from the Group Finder right away while staying in the queue.
An incomplete group stays in the queue (same place) so later Forever Groups players can still join it. Group Finder
searches need player input: the Find group click, Accept, and, while roles are still open, the player's own key
presses (a keyboard frame that passes every key through refreshes the search at most every 10 s, never in combat;
`/dq autosearch` turns it off). A click on the status bar or minimap button also searches.

### WoW's Group Finder

One setting, "Use WoW's Group Finder", turns all of the below on or off (`wow/features.lua`). Off, Forever Groups
only works with other Forever Groups players: it does not search, ask, invite from or list in the Group Finder, and
the "looking" counts show Forever Groups players only. On, each part has its own setting under it (refresh on key
presses, ask groups, invite listed players, list the group, invite players who whisper, every language, dry run);
those are greyed out while the main setting is off.

When players have waited 2 minutes without a full group, the matchmaker may propose a partial group (at least 2
players); the roles left open are filled from WoW's own Group Finder: the leader's Accept click also runs a Group
Finder search (searching is protected and needs a click), then the best listed solo players (right role, level and
dungeon; single-role players first, longest listed first) get a whisper and an invite. Anyone who declines or does not
join within 60 s is replaced. "Fill from Group Finder" in the window (or `/dq fill`) does the same for your own party;
`/dq dryrun` only prints the picks.

### Both directions

Forever's Group Finder is the board-style one (Blizzard_GroupFinder_VanillaStyle): no applications, players and
groups are listed and people whisper or invite each other. So a solo player first asks listed groups that need one of
their roles to invite them, by whisper to the leader (at most 3, nearest to full first, 2 s apart, never the same
leader twice), and waits 60 s. An invite from an asked leader holds off building; joining that group leaves the
Forever Groups queue. With no fitting group, or no invite in time, the player builds a group instead (inviting a player
makes you a party leader, after which another group's invite cannot be accepted, hence this order). While a group is
being filled it is also listed in the Group Finder (`wow/lfglisting.lua`; listing is protected, so it waits in
`wow/input.lua` for the next key press or click). Searches include every language unless "Find players of every
language" is off; without a language filter the server only returns the player's own language.

Players who see the listing whisper the leader (there are no applications). While a group is being built,
`wow/whisperinvite.lua` invites a whisperer who names a role that is still open ("heal?", "dps lf group"), asks once
which role they play when they only ask to join ("inv pls"), and says which roles are needed when theirs is taken.
The status shows the phase: "Asking groups to invite you (2 asked) · own group in 0:18", then "Building your own
group: inviting …".

### During and after forming

- **Taskbar flash:** proposals and invites flash the WoW icon in the taskbar and play a sound (`wow/notify.lua`).
- **Dungeon quests:** the dungeon table shows how many quests from the quest log belong to each dungeon (the quest
  log's area headers; `wow/quests.lua`).
- **Entrances:** when the group is complete a waypoint is set to the dungeon entrance, with directions, and each
  group slot shows how far that player is. Sources, in order: WoW's own dungeon pins
  (`C_EncounterJournal.GetDungeonEntrancesForMap`; Forever's client has none), the entrances copied into
  `core/dungeons.lua` from ForeverDungeonJournal (no runtime dependency), and for a dungeon with neither, the spot a
  Forever Groups player stood on just before zoning in, shared on the channel (`v1|E|id|map|x|y`, asked for with
  `v1|E?|id`; `wow/entrances.lua`).
- **Level ranges:** only from WoW's Group Finder suggestion per activity (`C_LFGList.GetActivityInfoTable`), read at
  login. A dungeon without one (The Stockade) is only listed under "Other dungeons".
- **Quest sharing:** in a group being built, party members with Forever Groups exchange which quests they have for the
  dungeon over PARTY addon messages (`v1|QL|dungeon|questID,...`, asked for with `v1|QR|dungeon`); the window shows
  the counts per player, and "Share my quests" shares every shareable quest, 1.5 s apart (`wow/questshare.lua`).
- **Replacement:** `wow/run.lua` counts bosses killed (`ENCOUNTER_END`). A dungeon's boss count comes from WoW's
  Adventure Guide when it lists the dungeon, else from finished runs (the most ever killed in one run). When someone leaves the full group before every known boss is down, the leader gets a popup to
  queue the group for a replacement (Forever Groups and the Group Finder, the leaver excluded).

### Test tools

- `/dq fake <n> [roles]` adds local fake players (default: a mix of roles, also combinations). They are never sent
  to the channel, never become matchmaker, never expire, and are only grouped with you; they accept 1-3 s after a
  proposal. `/dq fake decline` / `/dq fake afk` makes the first fake in the next proposal decline / stay silent;
  `/dq fake clear` removes them.
- `/dq queue` lists the queue with tags (you, fake, in a proposal).
- `/dq debug` logs every sent/received message and, when it changes, why the matchmaker did or did not form a group.

## Releasing

Releases go to CurseForge, Wago and WoWInterface through the BigWigs packager
(`.github/workflows/release.yml`, `.pkgmeta`):

1. Set the new version in `ForeverGroups.toc` (`## Version: 1.2.3`) and commit.
2. Tag it with the same version and a `v` in front, annotated, and push the tag:
   `git tag -a v1.2.3 -m "v1.2.3" && git push origin v1.2.3`.
3. The workflow runs luacheck and busted, checks that the tag matches the .toc
   version, then builds `ForeverGroups/` and uploads it to every site whose id is
   in the .toc (`X-Curse-Project-ID`, `X-Wago-ID`, `X-WoWI-ID`).

The repository needs the secrets `CF_API_KEY`, `WAGO_API_TOKEN` and
`WOWI_API_TOKEN` (Settings → Secrets and variables → Actions), and workflow
permissions set to "Read and write". `python3 scripts/package.py` still builds
the same zip locally in `dist/`.

## Credits

The dungeon entrance positions come from the ForeverDungeonJournal addon by
Exehn;
the descriptions of how to get in are our own. The boss counts per dungeon
(rare spawns left out) are based on its boss lists.
