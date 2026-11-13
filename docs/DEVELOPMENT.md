# Forever Groups — development notes

How the addon works inside, for anyone reading or changing the code. The player-facing overview is the
[README](../README.md).

## Layout

- `core/` – pure Lua 5.1, no WoW API: protocol, queue, matchmaking, election, proposals, engine
- `wow/` – thin WoW layer: hidden channel, send queue, invites, `/fg` commands (`/dq` still works); `wow/ui/` window and proposal popup;
  the main window is `wow/ui/window.lua` plus its parts in `wow/ui/window/` (shared, card, setup, quests, tabs); the
  card (status, "Looking now", the group; with a group, the dungeon's picture as a banner behind its title,
  `W.paintBanner`: the popup's crop narrowed to the wider banner, across the inner panel (`W.cardBleed`, from the
  ButtonFrameTemplate Inset's anchors) with the card's background, the member places under it; a shade behind the
  text and a faded lower part). Without tabs the Inset's top moves up under the title bar (`W.fitInset`). The connection is a dot in the title bar, left of the
  close button, with its word only while not plainly connected (`W.refreshConnection`); there is no connecting
  card, and in a party the tabs stay away while connecting (`W.groupTab`); while connecting the dot pulses (an
  OnUpdate on the bar) and the join button reads "Connecting..."
  leads the window, except alone and choosing: then the roles come first and
  the card, without a title, follows them (`W.cardBelowRoles`)
- every whisper the addon sends goes through `wow/whispers.lua` (`Whispers.send`), which hides its "To ..." echo in
  the player's chat with a `CHAT_MSG_WHISPER_INFORM` filter (exact text and name, for 10 s); a leader asked
  automatically (`Whispers.expectReplies`, 90 s) has their whispers kept out with a `CHAT_MSG_WHISPER` filter, and a
  question of theirs (`Replies.isQuestion`) gets the `askAnswer` message; joining their group ends the hiding
  (`Whispers.stopQuiet`), and each answer goes to the log (`Log.detail`). `core/replies.lua` reads English and the
  common words of Russian, German, French, Spanish and Portuguese (words split on spaces, punctuation and digits,
  so UTF-8 letters stay whole; Cyrillic listed capitalised too, as `string.lower` only lowers A-Z). Both filters are off with
  `db.showSentWhispers` or `db.debug`
- how a group comes about is kept out of sight: process lines use `Log.detail` (saved log; chat only with
  `/fg debug on`, `db.debug`), and `Status.current` adds the asking/filling details only with `db.debug`; the chat
  gets outcomes ("Group found for X: you're the Tank.")
- `wow/ui/findertab.lua` adds a launcher tab to WoW's Group Finder (`LFGParentFrame`, from the load-on-demand
  `Blizzard_GroupFinder_VanillaStyle`) with WoW's `LargeSideTabButtonTemplate`, under the last side tab (LFGForever's
  `LFGForeverBlizzardTab` when present, re-placed on show). It only opens our window and closes theirs
  (`HideUIPanel`, out of combat); that Group Finder is secure code, so its panels are never shown or read
- `tests/helpers/wowmock.lua` has no `require`, like WoW: a module loaded before one it uses fails the tests
- `media/` – `icon.tga` (64×64, 32-bit uncompressed, top-left origin; the only image in the package) and the logo
  for README and download sites (`logo-1024.png`, `logo-400.png`); their SVG sources are in `media/source/`
  (`logo.svg`, `icon.svg`; the ribbon's font is Cinzel from Google Fonts). Render them with headless Chrome
  (`--screenshot --default-background-color=00000000`), scale down with `sips -z`, and write the icon as an
  uncompressed TGA: `sips -s format tga` gives RLE
- `probe/ForeverGroupsProbe/` – API probe addon for in-game checks (`/fgp help`)
- `tests/` – busted specs; `tests/helpers/sim.lua` simulates engines on a shared channel,
  `tests/helpers/wowmock.lua` loads the full addon (per the .toc) into mocked WoW clients

## How the network behaves

All clients join the hidden channel `ForeverGroupsNet` (realm-wide). Queued players re-send their entry every 45 s.
The matchmaker is the queued player whose client has been online longest (ties by name), so the role stays with a
stable client. The three likeliest matchmakers also send a keep-alive (`v2|K`) every 10 s; one that is silent for 25 s
is skipped and the next takes over. Any message of a player counts as alive in both queues (dungeons and questing),
and a keep-alive is only sent when the client sent nothing else in the last 10 s, so a player in both queues sends
one stream of keep-alives, not two. A client that joins asks for the state (`v2|S`); queued players (in both queues: the questing engine answers the
dungeon protocol's sync too) answer with their
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
The same answers tell an older client that it is behind. Hovering "Connected" lists them; `/fg online` prints them.

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
LOAD=1 .lua51/bin/busted tests/load_spec.lua   # channel load measurement (left out of the normal run)
LOAD_CLIENTS=150 LOAD_SECONDS=300 .lua51/bin/busted tests/load_spec.lua   # a bigger one
python3 scripts/package.py        # dist/ForeverGroups-<version>.zip with only what the .toc loads
```

`tests/soak_spec.lua` runs ten simulated players doing random things in both queues (joining, leaving, answering
proposals, logging out) and checks after every step that nobody is stuck: no queue held without a proposal in the
other, no proposal open past its deadline, no popup without a proposal or proposal without a popup. The mock keeps
Group Finder results secret during chat-messaging lockdown (`World.SECRET`), as Midnight does.

`tests/load_spec.lua` (only with `LOAD=1` or a `LOAD_*` setting) measures the channel load: many dungeon engines on one channel, with players logging in and
out, reloading, queueing and answering proposals, once at a quiet login rate and once at a busy one (`LOAD_LOGINS`,
about what ~5000 players online would give). It prints the messages per second by kind, the queue messages per
queued player (and what that means for 1000 queued), how long a newcomer and a reloaded matchmaker take to see the
whole queue, the wait until a group per role, and how long `findGroups` takes on queues of 250 to 1000 players.

In game, `/fg selftest` tells which client features Forever Groups can use, and `/fg bugreport` opens the version,
the self-test, the addon's last errors (kept by a chained error handler, `wow/diagnostics.lua`) and the log, ready
to copy.

## In game

`/fg` (or the AddOns menu at the minimap) opens the window: role, party roles (party leader), dungeons, Join/Leave.

`/fg join <tank|healer|dps> [auto | dungeon, ...]`, `/fg leave`, `/fg status`, `/fg dungeons`,
`/fg accept`, `/fg decline`, `/fg invite`, `/fg debug`, `/fg log [n]`,
`/fg style <relaxed | learning | serious | expert>`, `/fg progress`.
`/fg slots <t> <h> <d>` shrinks the group for testing with fewer players (only the matchmaker's setting counts).

### Playstyle

A dropdown on the line under the role tiles, on the left (dungeons tab only; `W.buildPlaystyle` in `wow/ui/window/setup.lua`): the choice
and WoW's own dropdown button (atlas `common-dropdown-a-button`, with its `-hover` and `-pressedhover` states; the
plain `Arrow-Down-Up` when the atlas is missing) in a rounded box like the role tiles, as wide as the longest
playstyle and centred on the "I'd like to lead" checkbox, on a `DropdownButton` whose `SetupMenu` builds WoW's own menu with a radio per
playstyle (its tooltip says who you're grouped with). A client without `DropdownButton` gets our own list instead
(`wow/ui/playstylemenu.lua`). It offers "Any" (the default, `Playstyles.ANY`) and the four playstyles of WoW's Group
Finder: Relaxed, Learning, Serious or Expert (the words come from `GetGeneralPlaystyleString`). "Any" goes with
everyone; Learning and Relaxed players are grouped together, and so are Serious and Expert ones; the two camps never
are (`core/playstyles.lua`). The playstyle travels in the queue entry, the matchmaker keeps each group within one camp,
and a client turns down a proposal that mixes them. The proposal popup, the status and the party message name the
group's playstyles, the one most players picked first (on a tie the calmer one). While the popup asks, the main window
steps aside (`Window.stepAside`) and comes back once the proposal ends, if it was open (`Window.comeBack`).

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

The role tiles show the class in that role (`Specs.forRole`, `Widgets.setTileLook`): the tree it plays the role with
(the current one if it fits, else the first), as retail's spec art (atlas `spec-thumbnail-<class>-<spec>`, cut to the
tile around its upper middle, under a gradient dark at the bottom; Feral as tank gets the guardian art), with a small
role icon at the bottom left and the role and the tree's name (when it is certain) on one line beside it. The art
exists in Forever's client for all nine classes (`/fgp classart`, `/fgp specart`). Unticked tiles are dimmed and grey;
a role the class can't play keeps the plain tile with the large role icon. "Needed most" is a small label at the top
left. The group card's member places (`Widgets.paintSlot`) show a member's spec art when the spec is known (their
own, learned from the queue or by inspecting; `Spec.indexOf`, `Specs.artFor`) and plays the place's role; else the
tree their class plays that role with (`Specs.forRole`: a Feral druid healing shows Restoration; the group popup
the same through `Spec.labelInRole`); when several trees could, or nothing is known, their class's emblem
(`classicon-<class>`, dimmed), both filling the place, with class and spec on one line; art is cut to shape by `Widgets.coverAtlas`. In the
rounded boxes (role tiles, member places) art runs up to the border and follows the round corners through a mask
(`Widgets.roundArt`, `Interface\Common\common-iconmask`; `/fgp mask`); without mask support it stays 5 px in. `/fg preview` shows the card with a sample group
(`W.previewComposition`), to see it without being in a group.

### Battlegrounds tab

`core/battlegrounds.lua` lists the battlegrounds: Warsong Gulch (10 players, from level 10) with its Group Finder
activity (Forever's "Battlegrounds" category 118 offers only Warsong Gulch, activity 919; `/fgp pvp`), Arathi Basin
(15, from 20) and Darkspear Islands (15, from 30, Forever's own), which only the Forever Groups queue finds players
for. Battlegrounds put players together by level bracket (10-19, 20-29, ...), so only listings whose leader is in the
player's bracket count. `LfgList` searches that
category as a third kind of result (`searchBattlegrounds`, `battlegroundListings`), each listing with its open places
(`open`: the battleground's size less its members; roles hardly matter). The tab (`wow/ui/window/battlegrounds.lua`)
shows the role tiles, the wish to lead (`charDb.wantsLeadBattlegrounds`), the ticked battlegrounds
(`charDb.battlegroundUnticked`) with counts per role and groups with room, and Who is looking shows those listings.
Signing up stays the player's: at a battlemaster (`C_PvP.JoinBattlefield` is protected), where a leader can sign the
whole group up.

Find group on the tab looks two ways at once, whichever finds a group first: the Forever Groups battleground queue
(below) for all ticked battlegrounds, and WoW's Group Finder (`wow/bgfinder.lua`) for the first ticked one it lists;
Stop ends both. The Group Finder side takes a group size ("Party (5)" or "Premade (10)",
`charDb.bgSize`). Alone and not wishing to lead, it first asks the leaders of listed groups in the bracket with room,
one at a time (the `bgAsk` whisper; the next after 20 s, at once on a no or when the group leaves the Group Finder;
answers and questions handled as for dungeons) and joins an asked leader's invite (`noAutoAcceptAsked` turns that
off); after 60 s without one (also when no group is listed, so the Forever Groups queue gets its chance first), or
with the wish to lead, or as a party leader, it builds the group from listed solo
players in the bracket (the longest listed first, but healers first while the group lacks one per five players:
the player counts when they ticked Healer, invited healers while in the group or on the way; the places still
lacking a healer stay open, and the card says "Still looking for N healers"; the
`bgInvite` whisper before each invite; no answer within 30 s or a decline frees the place, read from WoW's own
`ERR_DECLINE_GROUP_S` / `ERR_ALREADY_IN_GROUP_S` texts through `Filler.declinedName`). Once a player it invited
joins, the dungeon and questing queues are left (`Queues.leaveOthers`; while it builds they ignore the roster). While
it looks, the role tiles and battleground ticks are locked. A leader asked by hand from Who is looking counts as asked
for 5 minutes, as for dungeons. Past five players the
party becomes a raid first (`C_PartyInfo.ConvertToRaid` works from a timer, `/fgp raid`; WoW makes it one a moment
later). Once the group has its size, Find group ends with "sign it up at a battlemaster"; leaving the
group while it builds stops it. The card shows what it does,
and once signed up WoW's battleground queue (`GetBattlefieldStatus`: signed up with the estimated wait, ready to
enter, inside). Who is looking's "Request to join" asks a battleground group's leader the same way.

The battleground queue is a third engine (`wow/bgqueue.lua`) on the same channel with its own messages: the dungeon
protocol under the prefix `b1|` (`Protocol.BATTLEGROUNDS`, any roles up to five). An entry lists battleground keys
with the bracket (`wsg-20`: Warsong Gulch at 20-29, `Battlegrounds.key`). `core/bgmatch.lua` anchors a group on the
longest waiting player and one of its keys and adds the others who wait for it (more shared keys first, then by
waiting time) up to a party of five; two players are enough. Parties never merge (at most one entry with more than
one player, which leads); otherwise the wish to lead decides. One healer when someone heals, the rest DPS where they
can. A party leader waits with the party, and the Group Finder invites on their way keep places (`reserved`, the
proposal's `missing`); a raid or a party of five leaves the queue, as does joining someone else's group. While solo
Forever Groups players wait for the same battleground, the Group Finder leaves places open for them
(`BgQueue.soloWaiting`). Once a group forms the leader invites; for Warsong Gulch the leader's Find group goes on
filling it from the Group Finder up to the chosen size (`BgFinder.onFormed`), for the others the leader is told to
sign it up at a battlemaster; everyone else stops looking. A `/reload` keeps the place (`charDb.bgQueue`), as for the
other queues. Queue messages are capped at 255 bytes, so the queue forms parties of at most five; a premade of ten
fills on from the Group Finder as a raid.

All three queues go along (`wow/queues.lua`): a player can wait in each; while one has a group proposal for the
player the others step out, and once a group forms the others are left ("A dungeon group formed, so you left the
battleground queue."), and Find group through the Group Finder stops.

### Quests tab

The window has three tabs at the top: Dungeons, Quests and Battlegrounds. While the player waits in only one queue
the tabs are hidden and links under the page ("Also find a questing group »", "Also find a battleground group »")
open another queue's page with the tabs; in more queues the tabs show, each with its timer (`W.queueTab` in `wow/ui/window/shared.lua`). The chosen tab shows the
art of WoW's Group Finder buttons (`groupfinder-button-dungeons` / `-questing`, found with `/fgp finderart`; the
`groupfinder-background-*` versions are too dark); the chosen
tab's picture runs on under it across the content and fades out, as one picture (`paintArt` in
`wow/ui/window/tabs.lua`, parts of the atlas through `Widgets.atlasPart`); the other tab shows only its name. With tabs
the inner panel starts right under their gold base line, which replaces its top border (the Inset's
`NineSlice.TopEdge` and top corners are hidden, `W.fitInset`) and runs between its side edges (`W.panelEdges`); the
chosen tab's sides run into it with an outward rounded corner. The Quests tab lists the group and elite quests in the quest
log outside dungeons: quests WoW tags Group (`C_QuestLog.GetQuestTagInfo`, tagID `Enum.QuestTag.Group`) or suggests
a group size for (`suggestedGroup`); Dungeon, Raid and PvP quests and quests under a dungeon's header are left out.
Every listed quest is ticked until the player unticks it. "Find questing group" queues the player with the chosen
roles; a party leader queues the whole party (members keep their party roles) for the ticked quests the party is
not already big enough for, and a party that changes leaves the questing queue. Playstyles do not apply to quests.
A `/reload` keeps the place in the questing queue (`charDb.questQueue`). For both queues: back within 2 minutes
(`Config.ENTRY_TIMEOUT`) keeps the old place; back within 15 minutes (`Config.RESTORE_WINDOW`, a disconnect) queues
again at the end; later, not at all.

The questing queue is a second engine (`wow/questqueue.lua`) with its own messages: the dungeon protocol under the
prefix `q1|` (`Protocol.QUESTS`), where a group has at most one tank and one healer and the rest DPS. A queue entry
lists quest keys (`176-3`: quest 176 for a group of 3, the size WoW suggests or 3) where a dungeon entry lists
dungeons. `core/questmatch.lua` anchors a group on the longest waiting player and one of its quests, takes players
who share more of its quests first, then healers, then by waiting time, and keeps the playstyle camps apart; the
group is complete at the quest's size.

Once a group forms, the status bar's quest icon folds out a progress panel right under the bar
(`wow/ui/progresswindow.lua`; `/fg progress` does the same) that shows how far everyone is: for a questing group its quest(s), for a dungeon group the player's quests for that dungeon. Members
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

A small bar (`wow/status.lua`: addon icon, dungeon or quest name, a progress line for bosses or players found, and
icons to share quests and fold out the quest progress) sits under the minimap by default (drag to move, click to open the window) and shows what is going on whenever
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
presses and clicks in the game world (a keyboard frame that passes every key through, and a hook on the world
frame's mouse-down; `wow/keysearch.lua`), at most every 10 s and never in combat (`/fg autosearch` turns it off). A click on the status bar or minimap button also searches. While queued or filling, input refreshes results older than 30 s even when no role is open
right now, so a decliner is replaced from fresh results; the filler keeps using results up to 5 minutes old (players
who delist drop out of them as WoW reports it) before it waits for input.

### WoW's Group Finder

One setting, "Use WoW's Group Finder", turns all of the below on or off (`wow/features.lua`). Off, Forever Groups
only works with other Forever Groups players: it does not search, ask, invite from or list in the Group Finder, and
the "looking" counts show Forever Groups players only. On, each part has its own setting under it (refresh on key
presses, ask groups, invite listed players, list the group, invite players who whisper, every language, dry run);
those are greyed out while the main setting is off.

When queued players cannot make a full group, the matchmaker proposes a partial group right away (`PARTIAL_AFTER = 0`; at least 2
players); the roles left open are filled from WoW's own Group Finder: the leader's Accept click also runs a Group
Finder search (searching is protected and needs a click), then the best listed solo players (right role, level and
dungeon; single-role players first, longest listed first) get a whisper and an invite. Anyone who declines or does not
join within 30 s is replaced (a player who joins later is kept while a spot is open). The invite follows the whisper
after 1.5 s, so an away player's automatic reply (`CHAT_MSG_AFK`/`CHAT_MSG_DND`) comes first and they are passed over
uninvited. Every open invite takes a place in the party, also one given up on: WoW keeps an unanswered invite open
for exactly 60 s. The filler counts those places and invites no more than the party has room for; after WoW's
`ERR_GROUP_FULL` ("Your party is full") right after one of its invites it invites nobody for 10 s. A pending invite
can't be taken back (`C_PartyInfo.UninviteUnit` is protected and left the invite open in the probe). The group card
fills its open places with `Filler.invites()` by role: the invited player's name with "invited" and the seconds left
of the 30, or "frees in" and the seconds until WoW drops a given-up invite. `/fg preview` shows both in its sample group. A role that a solo Forever Groups player
waiting in the queue for the dungeon can play is left to the matchmaker first (`addonRoles` in `wow/filler.lua`);
only the other roles go to the Group Finder, and that role too if the matchmaker has not grouped them within 20 s. "Fill from Group Finder" in the window (or `/fg fill`) does the same for your own party;
`/fg dryrun` only prints the picks. Filling has no window of its own: what it waits for goes to the saved log
(`Log.detail`, chat with `/fg debug on`) and the status bar shows who is invited.

Roles in the group (`wow/rolesync.lua`): each player's Forever Groups role is set in WoW's party frames once. A
player who then picks another role keeps it, except the player's own role when it is one they did not queue for:
the spec decides it elsewhere: Deadly Boss Mods sets the role from the spec 2 s after joining a group or a /reload
(`DBM:RoleCheck`, first DAMAGER, then the spec's role; found with the probe's role watch, which logs every
`UnitSetRole` with its Lua stack). While Forever Groups holds the player's role, `DBM.RoleCheck` is wrapped to do
nothing (in Forever's client it only sets the role; outside such groups DBM works as always), and the check DBM
already planned while loading (before Forever Groups loads) is called off with `DBM:Unschedule`; the saved roles
count from the moment the addon loads. Any other change is
set back: right away from a `hooksecurefunc("UnitSetRole")` hook, else when WoW reports it (at most once per 5 s);
only with several roles ticked may it change between them. In a group Forever Groups follows the player's role is
always held: the current one if ticked, else the first ticked one. The agreed roles are kept in `charDb.roleSync`, so they still hold after a /reload; and in a group
Forever Groups follows (`GroupView.isTracking`) with nothing agreed for the player, a role outside the ticked ones
gives way to the first ticked one. Groups the addon does not follow are left alone. The group card
shows each member in their own role (two tanks as two tanks) and as open places what a group of one tank, one
healer and three DPS still lacks (`GroupView.composition`).

### Both directions

Forever's Group Finder is the board-style one (Blizzard_GroupFinder_VanillaStyle): no applications, players and
groups are listed and people whisper or invite each other. So a solo player first asks listed groups that need one of
their roles to invite them, by whisper to the leader (one at a time; listings up for 30 min or more last (`LfgPick.OLD_LISTING`, often an
away leader), then nearest to full, then the most recently listed; the next after 20 s without an invite, so two
invites never arrive at once; a leader asked automatically is not asked again for 15 min, also in a later queue or
after a reload (`charDb.askedLeaders`); the questing queue the same), and waits 60 s in all, or less: with no group left to ask and every asked leader clearly done (a no, full or gone),
building starts at once (`Apply.wantsToBuild`). Replies are matched to the asked leader with or without a realm
(`Whispers.find`), and `WhisperInvite` ignores leaders we asked. An asked leader's invite
is accepted at once while still looking, or for a "Request to join" click (`Group.acceptInvite`; off with
`noAutoAcceptAsked`). An invite from a listed group brings up WoW's role window (`LFGInvitePopup`, with
`PARTY_INVITE_REQUEST`'s tank/healer/damage flags) instead of the plain popup, and it stays up after joining
(probe, 2026-11-12); it is closed with `StaticPopupSpecial_Hide` right away and again after 0.3 and 1 s, and the role
is set through `RoleSync.expect` (`UnitSetRole("player")` once in the group). An ask offers one role
(`LfgPick.askRole`): of the player's roles the scarcest the group still needs (tank, then healer, then DPS); with the
open places unknown (battleground asks, or a listing without them) healer, then DPS, then tank.
The ask's whisper names only that role and its spec, and the player joins with it, unless the invite asks for other
roles; then `LfgPick.joinRole` takes DPS while the group has a DPS place, else tank, else healer, from the listing's
open places, else the invite's flags. Quest and battleground asks do the same. An ask ends early when results that came in after it no longer list the group (by name, or as a
result id still listed: `LfgList.stillListed`, since a leader's name can arrive late) or show no
place for the player's roles, or when the leader whispers a clear no; a clear yes gives the leader 30 s more, also
past the 60 s (`core/replies.lua` reads the answer: refusal and yes words and phrases, "no problem" taken out first;
both or neither is left open). An invite from an asked leader holds off building; joining that group leaves the
Forever Groups queue. With no fitting group, or no invite in time, the player builds a group instead (inviting a player
makes you a party leader, after which another group's invite cannot be accepted, hence this order). A solo player who
ticked "I'd like to lead" (on the right of the line under the role tiles; `charDb.wantsLead` for dungeons,
`charDb.wantsLeadQuests` for group quests, each going into its own queue's entry) asks no groups (`Apply.isSeeker`, and the questing
side in `wow/questfinder.lua`) and builds the group right away. The wish travels as the last field of the queue
entry (`v2|Q|…|<lead>`, "1"; older clients ignore it), and `Matchmaker.chooseLeaderEntry` picks the leader in this
order: a party (it never breaks up), a solo player who would like to lead, the tank, the earliest entry. While a group is
being filled it is also listed in the Group Finder (`wow/lfglisting.lua`; listing is protected, so it waits in
`wow/input.lua` for the next key press or click). Searches include every language unless "Find players of every
language" is off; without a language filter the server only returns the player's own language.

WoW returns at most 100 results per search, and its "found" count is just the number returned (no paging; five
low-level dungeons together already give 100, one alone 40-70 at a busy time; `/fgp lfgapi`). So a search covers
one part (`searchParts` in `wow/lfglist.lua`): the main part is the dungeons that matter (being filled, else queued
for, else ticked); the rest of the player's level, only for the window's numbers, is searched on its own. While
nothing is known about the rest yet, the first search covers everything at once (part "all"), so every dungeon has
numbers right away; the next key press or click, at least 1.5 s later, searches the main part on its own, and after a
main search the rest follows the same way while the main results are younger than the refresh interval
(`LfgList.searchRestIfDue`, called from `wow/keysearch.lua` and from `LfgList.searchIfStale`). What counts as the
player's input for a search (`/fgp clicksearch`): key presses (a frame that lets keys through), a left click on the
3D world (`WorldFrame` OnMouseDown), zooming the camera (`CameraZoomIn`/`CameraZoomOut`), using an action button
(`UseAction`) and moving the mouse onto the main window or Who is looking (`KeySearch.watch`, OnEnter); not
`GLOBAL_MOUSE_DOWN` nor turning the camera (`CameraOrSelectOrMoveStart`), which are blocked. One click or key press allows one search: a second `Search` in the same handler is
`ADDON_ACTION_BLOCKED` (`/fgp lfgapi twice`), so the parts can't be searched at once. The server answers in about
0.2 s and allows about two searches (of any kind) per five seconds; a third is refused (`LFG_LIST_SEARCH_FAILED`
"throttled"), refused tries don't count (`/fgp lfgapi gap 1.5`, with the addon's own searches off: two in a row always
worked, the third within ~5 s always failed). So `LfgList` keeps the times of its searches (dungeons, zones and
battlegrounds alike, `roomToSearch`): with two in the last 5.5 s a search waits and goes out on a later input
(`retryPart`; `Filler.searchAgain` then says so instead of warning). A refused search is undone (its dungeons count
as not searched, the part keeps its turn, the search times go back) and tried again on input at least 3 s later, at
most 3 times in a row. Wailing Caverns alone already gives 100 results at a busy time. Results replace only the listings of the dungeons searched
(`coveredActivities`), and a listing for dungeons of both parts (it comes back in each search under a new id) is
kept once per leader, the newest; listings of a part not searched again are dropped after 2 minutes; a search from Blizzard's window replaces them all. Alone and looking with one role, the main
search uses WoW's advanced filter (`Search`'s sixth argument, built from `C_LFGList.GetAdvancedFilter` with the
activities' `groupFinderActivityGroupID`s, which Forever requires, and one of `needsTank`/`needsHealer`/
`needsDamage`): the server then leaves out groups without a place for that role, solo players stay. With several
roles there is no filter: the server reads several as "needs all of them" (`/fgp lfgapi healdps`, 2026-11-13: 8
groups needing a healer and DPS, none needing only one of them, where the plain search had 3 and 16 of those). A click on a role tile also sets WoW's Group Finder roles to the ticked ones (`LfgList.syncRoles`,
Forever's `C_LFGListRoles.SetRoles`; only from that click, off for the session after an error). On a trial account
(`IsTrialAccount`, `IsVeteranTrialAccount`) a login message says addon messages, and so the queue, don't work there
(Forever 1.60.1).

Players who see the listing whisper the leader (there are no applications). While a group is being built,
`wow/whisperinvite.lua` invites a whisperer who names a role that is still open ("heal?", "dps lf group"), asks once
which role they play when they only ask to join ("inv pls"), and says which roles are needed when theirs is taken.
The status shows the phase: "Asking groups to invite you (2 asked) · own group in 0:18", then "Building your own
group: inviting …".

### Who is looking

`wow/ui/queuewindow.lua` is a drawer of the main window: a separate window docked to the right of the main window
(left when there is no room on the screen), with a tab between them (`QueueWindow.attach`, made with the main window:
the Group Finder eye and an arrow that points the way the drawer moves) that opens and closes it. It opens with the
main window unless the player closed it (the tab, its close button or Escape while the main window stays:
`db.whoClosed`); `/fg queue` opens it. Opening with the main window doesn't search (that can come from code; a
search must follow a click), the tab and `/fg queue` do. `Window.refresh` also refreshes it, so it follows the main
window's tab, roles and dungeons, and so do new Group Finder results (`LfgList.onUpdate`). Ticking a dungeon the
last search didn't ask for searches at once (`LfgList.searchIfMissing`, from that click); unticking only filters. It moves with the main window and hides with it. No tabs: two framed blocks, one per source, each with a header band (icon and name; the Group Finder's also says
when it last searched): **Forever Groups** with Parties and then Players (queued solo players), and **WoW Group
Finder** with Groups and then Players (solo players listed for your dungeons). Every table has the same columns: Roles (what the
players can play; a party or group: the roles already in it), Needs (the places a party or group still has open,
empty for a solo player; a party's from `Filler.missingFor`, a listed group's from its `remaining`), Name ("+N" for
the other members), Lvl, Dungeons and Time. Hovering a party or group lists who is in it and what it needs, plus a Group Finder listing's note
(`listing.comment`, also for a solo player). WoW passes the note as a protected `|K...|k` string: shown as text by a
font string or tooltip, but unreadable to addons, so it cannot be matched to quests. An empty table shows only its caption and a line of
text, without column headers. Each table folds (its caption is a +/- button) to one line with a summary ("5 tanks,
16 DPS", "12 need DPS"). By default the half that fits what the player does is open: players with "I'd like to
lead" on (they build a group), groups otherwise (they look for a place); a fold the player sets is kept in
`db.queueFold` until the wish to lead changes, which brings back that choice's defaults. A click
on a header sorts that table only, a second click reverses; each table keeps its own order for the session only (not saved, a reload
brings back the default: by role), shown by WoW's `Arrow-Up-Up`/`Arrow-Down-Up` next to the active header (a column marked
`descending` points down unreversed); the Show filter
matches a solo player's roles and a party's or group's needs. Right-clicking a row opens `wow/ui/playermenu.lua`
(WoW's `MenuUtil` context menu, else a small menu of our own): Whisper and Invite to group for a player; Request to
join and Whisper leader for a group. Request to join whispers the leader the `applyAsk` message
(`LfgApply.request`); the request is remembered for 5 minutes so the leader's invite is recognised. For a questing group
it is the `questAsk` message naming a wanted quest in the group's zone (`QuestFinder.request`). Opened from the Quests
tab the window shows group quests instead (`QueueWindow.subject()`, which follows the main window's page, also when
that page changes by itself), without the playstyle filter and without a Needs column for questing parties (quest
groups have their own sizes and no fixed roles): the questing queue, and the Group Finder's "Quests & Zones"
listings (`LfgList.zoneListings`) in the zones of the wanted quests (the questing entry's, else the ticked ones) and in
every zone whose suggested levels (the zone activity's `minLevelSuggestion`/`maxLevelSuggestion`, verified for all 41
zones) include the player's level (`LfgList.zonesForLevel`), with a
Quests/Zone column; it searches those zones on input. An open window switches along with the main window's tab (`QueueWindow.follow`). The Quests tab shows
the same counts per quest (`lookingCounts(wanted, "quests")`, `groupsNeedingMe(wanted, "quests")`). The main window
counts, per dungeon and in "Looking now", the listed groups that need one of the player's ticked roles
(`QueueWindow.groupsNeedingMe`, from the listings' `remaining`); the dungeon's tooltip names their leaders. These
counts are hidden when Forever Groups won't ask groups for you: with "I'd like to lead" on (per tab) or with asking
groups switched off (`db.noApply`); "Who is looking" still lists the groups. Next to that count a dungeon row says
how much the player's roles are wanted (`W.demand` in `wow/ui/window/setup.lua`): "Tank needed" (green) when fewer
others looking can play that role than a group has places for it, "quiet" when no group needs them and nobody
looks; only for dungeons whose
Group Finder numbers are known (`LfgList.isSearched`: in the last dungeon search, or no activity, or the Group
Finder off). Before queueing, a dungeon search asks for the ticked dungeons and every dungeon for the player's
level, so the unticked rows are known too; once queued or filling, only those dungeons. The role tile of the role
needed most for the ticked dungeons (fewest looking per place in a group, among the roles the class can play; none
on a tie or with nobody looking) says "Needed most" (`W.neededRole`, `Widgets.paintNeeded`), not while queued and
not on the Quests tab.

### During and after forming

- **Joining:** the leader's client invites everyone (`wow/group.lua`, from a timer, which Forever allows). A
  member who accepted the proposal accepts the invite of that proposal's leader from `PARTY_INVITE_REQUEST` with
  `AcceptGroup()` and hides WoW's invite popup (`StaticPopup_Hide("PARTY_INVITE")`); verified in Forever with
  `/fgp autoaccept`. It first marks the popup `inviteAccepted` (its OnHide declines otherwise). The leader's
  invite is also accepted while the proposal is still open and the player answered yes, since it can arrive
  before the last answer; the expected leader is forgotten after 2 minutes. Off with the `noAutoAccept` setting;
  other inviters are never accepted.
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
  queue the group for a replacement (Forever Groups and the Group Finder, the leaver excluded); with
  `db.autoReplace` that happens without the popup. Only the popup's click searches the Group Finder; without it the
  filler starts from the current results and `wow/keysearch.lua` refreshes them on the next key press. While the
  followed run goes on (`GroupView.isActive`) the window shows no setup (roles, party, dungeons); for the leader with
  an open place its main button is "Find replacement" (`Run.findReplacement`, the same as the popup's).
- **Taking the lead:** a member of a dungeon group with open places whose leader has no Forever Groups (not seen by
  `Presence`) gets a "Make me leader" button next to "Looking now" (`wow/takelead.lua`). It whispers the leader
  the `askLead` message; once the player leads within 10 minutes (`PARTY_LEADER_CHANGED` / `GROUP_ROSTER_UPDATE`),
  `Run.fillGroup` queues the group and fills it like a replacement, without a Group Finder search.

### Languages

What the player reads is translated: `core/locale.lua` keeps the translations (`locales/deDE.lua`, `esES.lua` for
esES and esMX, `ruRU.lua`) keyed by the English text, and `ns.L["English text"]` gives the player's language
(`db.language` from Settings → Display → Language, else `GetLocale`), English when a text has none. Texts set once
when a window is built follow a new choice after a /reload, which the settings offer in a popup. Placeholders keep their order (Lua's `string.format` has no positional
arguments). `Log.info`/`Log.warn` translate their format themselves (the saved log stays English), and so do the
widgets for their labels and tooltips (`Widgets.button`, `check`, `header`, `link`, `tab`, `window`, `tooltip`) and
`W.setHint`; `ns.Locale.count(n, one, many)` picks singular or plural. Texts defined as data are marked with
`ns.Locale.mark(...)` (returns its argument). Whispers and party messages stay English (`Widgets.describeRolesEnglish`,
`Dungeons.englishName`, `Battlegrounds.englishName`); dungeon and battleground names on screen come from the client
in its language (`GetActivityInfoTable(...).fullName`, `C_PvP.GetBattlegroundInfo`). `tools/localekeys.lua` lists
every key from the source (`lua tools/localekeys.lua`), and `tests/locale_spec.lua` checks that each language has
all of them with the same placeholders. Not translated: the protocol's own error texts, `/fg selftest` and debug lines.

### Messages and settings

Every whisper and party message the addon sends is a template in `wow/messages.lua` (`Messages.LIST`), editable and
switchable in the settings' Messages tab (`wow/ui/messageswindow.lua`), with placeholders `{dungeon} {quest} {zone}
{size} {role} {roles} {spec} {level} {battleground}`. In the asks to a leader `{spec}` is the spec that plays the
roles looked for (`Spec.myLabel(roles)`: a Feral druid looking as healer is a Restoration Druid; the class alone when
several specs could). A sentence whose placeholder is empty is dropped, `|` escapes are stripped and
the text is cut at 255 bytes. Sent messages start with `[Forever Groups]` (the ask to a leader ends with
"(Forever Groups)"), so incoming whispers with that mark are ignored. The settings window (`wow/ui/settings.lua`) has
the tabs Groups, Messages and Display.

### In the group

- **Specs without the addon:** `wow/inspectspec.lua` inspects one party member at a time out of combat
  (`NotifyInspect`, `INSPECT_READY`, the talent config `-1`) and reads their tree like `wow/spec.lua`; again after
  10 minutes.
- **Where everyone is:** members send `v1|GP|<dungeon>|<in|far|yards>` on PARTY (`wow/groupplaces.lua`), so the card
  shows "inside" or the distance to the entrance even when the player is already inside.
- **Secret values:** during boss fights Midnight makes chat event arguments secret (strings that error on any string
  operation). `wow/events.lua` replaces them with nil before any handler sees them (`ns.isSecret`).

### Test tools

- `/fg fake <n> [roles]` adds local fake players (default: a mix of roles, also combinations). They are never sent
  to the channel, never become matchmaker, never expire, and are only grouped with you; they accept 1-3 s after a
  proposal. `/fg fake decline` / `/fg fake afk` makes the first fake in the next proposal decline / stay silent;
  `/fg fake clear` removes them.
- `/fg queuelist` lists the queue in chat with tags (you, fake, in a proposal).
- Fake players get made-up names (`Slash.fakeName`), a class and spec that can play their roles
  (`Slash.fakeSpec`, a different class in turn) and queue for the dungeons of your level.
- `/fg debug` logs every sent/received message and, when it changes, why the matchmaker did or did not form a group.

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
