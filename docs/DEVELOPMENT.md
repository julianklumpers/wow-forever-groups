# Forever Groups — development notes

How the addon works inside, for anyone reading or changing the code. The player-facing overview is the
[README](../README.md).

## Layout

- `core/` – pure Lua 5.1, no WoW API: protocol, queue, matchmaking, election, proposals, engine
- `wow/` – thin WoW layer: hidden channel, send queue, invites, `/fg` commands (`/dq` still works); `wow/ui/` window and proposal popup;
  the main window is `wow/ui/window.lua` plus its parts in `wow/ui/window/` (shared, card, setup, compose, levels,
  quests, battlegrounds, tabs). It is one screen per tab that stays the same while choosing, searching and in a
  group: the tabs (not in a group Forever Groups follows), the role tiles with join/lead and the playstyle (`W.layoutChoices`), then the
  status (`W.layoutStatus` in `card.lua`: a title line such as "In queue 4:31 as DPS" with the crown when leading,
  a line or two under it, and on the Dungeons tab the group's five places as place cards, `W.paintPlace`; with a group the
  dungeon's name and "Group complete · Relaxed · 3 of 5 at the entrance" on one line), the class choices only while
  not searching (`W.layoutCompose`; while searching the places take their spot), the level limit, then the list to
  tick with "Looking now" on its header line (`W.layoutHeaderLooking`, for dungeons, quests and battlegrounds);
  while the tab's queue searches the list makes way and "Looking now" follows the status title instead
  (`W.layoutLookingAfterStatus`); once Forever Groups follows a group, its actions come instead of the dungeon
  list (`W.layoutActions`: Waypoint to entrance, Share my quests, Quest progress). The bottom row has Find group (Stop while searching, with roles,
  how much is ticked and the time in the queue on its right, `W.searchSummary`), Find replacement, Remove LFG
  listing and, for a member whose leader has no addon, Make me leader. A party member sees the status and places
  without role tiles. When a group Forever Groups follows starts (a run, a questing group) the window turns to its
  tab (`W.followGroupTab`), and the tabs make way while it lasts (`W.paintTabs` returns false, the inner panel
  moves up under the title bar: `W.fitInset`, `W.insetTop`), since a group leaves the other queues. The connection is a dot in the title bar, left
  of the close button, with its word only while not plainly connected (`W.refreshConnection`); there is no
  connecting card; while connecting the dot pulses (an OnUpdate on the bar) and the join button reads
  "Connecting...". Hovering a member's place while a leader sets up the party tells the roles they are queued for
  and where those come from (`PartyRoles.sourceOf`)
- while the open tab's queue searches (or a group proposal waits) its choices stay in sight but are locked
  (`W.locked` in `shared.lua`): the role tiles show the roles the entry searches with, the others dimmed
  (`W.shownRoles`, `Widgets.paintTile`'s `locked`); but while the tab's queue searches, and in a formed group or
  run, the choices are hidden altogether (role tiles, join/lead, the playstyle, the
  battleground group size, the level limit; `W.hideChoices`): the status, the places and Stop say what it searches
  with, and to change anything the player presses Stop and finds a group again. Another tab's choices stay open.
- a line the addon says in party chat goes through `Whispers.sayParty`, which logs whether it went out (WoW is silent
  when it does not); the group-complete message also logs why it was not said
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
- the main window's design system (`wow/ui/window/shared.lua`): one content box with the same margin (`W.MARGIN`,
  18) inside the gold frame's border on both sides, which is what the eye measures against; that border is about 8
  wide on the left and 6 on the right (`W.BORDER_LEFT`/`W.BORDER_RIGHT`, measured in game): `W.PAD` its left edge, `W.RIGHT` its right edge (`W.RIGHT_OFFSET` for a TOPRIGHT anchor), `W.CONTENT` its width.
  Gaps are steps of `W.SPACE` (4, 6, 8, 12, 16, 24). Rows of tiles or cards are cut with `W.columns(count, gap)`,
  which hands the pixels left over from dividing to the first columns so a row fills the box exactly (the role
  tiles and the party cards, both `W.SPACE.s` apart)
- the one-second tick (`wow/main.lua`) and the Group Finder's result listeners (`wow/lfglist.lua`) run each part in
  its own `pcall`: an error goes to WoW's error handler and the other parts go on
- Limiting levels (Dungeons and Quests tabs, under "Lead a group"): `core/levels.lua` (min and max, 0 for no limit on
  that side, `untilAt` as for the class wishes) goes with the queue entry as its 12th field (`<until>:<min>:<max>`)
  while the player builds the group and has switched it on (`wow/partylevels.lua`, `charDb.levelsOn`; `untilAt` always 0: it holds for as long as the queue
  entry). Each side is a default until the player types a level there
  (`PartyLevels.limit`): the lowest and highest level of the ticked dungeons (the queue entry's while queued), on the
  Quests tab or with none ticked the player's level ±3; a typed level (`charDb.levelLimit`, `{ min, max }`, nil for a
  default side) never changes by itself, and emptying the box puts the side back to its default (a limit saved
  before, with `at`, is dropped). A default never crosses a typed side. One limit
  for every ticked dungeon or quest; a ticked dungeon whose range has no level within it gets an orange warning
  (`PartyLevels.outside`). Matchmaking: an entry with a limit in force anchors its own group and takes only solo
  players whose level fits (`Matchmaker.candidateFor`, also used by `core/questmatch.lua`); it leads. `Fill.pick`
  (`levels`), applicants and the quest finder's invites take only listed players within it (an unknown level does
  not fit); Who is looking fades players outside it, with the reason in the row's tooltip (`item.unwanted`; also for
  a class without a free place) and "faded: outside your limits" in the table's caption; right-click still invites. A whisperer's level is not known: one who joins outside it is
  named in chat once (the party there when the limit began counts as fixed). The block (`wow/ui/window/levels.lua`):
  "Limit levels" with "from [ ] to [ ]" (numeric boxes, saved on leaving the box when changed; a default in grey, a
  typed level in white)
- Matching by game language (see Game language below): `core/languages.lua` goes with every queue entry of all three
  queues as its 13th field (`<code>:<mask>`, e.g. `deDE:3`)
- Choosing the classes in the party: a leader's class wishes per place of a dungeon group (`core/compose.lua`: places T, H, D, D,
  D; per place a mask of the nine classes, 0 for any; `untilAt` server time after which anyone may join, always 0
  from the window: the wishes hold for as long as the queue entry, without a time after which anyone may join). They go
  with the dungeon queue entry as its 11th field (`v2|Q|...|<lead>|<until>:<m>.<m>.<m>.<m>.<m>`; older clients
  ignore it) while the player builds the group (party leader, or alone with "Lead a group") and has switched it on
  ("Choose the classes in my party", `charDb.composeOn`; switched off, the choices stay in `charDb.compose`;
  `wow/partycompose.lua`, set on join and on every change). Only when the player saw them when the search began:
  each search the player starts (Find group in the window or `/fg join`, Find questing group, Fill from Group
  Finder; not a replacement search or a restored queue) notes per tab whether the player built the group then (`PartyLevels.noteStart`, `charDb.wishesHidden`); a player who pressed Find group with "Join a group"
  and is made leader of the group Forever Groups builds for them keeps neither class choices nor level limit
  (`PartyLevels.wishesCount`). Among the group's places an open place with a wish shows the wished classes as round
  icons where the spec line goes (`row.classes` from `PartyCompose.freePlaces`, matched to the open places by role
  in order; `W.paintPlace`), their names on a client without the class icons. The player's own place and the party
  members' are fixed (no wish), each in the first place of their role. Matchmaking (`Matchmaker.findGroups`/
  `findPartialGroup`, given `now`): an entry with wishes in force only anchors its own group, takes only solo
  players (their class from their spec), narrows each candidate's roles to those with a place for their class
  (`restrictFor`), and a finished group must give everyone a place of their own (`pickFor`, `Compose.place`: exact,
  so two Mages don't share one Mage place); a player of unknown class only takes a place open to any class. Such
  an entry leads its group (`composer` in `chooseLeaderEntry`), and as an anchor it may also take players who queued
  before it (`candidateIndices`; they cannot take it in; also in `core/questmatch.lua` for a level limit).
  One seating decides the leader's own group for everything (`Compose.seat` through `PartyCompose`'s `layout`):
  the player and the party first: a player keeps the place they were seated in before (`charDb.composeSeats`, by
  name, also after a /reload), else a place of their role without a wish (they never use up a wish meant for
  someone still to come; a Mage leader wishing for a Mage wants a second one), only then a wished place their
  class fits. Then the players on their way (`Group.expectedPlayers`, their class from their queue entry, and the
  invites still out, `Filler.pendingPlaces`, sorted by name) with `match`: a wished place their class fits first,
  the strictest first, as that is what they were taken for; the place they get is remembered, so they keep it
  once they join. The queue entry sends every place so taken without a wish (`seat.wire`; the matchmaker knows
  these players, and held places, only by role, so it counts them without a class: `restrictFor(..., own)`)
  and the filler, applicants, whisper invites and Who is looking use the places left (`seat.free`). A new player
  is taken when everyone picked so far and they still all fit those places (`Compose.fitsPlaces`), not by
  deciding a place for each in turn. While a party member's name loads, the entry keeps what it sent. `syncEntry`
  sends the wishes and the level limit with every queue update in the same message; when it no longer fits, the
  update goes without them (reported once, `reportTooLong`), as `ns.join` does, and they are not tried again until
  they change (`engine.unfit`). The matchmaker checks the wishes
  as each candidate is added (`feasible`, `Compose.fits` on everyone's roles so far), so a set that can never fit
  is dropped at once; before each dungeon's search a quick matching tells whether the places can be filled at
  all by the anchor and its candidates (`Compose.canFill`), so a wish for a class nobody queued costs next to
  nothing, and all leaders with wishes together get at most `WISH_BUDGET` of a round's search (`wishLeft`). A leader with
  wishes or a level limit also checks a proposal itself and turns it down when a player does not fit
  (`Engine:proposalKeepsMyWishes`, as a matchmaker of an older version doesn't know them; classes as
  `restrictFor` counts them). `Engine:changeEntry` keeps a field that does not fit the queue message out. An applicant's class comes from `GetApplicantMemberInfo`; a player who whispers has it from their
  Group Finder listing (`classToken`), else from the whisper's GUID (`GetPlayerInfoByGUID`, `CHAT_MSG_WHISPER`'s
  12th argument), and only gets a place open to any class when neither tells. Who is looking fades solo players who don't fit the places left. The
  block
  sits under the join/lead buttons on the Dungeons tab: the switch, and while it is on the five places side by side
  as place cards (below): the wished classes as their round `classicon-<class>` icons in a grid of up to three by
  three (on a client without those atlases by name in their class colour, two, then "+n more"), and the player's
  and the party's places with who is there (those can't be clicked). A place open to any class has a dashed edge, a
  "+" and "Any class". Each card is a dropdown like the playstyle's (a `DropdownButton` with WoW's dropdown
  arrow at its bottom right): WoW's own menu with "Any class" and a check per class the role allows, the names in
  their class colour, open while ticking; our own list (`wow/ui/classmenu.lua`) on a client without it. And Reset. Not done: a note in the own Group Finder listing (whether Forever's CreateListing takes
  one is unknown)
- the test mock makes clients that used the addon before unless `fresh = true` (see Demo for a new player's
  first opening)
- matchmaking (`core/matchmaker.lua`): `findGroups` goes over the queue once, each entry in turn anchoring a group
  with the earliest feasible set behind it (an exhaustive search within `SEARCH_BUDGET` steps a round, each anchor at
  most `ANCHOR_BUDGET` of them, split over its dungeons with at least `DUNGEON_MIN_BUDGET` each, so one anchor no
  group can be formed for never keeps the anchors behind it from their turn, nor one dungeon that can never fill
  (players who don't take each other's language) the anchor's other dungeons; an anchor that found nothing never finds a group later in the same run, as groups only take players away).
  The questing matcher searches the same way, with its own budgets. The questing and battleground
  matchers share its helpers (`wantsKey`, `sharedKeys`, `sharesPlayer`, `addNames`, `orderByLeader`). All three keep
  every pair in a group to players who take each other's language (`Languages.compatible` against the anchor,
  `Languages.fitsAll` against everyone chosen so far, also for partial groups). The queue's
  sorted list (`Queue:list`) and the election's candidates are worked out once per change to the queue
- `media/` – `icon.tga` (64×64, 32-bit uncompressed, top-left origin; the only image in the package: the minimap
  button, the AddOns list and Who is looking) and the logo for README and download sites (`logo-1024.png`,
  `logo-400.png`); all three are the one logo, its SVG source `media/source/logo.svg` (the ribbon's font is Cinzel
  from Google Fonts). Render it with headless Chrome (`--screenshot --default-background-color=00000000`), scale
  down with `sips -z`, and write the icon as an uncompressed TGA (`sips -s format tga` gives RLE): a short Python
  script that decodes the PNG with zlib and writes the pixels as BGRA does it. `banner.png` (1600×1000, for the
  download sites, not packaged) comes from `media/source/banner/banner.html` with its three screenshots:
  `"Google Chrome" --headless=new --hide-scrollbars --window-size=1600,1000 --virtual-time-budget=5000
  --screenshot=banner.png file://…/banner.html`; swap a screenshot by replacing its PNG there and rendering again
- `probe/ForeverGroupsProbe/` – API probe addon for in-game checks (`/fgp help`)
- `tests/` – busted specs; `tests/helpers/sim.lua` simulates engines on a shared channel, and can lose, hold back
  and reorder messages (`Sim:drop`, `Sim:lossy` with a seed, `Sim:releaseHeld`); `tests/helpers/wowmock.lua` loads
  the full addon (per the .toc) into mocked WoW clients, with WoW's limits: one Group Finder search per click or key
  press, about two per 5 s on the server (`LFG_LIST_SEARCH_FAILED` "throttled"), and an invite holding a party
  place for 60 s (`ERR_GROUP_FULL` past five)

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

Messages wait in a send queue (`core/outbox.lua`, 6 at once and 1 per second) while WoW throttles or blocks them;
some are worthless once late and expire there: a proposal after 8 s (before its members would count as gone), an
answer after 30 s, a keep-alive after 10 s. A send WoW refuses with a code we don't know (or that raises an error) is
retried 2 s later, up to 3 tries, before it is dropped; only an invalid prefix, message or chat type is dropped at
once. Every refused send is logged with WoW's code (`-> … [retry, code 9]`), version pings too. A proposal of ours
that expired or was dropped is called off on this client too (`Engine:cancelOwnProposal`, from `Comm.onDropped`):
its players are free again and nobody counts as gone.

Messages can get lost or arrive late, so a proposal is built to end the same way on every client. While it is open
each member sends its own answer again every 8 s (`Config.ANSWER_RESEND`), and an answer that arrives before its
proposal is kept for 10 s (`earlyAnswers`). A member whose group formed leaves the queue with
`v2|L|<matchmaker>|<seq>`, which counts as its Yes (a plain `v2|L` is a No; older clients ignore the extra fields),
and a client that formed the group answers anyone still sending answers for it with its Yes again (at most every
4 s). A proposal that reaches a member more than 10 s after it was made (the matchmaker already counts that member as
gone) is answered with a conflict and a new heartbeat, so the member keeps its place; one older than 30 s is
ignored. An entry that answered with a conflict is left out of matchmaking for 15 s (`Config.CONFLICT_PAUSE`) or until
its new heartbeat arrives. A queue entry lives on its own heartbeats only (`updatedAt` in `core/queue.lua`): any
message keeps a player alive for the keep-alive check, but not their entry, so a lost leave can't keep them in a
queue they left. `tests/network_spec.lua` covers each case, and a run with 15% of all messages lost (25 seeds) checks
that nobody leaves the queue without a group and that no leader misses the group its members formed. The answers
sent again cost about 0.5 messages/s at 30 queued (`LOAD=1` load test).

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
.lua51/bin/lua tools/simulate.lua busy 60 1 5 grace   # matchmaking variants (scenario, minutes, seed, runs, set)
python3 scripts/package.py        # dist/ForeverGroups-<version>.zip with only what the .toc loads
```

`tests/soak_spec.lua` runs ten simulated players doing random things in both queues (joining, leaving, answering
proposals, logging out) and checks after every step that nobody is stuck: no queue held without a proposal in the
other, no proposal open past its deadline, no popup without a proposal or proposal without a popup. The mock keeps
Group Finder results secret during chat-messaging lockdown (`World.SECRET`), as Midnight does.

`tools/simulate.lua` compares matchmaking variants without the game, second by second: Forever Groups players arrive
(roles, classes, 1-3 of 6 dungeons, some duos) and others see their entry 1-2 s later, the real
`Matchmaker.findGroups` / `findPartialGroup` run every 5 s at a moment of their own, and a player without a group
invites simulated Group Finder listings with the real `Fill.pick` / `Fill.plan` (60% accept after 5-20 s, the rest
time out after 30 s). A player with a possible partner waits the variant's `grace` first (`PARTNER_GRACE`), and a
group that builds leaves a role a queued solo Forever Groups player can play to them for 20 s (`ADDON_GRACE`, as
`addonRoles` in `wow/filler.lua`); one who invited anyone is a party for the matchmaker (open invites are reserved roles), two parties never merge, and an entry
whose invites fill the group leaves the matchmaker until a place opens (as `wow/main.lua` parks it). Every variant
replays the same arrivals and answers. Sets (`Sim.VARIANT_SETS`): `main` (current, no partial groups, no class
variety, no partner grace), `hold` (with and without leaving roles to Forever Groups players), `level` (with and
without the level preference), `adaptive` (the strict class time fixed at 5, 2 or 1 minutes, or growing with the
listed players available; measured: shorter saves at most ~30 s and gives 2-3x the class doubles, so 5 minutes stays)
and `grace` (0-20 s). Dungeons have levels (15-31) and players pick only those their
level fits; the "levels" column is the average gap between a group's highest and lowest level. The table shows groups by source (full from the queue, partial, a
lone player's own), the wait of queued players until their group is complete (average, median, 90th percentile, max),
who is still waiting at the end, groups with two of a class in one role or three of a class, Forever Groups players
per group, and the matchmaker's time per round. Left out: playstyles, languages, class wishes, asking listed groups
first. `tests/simulate_spec.lua` runs a short one so it keeps working.

`tests/load_spec.lua` (only with `LOAD=1` or a `LOAD_*` setting) measures the channel load: many dungeon engines on one channel, with players logging in and
out, reloading, queueing and answering proposals, once at a quiet login rate and once at a busy one (`LOAD_LOGINS`,
about what ~5000 players online would give). It prints the messages per second by kind, the queue messages per
queued player (and what that means for 1000 queued), how long a newcomer and a reloaded matchmaker take to see the
whole queue, the wait until a group per role, and how long `findGroups` takes on queues of 250 to 1000 players.

In game, `/fg selftest` tells which client features Forever Groups can use, and `/fg bugreport` opens the version,
the self-test, the addon's last errors (kept by a chained error handler, `wow/diagnostics.lua`) and the log, ready
to copy.

## In game

`/fg` (or the AddOns menu at the minimap) opens the window: role, dungeons, Join/Leave.

The minimap button (`wow/ui/minimap.lua`) is made with LibDBIcon-1.0 and a LibDataBroker launcher (bundled in
`libs/`, loaded first in the TOC; `libs/` is left out of luacheck), so minimap tools such as Leatrix Plus handle it
like any other addon's. It always shows the logo (`Widgets.ICON`); the status, the channel and what the clicks do
are in its tooltip. Left-click opens the window, right-click the settings, drag moves it (`db.minimapIcon`, which
takes over the old `db.minimapAngle`); `db.minimapHidden` hides it. The logo pulses while a group proposal waits.

`/fg join <tank|healer|dps> [auto | dungeon, ...]`, `/fg leave`, `/fg status`, `/fg dungeons`,
`/fg accept`, `/fg decline`, `/fg invite`, `/fg debug`, `/fg log [n]`,
`/fg style <relaxed | learning | serious | expert>`, `/fg progress`, `/fg demo`.

### Playstyle

A dropdown on the line under the role tiles, on the left (dungeons tab only; `W.buildPlaystyle` in `wow/ui/window/setup.lua`): the choice
and WoW's own dropdown button (atlas `common-dropdown-a-button`, with its `-hover` and `-pressedhover` states; the
plain `Arrow-Down-Up` when the atlas is missing) in a rounded box like the role tiles, as wide as the longest
playstyle, on a `DropdownButton` whose `SetupMenu` builds WoW's own menu with a radio per
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

### Game language

Players are grouped by the language of their WoW client, as in WoW's Group Finder (`core/languages.lua`,
`wow/matchlanguages.lua`). The own language is `GetLocale()` as the Group Finder names it (enGB → enUS, esMX →
esES, ptPT → ptBR); the player is grouped only with players of their own language unless they tick others in
Settings → Groups, "Languages you are matched with" (`db.languages`, a set of the extra codes; the old
`db.ownLanguageOnly` is cleared on load). The boxes are the codes `C_LFGList.GetAvailableLanguageSearchFilter()`
offers when the window shows (else enUS, deDE, esES, frFR, ruRU, ptBR), the own one ticked, greyed out and marked
"(your language)"; names are translated texts, not native ones (Western fonts have no Cyrillic).

Every queue entry (dungeons, quests, battlegrounds) carries the owner's language and the languages the owner takes
as the 13th field of `Q`: `<code>:<mask>`, the mask a bit per code of `Languages.CODES` in that order (enUS 1,
deDE 2, esES 4, frFR 8, ruRU 16, ptBR 32; the own bit always set), so `deDE:3` is a German client that also takes
English players. New codes go at the end of the list. A field that does not decode (an unknown code, no own bit) or
is missing (older versions, a client language outside the list) means unknown, and an unknown entry goes with
everyone. Two players may be in one group only when each takes the other's language; a party counts as its owner.
The matchers check every pair, and `Engine:proposalFitsMyEntry` turns down a proposal with a queued player who does
not fit (as for a playstyle). Ticking a box changes the entries of all three queues at once (`Engine:setLanguage`).
WoW's Group Finder searches with the same languages (`languageFilter` in `wow/lfglist.lua`: the own one and the
ticked ones it offers). The "looking" counts, the waiting counts of the Quests and Battlegrounds tabs, Who is looking
and the filler's and auto-fill's look at queued partners leave out players of a language that does not fit
(`Engine:sharesLanguage`). When the queue message is too long, `ns.join` and `syncEntry` drop the class wishes and
level limit first and then the language (reported once, `reportTooLong`): the entry then goes with everyone, and the
language comes back with the next join; `QuestQueue.join` does the same with the questing level limit and the
language. When an update does not fit even without them, the engine keeps the language its published entry still
has. The settings list only the codes of `Languages.CODES` (and the player's own) and keep room for all of them
(`MatchLanguages.mostOffered`).

### Spec

Forever has one specialization per class, with the three Classic talent trees side by side in one retail-style
talent tree (`C_ClassTalents` / `C_Traits`). A talent's column (its x position: below 4000, below 8000, above) tells
its tree, and the tree with the most points is the player's spec (`core/specs.lua`, `wow/spec.lua`; a tie means no
spec). The spec never takes part in matchmaking. When the spec changes (or the first time), its roles are ticked
(Feral ticks Tank and DPS); after that the player's own ticks stay, so a healer can still queue as DPS. Queueing with
roles that fit none of the spec gives a warning, nothing more. The spec travels in the queue entry ("SHAMAN2"), so
the proposal popup and the group's places show it for players with Forever Groups, and the whispers the addon sends name
it ("Level 20 Enhancement Shaman (DPS) here, could you invite me…"); the invite whisper only names it when the
player's own text has `{spec}`.

The role tiles show the class in that role (`Specs.forRole`, `Widgets.setTileLook`): the tree it plays the role with
(the current one if it fits, else the first), as retail's spec art (atlas `spec-thumbnail-<class>-<spec>`, cut to the
tile around its upper middle, under a gradient dark at the bottom; Feral as tank gets the guardian art), with a small
role icon at the bottom left and the role and the tree's name (when it is certain) on one line beside it. The art
exists in Forever's client for all nine classes (`/fgp classart`, `/fgp specart`). Unticked tiles are dimmed and grey;
a role the class can't play keeps the plain tile with the large role icon. "Needed most" is a small label at the top
left. Every place of a group in the window is the same place card (`wow/ui/window/placecard.lua`, `W.addPlaceParts`
and `W.paintPlace`): the class choices' cards and the group's places while searching and in a group. A thin rounded
edge drawn by the card itself, the role in the top left corner as on the role tiles (on a frame of its own above
the edge and art); a member's card shows their spec art when the spec is known (their
own, learned from the queue or by inspecting; `Spec.indexOf`, `Specs.artFor`) and plays the place's role; else the
tree their class plays that role with (`Specs.forRole`: a Feral druid healing shows Restoration; the group popup
the same through `Spec.labelInRole`); when several trees could, or nothing is known, their class's emblem
(`classicon-<class>`, dimmed), both filling the card; the name is always in the small font on one line (cut off with
"..."), the class's round icon right before it, the two centred together, and the line under it has the spec only
(the class name and spec on a client without class icons); where the points per tree are known (the player, and
members once inspected: `Spec.learn` keeps them, `Spec.treesOf`) it names the tree with the most points and any
other with at least a third of all points, most first ("Shadow/Holy" for 0/20/31 or 0/5/6, "Shadow" for 0/3/8,
"Holy" for 0/51/0), so it works at low level too (that line is 2 points smaller than the name, set from
`GameFontHighlightSmall`'s own size, as a font set by hand outlives `SetFontObject`); else, when no tree of theirs plays the place's role (a
Shadow priest in a healer's place, a Protection warrior as DPS, both with two trees that could) or nothing is known
yet, that line names the place's role ("Healer", "DPS"). An invited player shows dimmed with "invited 0:24" or
"frees in 0:24", an open place with a wish a gold edge and the wished classes, an open place without one a dashed
edge with "open" (with "+" and "Any class" where it can be chosen). Name and spec (or the invite line) sit in the
middle of the card. In a group a row comes under that: the distance (a dot and "at entrance", "120 yd", "far
away", or "offline" in red for a member WoW calls not connected, `UnitIsConnected`, which also brings the row
when it would show no distances) at the bottom left and the quests ("3 quests", left out for a member without Forever Groups) at the bottom
right, each in its half of the card (cut off with "..." rather than overlapping) and 3 points smaller than the name
(the spec 2); name and spec stay in the middle of the whole card; every card has the same height
(`W.PLACE_HEIGHT`, room for that row included) in every view, class choices too; the role icons are fully opaque, also of open and invited places; art is cut to shape by `Widgets.coverAtlas`. In the
rounded boxes (role tiles, member places) art runs up to the border and follows the round corners through a mask
(`Widgets.roundArt`, `Interface\Common\common-iconmask`; `/fgp mask`); without mask support it stays 5 px in. `/fg demo` shows the places with a
whole group (see Demo below).

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
lacking a healer stay open, and the status says "Still looking for N healers"; the
`bgInvite` whisper before each invite; no answer within 30 s or a decline frees the place, read from WoW's own
`ERR_DECLINE_GROUP_S` / `ERR_ALREADY_IN_GROUP_S` texts through `Filler.declinedName`). Once a player it invited
joins, the dungeon and questing queues are left (`Queues.leaveOthers`; while it builds they ignore the roster). While
it looks, the role tiles and battleground ticks are locked. A leader asked by hand from Who is looking counts as asked
for 5 minutes, as for dungeons. Past five players the
party becomes a raid first (`C_PartyInfo.ConvertToRaid` works from a timer, `/fgp raid`; WoW makes it one a moment
later). Once the group has its size, Find group ends with "sign it up at a battlemaster"; leaving the
group while it builds stops it. The status shows what it does,
and once signed up WoW's battleground queue (`GetBattlefieldStatus`: signed up with the estimated wait, ready to
enter, inside). Who is looking's "Request to join" asks a battleground group's leader the same way.

The battleground queue is a third engine (`wow/bgqueue.lua`) on the same channel with its own messages: the dungeon
protocol under the prefix `b1|` (`Protocol.BATTLEGROUNDS`, any roles up to five). An entry lists battleground keys
with the bracket (`wsg-20`: Warsong Gulch at 20-29, `Battlegrounds.key`). `core/bgmatch.lua` anchors a group on the
longest waiting player and one of its keys and adds the others who wait for it (more shared keys first, then by
waiting time) up to a party of five; two players are enough. Parties never merge (at most one entry with more than
one player, which leads), and a player listed twice (a stale solo entry next to the party's) is placed once;
otherwise the wish to lead decides. One healer when someone heals, the rest DPS where they
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

The window has three tabs at the top: Dungeons, Quests and Battlegrounds (not while in a group Forever Groups
follows), each with its queue's timer
while it waits; the player can wait in all three at once. The chosen tab shows the
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
prefix `q1|` (`Protocol.QUESTS`), where a group takes any mix of roles (the players decide; a tank and a healer are
only preferred when there are any). A queue entry
lists quest keys (`176-3`: quest 176 for a group of 3, the size WoW suggests or 3) where a dungeon entry lists
dungeons. `core/questmatch.lua` anchors a group on the longest waiting player and one of its quests, takes players
who share more of its quests first, then healers, then by waiting time, and passes over players only when the group
cannot be filled with them (a depth-first search in that order, within `SEARCH_BUDGET` steps a round and
`ANCHOR_BUDGET` per anchor, split over its quests with at least `KEY_MIN_BUDGET` each); at most one party per
group, as a player still in another party cannot accept the
invite. Playstyles do not apply; the group is complete at the quest's size.

Once a group forms, the status bar's quest icon folds out a progress panel right under the bar
(`wow/ui/progresswindow.lua`; `/fg progress` does the same) that shows how far everyone is: for a questing group its quest(s), for a dungeon group the player's quests for that dungeon. Members
with Forever Groups send their progress in hidden PARTY addon messages (`v1|QP|questID:done/total:complete,...`, or
`questID:t` once turned in; `wow/questgroup.lua`); members without it show "?". When the player has turned in a
questing group's quests, a popup asks whether to leave the group.

While queued, the questing queue also uses WoW's Group Finder (`wow/questfinder.lua`): it searches the "Quests &
Zones" category (one activity per zone, matched by name to the quest log's zone headers) for the zones of the queued
quests, on the click that queues and then on key presses like the dungeon side. A player who joins (not "Lead a
group") and is still alone first asks the leader of a listed group in the zone that still has room, one at a time
(the next after 20 s without an invite); only when there is no group left to ask, or when leading, are players
listed alone in a quest's zone invited, with a whisper that names the quest and offers to share it ("Inviting you
for Hogger (Elwynn Forest, group of 3). I can share the quest."); the entry then narrows to that quest with the
invited roles reserved, invitees who join become members, and the group is complete at the quest's size. Opening
the window searches for what its open tab shows (`QueueWindow.searchIfStale(30, tab)`: the quests' zones on the
Quests tab, the battlegrounds on the Battlegrounds tab), and every tab switch searches for the new tab
(`searchIfStale(0, tab)`, so only the burst limit holds it back). Who is looking's "searched … ago" note uses the
open tab's own search time. The group is listed in its
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
partial group); a player with no partner in sight fills from the Group Finder right away while staying in the queue. A possible
partner (same dungeon, language and playstyle camp, roles that fit; `hasPartner` in `wow/autofill.lua`) is waited for
at most 20 s (`PARTNER_GRACE`): the matchmaker may still refuse the pair (class wishes, a level limit, two leaders).
An incomplete group stays in the queue (same place) so later Forever Groups players can still join it. Group Finder
searches need player input: the Find group click, Accept, and, while roles are still open, the player's own key
presses and clicks in the game world (a keyboard frame that passes every key through, and a hook on the world
frame's mouse-down; `wow/keysearch.lua`), at most every 10 s and never in combat (`/fg autosearch` turns it off;
after a /reload in combat the keyboard frame is set up once the fight ends, `PLAYER_REGEN_ENABLED`). A click on the status bar or minimap button also searches. While queued or filling, input refreshes results older than 30 s even when no role is open
right now, so a decliner is replaced from fresh results; the filler keeps using results up to 5 minutes old (players
who delist drop out of them as WoW reports it) before it waits for input.

### WoW's Group Finder

One setting, "Use WoW's Group Finder", turns all of the below on or off (`wow/features.lua`). Off, Forever Groups
only works with other Forever Groups players: it does not search, ask, invite from or list in the Group Finder, and
the "looking" counts show Forever Groups players only. On, each part has its own setting under it (refresh on key
presses, ask groups, invite listed players, list the group, invite players who whisper); those are greyed out while
the main setting is off. The languages to be grouped with sit below them and also count while it is off (see Game
language).

When queued players cannot make a full group, the matchmaker proposes a partial group right away (`PARTIAL_AFTER = 0`; at least 2
players); the roles left open are filled from WoW's own Group Finder: the leader's Accept click also runs a Group
Finder search (searching is protected and needs a click), then the best listed solo players (right role, level and
dungeon; single-role players first, longest listed first) get a whisper and an invite. For the first 5 minutes of a
group Forever Groups starts (`VARIETY_TIME`; not a run's replacement, `Filler.start`'s `replacement`; not while the
leader's class wishes have a free place; `db.noClassVariety` turns it off) nobody is picked whose class the group
(members and invites out, with their roles) already has in that role, or has twice (`Fill.avoided`, `MAX_OF_CLASS`;
`Filler.avoidClasses` → `Fill.pick`'s `avoid`, also for applicants to our listing): a Paladin tank and a Paladin DPS
are fine, a third Paladin waits. The matchmaker holds groups from the queue to the same rule while their anchor (who
waited longest) has waited less than `Config.VARIETY_TIME` and has no class wishes (`checkFor` in
`core/matchmaker.lua`: a complete set is accepted only with a role assignment, from every assignment
`Roles.options(…, true)`, that passes `varied`; partial groups too). It knows only each entry's owner's class (from
the spec on the wire); a party's other players and places held for invites count as unknown and are never held back.
Only the elected matchmaker computes groups, so an older one simply leaves the rule out. Past that time the rule is a
preference: `Fill.pick`'s `prefer` (`Filler.preferClasses`) picks with it first and fills the roles left open with
anyone who fits ("Passed over … another class was listed" in the log); the matchmaker keeps the first complete set that
is not varied as a fallback, looks `PREFER_BUDGET` steps further for a varied one, and takes the fallback when there is
none (`canStayVaried` prunes sets that can never be varied while the rule is hard).
Levels are a preference too (never a limit; the dungeon's levels and a level limit still are): `Fill.pick`'s `near`
(`Filler.groupLevel`, the player's and the party's average) puts the closest level before the longest listed, after
single-role players; the matchmaker sorts an anchor's candidates by how far their average level is from the anchor's
(`Matchmaker.levelPreference`, `averageLevel`), whoever waited `VARIETY_TIME` counting as near, then by queue order. A whisperer held back waits in `wow/whisperinvite.lua` until then; the log counts
them per role ("of a class your group has in that role or twice, for 95 s more"). The test mock turns it off unless a client
is made with `classVariety` (its listed players are mostly Paladins). Anyone who declines or does not
join within 30 s is replaced (a player who joins later is kept while a spot is open). The invite follows the whisper
after 1.5 s, so an away player's automatic reply (`CHAT_MSG_AFK`/`CHAT_MSG_DND`) comes first and they are passed over
uninvited. Every open invite takes a place in the party, also one given up on: WoW keeps an unanswered invite open
for exactly 60 s. Every invite the addon sends goes through `wow/invites.lua` (the filler, the battleground and quest
finders, a formed queue group, whisper invites and the player menu), which counts the places open invites hold until
they are answered, joined or 60 s old. A /reload keeps them (`charDb.invites`, with their ages). The queue entry
saved for a /reload (`charDb.queue`) carries the filler (`Filler.saved`, `Filler.restore`: the roles sought, the
invites still out, who not to invite again), so it fills on without whispering and inviting the same players twice.
When members and invites take all five places the party leaves the queue for the moment (`parked` in
`wow/main.lua`) and joins again at its old place once a place frees; that too is saved, and after a /reload the
filler goes on and replaces whoever declines. The filler, the battleground finder and the quest finder invite no more than
the party has room for after those. WoW's `ERR_GROUP_FULL` ("Your party is full") names nobody and belongs to the
invite sent last (`Invites.onRefused` tells its sender, which may pick that player again); the filler then invites
nobody for 10 s. A pending invite
can't be taken back (`C_PartyInfo.UninviteUnit` is protected and left the invite open in the probe). The group's places
fill their open places with `Filler.invites()` by role: the invited player's name with "invited" and the seconds left
of the 30, or "frees in" and the seconds until WoW drops a given-up invite. A role that a solo Forever Groups player
waiting in the queue for the dungeon can play is left to the matchmaker first (`addonRoles` in `wow/filler.lua`);
only the other roles go to the Group Finder, and that role too if the matchmaker has not grouped them within 20 s. "Fill from Group Finder" in the window (or `/fg fill`) does the same for your own party;
Filling has no window of its own: what it waits for goes to the saved log
(`Log.detail`, chat with `/fg debug on`) and the status bar shows who is invited. When a role stays open while
players are listed for it, the line says why they were passed over (`Fill.skipped`: already invited/asked/declined,
outside the dungeon's levels, outside the level limit, a class the class choices leave out, another playstyle,
picked for another role). The saved log keeps 2000 lines (`wow/log.lua`); the version pings (`DQV|`) are not
logged, they used to push everything else out within minutes. In the developer copy only (a
`--@do-not-package@` block, stripped from releases by the packager), with `/fg debug on` it keeps 10000 lines and
logs the same party message (`-> party …`, sent every few seconds) once per 10 minutes.

Roles in the group (`wow/rolesync.lua`): each player's Forever Groups role is set in WoW's party frames once. A
party member who then gets another role keeps it when they offered it (the roles of their Group Finder listing or
application, `RoleSync.expect`'s third argument, kept in `charDb.roleSyncOffered`; any role when not known); one they
did not offer is WoW setting the role from their spec (a Feral druid invited as healer becomes the tank 6 s after
joining), so the leader sets it back, at most twice (`MAX_RESETS`), after which it counts as their own choice; a
player who is not the leader (who cannot set others' roles) takes the member's role over at once. The
same goes for the player's own role when it is one they did not queue for:
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
gives way to the first ticked one. Groups the addon does not follow are left alone. The group's places
show each member in their own role (two tanks as two tanks) and as open places what a group of one tank, one
healer and three DPS still lacks (`GroupView.composition`).

### Both directions

Forever's Group Finder is the board-style one (Blizzard_GroupFinder_VanillaStyle): no applications, players and
groups are listed and people whisper or invite each other. So a solo player first asks listed groups that need one of
their roles to invite them, by whisper to the leader (one at a time; listings up for 30 min or more last (`LfgPick.OLD_LISTING`, often an
away leader), then nearest to full, then the most recently listed; the next after 20 s without an invite, so two
invites never arrive at once; a leader asked automatically is not asked again for 15 min, also in a later queue or
after a reload (`charDb.askedLeaders`); the questing queue the same), and waits 60 s in all, or less: with no group left to ask and every asked leader clearly done (a no, full or gone),
building starts at once (`Apply.wantsToBuild`). Replies and invites are matched to the asked leader with or without a
realm (`Whispers.find`), and `WhisperInvite` ignores leaders we asked. A leader counts as asked only once the whisper
went out. An ask is over as soon as WoW reports its group delisted (`LFG_LIST_SEARCH_RESULT_UPDATED`, `LfgList.isDelisted`;
the listeners hear of it within 0.5 s), without waiting for the next search. The battleground and questing finders keep
their asks in `core/asks.lua` (`Asks`: when, from which result, the role offered, a yes, a no, a question answered);
the dungeon side keeps its own in `wow/lfgapply.lua`. An asked leader's invite
is accepted at once while still looking, or for a "Request to join" click (`Group.acceptInvite`; off with
`noAutoAcceptAsked`). Several parts may know the inviter (a queue group, an asked leader); the first to accept takes
the invite and the others leave it alone for 2 s (`Group.justAccepted`). An invite from a listed group brings up WoW's role window (`LFGInvitePopup`, with
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
chose "Lead a group" (one of two buttons, "Join a group" | "Lead a group", at the left of the line under the role
tiles on every tab, with the playstyle (dungeons) or the group size (battlegrounds) at its right and the questing
hint on the line below; `W.layoutLead`; a party leader gets no choice there, a party always leads, and on the Dungeons tab the status
title ("Your party: 2/5") takes that line instead, left of the playstyle (`layoutChoices`' shareLine, `W.playstyleRoom`); `charDb.wantsLead` for dungeons,
`charDb.wantsLeadQuests` for group quests, each going into its own queue's entry) asks no groups (`Apply.isSeeker`, and the questing
side in `wow/questfinder.lua`) and builds the group right away. The wish travels as the last field of the queue
entry (`v2|Q|…|<lead>`, "1"; older clients ignore it), and `Matchmaker.chooseLeaderEntry` picks the leader in this
order: a party (it never breaks up), a solo player who would like to lead, the tank, the earliest entry. While a group is
being filled it is also listed in the Group Finder (`wow/lfglisting.lua`; listing is protected, so it waits in
`wow/input.lua` for the next key press or click). Searches pass the player's own language and the ones ticked in the
settings as the language filter (see Game language); without a filter the server only returns the own language, and
a result does not say its language.

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
most 3 times in a row. A refused zone or battleground search gets its search time back too, so the next input asks
again instead of waiting on the old results. Wailing Caverns alone already gives 100 results at a busy time. Results replace only the listings of the dungeons searched
(`coveredActivities`), and a listing for dungeons of both parts (it comes back in each search under a new id) is
kept once per leader, the newest; listings of a part not searched again are dropped after 2 minutes; a dungeon search from Blizzard's window replaces them all. Results the addon can't place (no dungeon, zone or battleground among them) count only when its own search is waiting for an answer (`pending.kind`); otherwise they are another category searched in WoW's window and left alone. A dungeon search with no activity to search (The Stockade alone) is not sent. Alone and looking with one role, the main
search uses WoW's advanced filter (`Search`'s sixth argument, built from `C_LFGList.GetAdvancedFilter` with the
activities' `groupFinderActivityGroupID`s, which Forever requires, and one of `needsTank`/`needsHealer`/
`needsDamage`): the server then leaves out groups without a place for that role, solo players stay. With several
roles there is no filter: the server reads several as "needs all of them" (`/fgp lfgapi healdps`, 2026-11-13: 8
groups needing a healer and DPS, none needing only one of them, where the plain search had 3 and 16 of those). A click on a role tile also sets WoW's Group Finder roles to the ticked ones (`LfgList.syncRoles`,
Forever's `C_LFGListRoles.SetRoles`; only from that click, off for the session after an error). On a trial account
(`IsTrialAccount`, `IsVeteranTrialAccount`) a login message says addon messages, and so the queue, don't work there
(Forever 1.60.1).

Players who see the listing whisper the leader (there are no applications). While a group is being built,
`wow/whisperinvite.lua` invites a whisperer who names a role that is still open ("heal?", "dps lf group"), asks
which role they play when they only ask to join ("inv pls"), and says which roles are needed when theirs is taken.
An answer that names no role ("i can tnak") is asked again, at most three questions in all (`MAX_ASKS`); a line
within 3 s of the question ("inv?") is not taken as the answer. Role words are matched exactly, never guessed. Each
step goes to the saved log with the whisper's first 80 characters.
When open invites hold every party place (`Filler.room`), a whisperer gets no answer yet and is invited (with the
usual answer) as soon as a place frees, within an invite's 60 s (`WhisperInvite.tick`).
Asking groups happens out of sight: no status, window or chat line says how many were asked (only the saved log
does). With `/fg debug on` the status shows "Building your own group: inviting …" once the filler runs.

### Who is looking

`wow/ui/queuewindow.lua` is a drawer of the main window: a separate window docked to the right of the main window
(left when there is no room on the screen), with a tab between them (`QueueWindow.attach`, made with the main window:
the Group Finder eye and an arrow that points the way the drawer moves) that opens and closes it. It opens with the
main window unless the player closed it (the tab, its close button or Escape while the main window stays:
`db.whoClosed`); `/fg queue` opens it. Opening with the main window doesn't search (that can come from code; a
search must follow a click), the tab and `/fg queue` do. `Window.refresh` also refreshes it, so it follows the main
window's tab, roles and dungeons, and so do new Group Finder results (`LfgList.onUpdate`). Ticking a dungeon the
last search didn't ask for searches at once (`LfgList.searchIfMissing`, from that click); unticking only filters. It moves with the main window and hides with it. No tabs and no part per source: two tables that each hold both sources, **Groups** (Forever Groups' queued
parties and the Group Finder's listed groups) and then **Players** (queued solo players and solo players listed
for your dungeons), with "(n  ·  m in Forever Groups)" in the caption while the Group Finder is used. Every row
has an icon at its far right for where it comes from (the addon's icon or the Group Finder eye, `row.source`; a
Forever Groups row's tooltip says it too). A player in both sources shows once, from Forever Groups (`combined`), and on a sort tie
Forever Groups comes first. Refresh is a small button in the title bar, left of the close button, with WoW's own refresh icon
(`Interface\Buttons\UI-RefreshButton`, its Group Finder's) on the close button's frame level; what it does is in
its tooltip; when the Group Finder was last searched ("searched 12 s ago") sits left of it in the title bar (a
font string of the Refresh button, so on its level). The top line is the filter boxes'; a caption's summary is
cut short at the caption's width. Both tables have the same columns: Roles (what the
players can play; a party or group: the roles already in it), Name ("+N" for
the other members; before it, `row.badge`, a crown for a party or group, a solo player's `classicon-<class>`),
Classes (up to five class icons: a listed group's members, a Forever Groups party's leader; its header and cells
stay empty in the Players table, so the columns still line up), Needs (the places a party or group still has open,
empty for a solo player; a party's from `Filler.missingFor`, a listed group's from its `remaining`; a Forever
Groups party with class wishes shows per open place the classes wished for, else the role, four icons or three and
"+n", with "Wants: ..." in its tooltip, `wishesOf`: of each role the places with a wish are open, since a place a
member holds wishes for nothing), Lvl, Dungeons and Time. A listing's and an applicant's roles are only those its class can play
(`Classes.filter`: WoW lets a Warlock tick tank and healer too). A table longer than its rows scrolls with the mouse
wheel and WoW's own scroll bar (`MinimalScrollBar` through `CreateFrame("EventFrame", ...)`, its `OnScroll` callback
and `SetScrollPercentage`/`SetVisibleExtentPercentage`; found with `/fgp scrollbar`; a thin track on a client
without it). A listed
group's members are read with `GetSearchResultPlayerInfo(id, i)` (class, assigned role and level, the leader first;
`listing.memberInfo`) and listed in its row's tooltip, tank, healer, DPS, as two columns (`AddDoubleLine`: class
icon through `|A:classicon-<class>:14:14|a`, class, the leader's crown and name; role and level). Hovering a party or group lists who is in it and what it needs, plus a Group Finder listing's note
(`listing.comment`, also for a solo player). WoW passes the note as a protected `|K...|k` string: shown as text by a
font string or tooltip, but unreadable to addons, so it cannot be matched to quests. An empty table shows only its caption and a line of
text, without column headers. Each table folds (its caption is a +/- button) to one line with a summary ("5 tanks,
16 DPS", "12 need DPS"). Both tables are open by default; a fold the player sets is kept in `db.queueFold`
(`{ groups, players }`), also when they switch between joining and leading. A click
on a header sorts that table only, a second click reverses; each table keeps its own order for the session only (not saved, a reload
brings back the default: by role), shown by WoW's `Arrow-Up-Up`/`Arrow-Down-Up` next to the active header (a column marked
`descending` points down unreversed). Four filter boxes start the window's top
line (`BOXES`), each WoW's own menu with one filter (`Widgets.dropdown`, `SetupMenu`; without WoW's menu they are
hidden and nothing is filtered): **Roles** (a solo player's roles, a flexible player shows for any of them),
**Classes** (in their colour with `classicon-*`), **Needs** (a group's open places; quest and battleground groups
have none, so the roles in them; plus Room for my class: an open place of a role the player's class can play, for
a Forever Groups party with class wishes one wished for that class or any class, `openPlaces` shared with
`wishesOf`) and **Level** (players near my level, groups near my level: within 3 levels, `NEAR_LEVELS`; a group by
the average of its members' levels where known, else its leader's). Role icons in the current style
(`Widgets.roleMarkup`, the classic file cut with WoW's `GetTexCoordsForRole`); checks keep the menu open. Each menu
starts with "All roles" / "All classes" / "All groups" / "All levels", a check ticked while the box filters nothing,
that turns its filters off (a check like "Any class" of the class choices; a plain menu button for this did nothing
in game). A box without a filter says that "All …"; with one it shows it in gold: "Roles: Tank/Healer",
"Classes:" with up to three class icons and "+n", "Needs: Healer" with the player's class icon for room for their
class, "Level: 17-23". Up to three class icons, so all four boxes fit on the line with filters on. Kept in `db.whoFilter` (`{ players = { roles, classes,
near }, groups = { needs, myClass, near } }`); the old `db.queueRoles` is taken over for both tables once. An empty
filtered table says "Nobody matches your filters." / "No group matches your filters.". Right-clicking a row opens `wow/ui/playermenu.lua`
(WoW's `MenuUtil` context menu, else a small menu of our own): Whisper and Invite to group for a player; Request to
join and Whisper leader for a group. Request to join whispers the leader the `applyAsk` message
(`LfgApply.request`); the request is remembered for 5 minutes so the leader's invite is recognised. For a questing group
it is the `questAsk` message naming a wanted quest in the group's zone (`QuestFinder.request`). Opened from the Quests
tab the window shows group quests instead (`QueueWindow.subject()`, which follows the main window's page, also when
that page changes by itself), without the playstyle filter and without a Needs column for questing parties (quest
groups have their own sizes and no fixed roles): the questing queue, and the Group Finder's "Quests & Zones"
listings (`LfgList.zoneListings`) in the zones of the wanted quests (the questing entry's, else the ticked ones); with
no such quest, in every zone whose suggested levels (the zone activity's `minLevelSuggestion`/`maxLevelSuggestion`,
verified for all 41 zones) include the player's level (`LfgList.zonesForLevel`). The Group Finder cannot tell who
does which quest (no quest activities on Forever), so a ticked quest narrows the list to its zone. With a
Quests/Zone column; it searches those zones on input. An open window switches along with the main window's tab (`QueueWindow.follow`). The Quests tab shows
the same counts per quest (`lookingCounts(wanted, "quests")`, `groupsNeedingMe(wanted, "quests")`). The main window
counts, per dungeon and in "Looking now", the listed groups that need one of the player's ticked roles
(`QueueWindow.groupsNeedingMe`, from the listings' `remaining`); the dungeon's tooltip names their leaders. These
counts are hidden when Forever Groups won't ask groups for you: with "Lead a group" chosen (per tab) or with asking
groups switched off (`db.noApply`); "Who is looking" still lists the groups. Next to that count a dungeon row says
how much the player's roles are wanted (`W.demand` in `wow/ui/window/setup.lua`): "Tank needed" (green) when fewer
others looking can play that role than a group has places for it, "quiet" when no group needs them and nobody
looks; only for dungeons whose
Group Finder numbers are known (`LfgList.isSearched`: in the last dungeon search, or no activity, or the Group
Finder off). Before queueing, a dungeon search asks for the ticked dungeons and every dungeon for the player's
level, so the unticked rows are known too; once queued or filling, only those dungeons. The role tile of the role
needed most for the ticked dungeons (fewest looking per place in a group, among the roles the class can play; none
on a tie, with nobody looking, or for a class with only one role) says "Needed most" (`W.neededRole`, `Widgets.paintNeeded`), not while queued and
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
  login. A dungeon without one (The Stockade) is only listed under "Other dungeons". Below level 10 (`W.DUNGEON_LEVEL`; WoW's Group
  Finder is closed to the player then) the window lists no dungeons and no "Other dungeons", only "Dungeons open up
  at level 10."
- **Quest sharing:** in a group being built, party members with Forever Groups exchange which quests they have for the
  dungeon over PARTY addon messages (`v1|QL|dungeon|questID,...`, asked for with `v1|QR|dungeon`: on a roster
  change, and once connected after a login or /reload (`QuestShare.onReady`), as the lists live in memory only and
  party messages are read only once the own name is known); the window shows
  the counts per player, and "Share my quests" shares every shareable quest, 1.5 s apart (`wow/questshare.lua`).
  Sharing also happens by itself (`QuestShare.autoShare`, off with `db.noAutoShareQuests`) 5 s after the roster
  changes or a list arrives: each of our shareable quests for the dungeon that a member lacks is shared, by the
  first by name of the Forever Groups players holding it, once per member (`sharedTo`, so a member who joins later
  gets it too). A member with Forever Groups whose list has not come in is waited for once (5 s more); one without
  it gets the quest unless `C_QuestLog.IsUnitOnQuest(unit, id)` says it has it (that says false at a distance, and
  WoW skips members already on the quest: "X is already on that quest."). Sharing from a timer is allowed
  (`/fgp sharequest later`, 2026-11-14). With members without Forever Groups in the party (no list, not seen by
  `Presence`), each Forever Groups player asks the party once on coming into the group to share theirs
  (`QuestShare.askParty`, the `partyAskQuests` message; not with `db.noPartyAnnounce`). Only once the group is
  complete and announced (`GroupView.wasAnnounced`, so after "Group complete!") or inside the dungeon, so nobody
  invited later misses it: also a player who joins a run
  under way, but not one who saw a boss die in this run (`Run.current().kills`; a /reload in the dungeon with a
  level-up's roster update once asked mid-run). The one asking sends `v1|QA|dungeon` on the PARTY addon channel, and
  who hears it does not ask; at a new group the players ask in order of name, 3 s apart, so only the first does. A
  share WoW turns down with `ERR_QUEST_PUSH_TOO_FAR_S` or `ERR_QUEST_PUSH_BUSY_S` (a newcomer outside while we are
  inside; the line names the player, so it is matched to the quest shared in the last 1.5 s) is tried again every
  15 s, at most 20 times. What was shared, whether we asked or heard an ask are kept in `charDb.questShare` for the
  group's dungeon, so a /reload does not share or ask again; it is cleared on leaving the group. Only a real change
  starts a round (the tracked dungeon or the party's names, not every `GROUP_ROSTER_UPDATE`).
- **Replacement:** `wow/run.lua` counts bosses killed (`ENCOUNTER_END`). A dungeon's boss count comes from WoW's
  Adventure Guide when it lists the dungeon, else from finished runs (the most ever killed in one run). When someone leaves the full group before every known boss is down, the leader gets a popup to
  queue the group for a replacement (Forever Groups and the Group Finder, the leaver excluded); with
  `db.autoReplace` that happens without the popup. Only the popup's click searches the Group Finder; without it the
  filler starts from the current results and `wow/keysearch.lua` refreshes them on the next key press. While the
  followed run goes on (`GroupView.isActive`) the window shows no setup (roles, party, dungeons); for the leader with
  an open place its main button is "Find replacement" (`Run.findReplacement`, the same as the popup's). Its click
searches after the filler started, so the one search covers the run's dungeon.
  While the run of that dungeon has a boss down and goes on, every invite whisper for it (the filler's, the answer
  to a whisperer, the queue group's) is the `replaceInvite` message (`Messages.inviteText`,
  `Run.replacementProgress`: "1/6 bosses down, group is inside" in English, the group part while the player is
  inside).
  Its open places are cards like the class choices' (`placeRows(..., choosing)` maps each to a free
  `Compose.SLOT_ROLES` place, `row.wishSlot`), built by the same `W.newClassCard` (WoW's dropdown menu, our own list without it): a pick
  switches the class choices on (cleared first when they were off) and sets that place's classes (`PartyCompose.setClasses`), which the replacement search then uses; while it searches
  they are locked.
  Next to that button, while the followed run goes on and nothing searches, "End run" (`Run.endFollowing`):
  `GroupView.forget()`, the replacement popup closed, and `run.ended` so a later leaver of that run is not asked
  about (logged); the boss count goes on.
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
- **Where everyone is:** members send `v1|GP|<dungeon>|<in|far|yards>` on PARTY (`wow/groupplaces.lua`), so the places
  show "inside" or the distance to the entrance even when the player is already inside.
- **Secret values:** during boss fights Midnight makes chat event arguments secret (strings that error on any string
  operation). `wow/events.lua` replaces them with nil before any handler sees them (`ns.isSecret`).

### Test tools

- Tests put fake players in a queue with `Engine:addFake(members, dungeons, spec)`. They are never sent to the
  channel, never become matchmaker, never expire, and are only grouped with you; they accept 1-3 s after a
  proposal. `Engine:setFakeBehavior("decline" | "afk")` makes the first fake in the next proposal decline / stay
  silent; `Engine:clearFakes()` removes them. Who is looking and the popup tag them "fake".
- `/fg queuelist` lists the queue in chat with tags (you, in a proposal).
- `/fg debug` logs every sent/received message and, when it changes, why the matchmaker did or did not form a group.

### Demo

`/fg demo` (`wow/demo.lua`) walks through every screen with fixed example data, for screenshots: choosing alone with
Who is looking open, leading a party with class wishes and a level limit, waiting in the queue, the group-found
popup, in the group (places, distances, dungeon quests, status bar), the Quests tab, a questing group with its
progress, and the Battlegrounds tab. A bar (`FULLSCREEN_DIALOG`) sits on top of the main window, or of the
group popup while the window steps aside, at the window's scale; under it when the window is too close to the top of
the screen, and at the top of the screen when neither shows. It carries an "Example" tag, the screen's number and
title, "Step n of m" and the step's explanation (wrapped; the bar grows with it). It opens with a welcome ("Show me
around" / "Skip", every window darkened). Each screen has `STEPS`: a text and a `target()` that returns the first
and last frame of the part it explains; steps whose part is not on screen are left out. The part gets a pulsing gold
outline and the main window, Who is looking and the popup are darkened around it (four bands per window, placed
from screen-pixel edges). Next/Previous go through the steps, then to the next screen or back to the last step of
the one before; back from the first step is the welcome, Done on the last ends it. Bar and darkening follow the
window five times a second. `/fg demo` again or Settings → Display → "Show the demo" end or start it too. The player
is always "Aldric Dawnmere", a level 20 Protection Paladin; the others have made-up names.

- **A new player's introduction** (it replaced the old tour of the window): `ns.db.tourSeen` is false on a fresh
  install (no saved variables at all) and true for players who used Forever Groups before. While false, the window
  opens by itself 5 s into the first login (after a fight, `PLAYER_REGEN_ENABLED`; `db.welcomed`; `Demo.welcome`),
  and every opening (`Window.show`/`toggle`) and the moment the channel connects (`onReady`) try `Demo.maybeStart`,
  which starts it with `auto` 0.3 s later: when it can't start yet (not idle, not connected) it says nothing and the
  next opening tries again. Starting sets `tourSeen` on the real settings before `ns.db` becomes the copy, so a crash
  or `/reload` during it can't bring it back.

- **Only when idle:** connected, not in any queue, no proposal, not filling, asking or finding a battleground, solo,
  not in an instance and not in combat (`isIdle`); otherwise a chat line says so.
- **Nothing runs while it shows:** `wow/events.lua` hands no event to the handlers (`Demo.passes`) except
  `CHAT_MSG_CHANNEL_NOTICE`; combat (`PLAYER_REGEN_DISABLED`), a loading screen (`PLAYER_ENTERING_WORLD`),
  logging out or reloading (`PLAYER_LOGOUT`) and joining a group end the demo first and then go through. The
  one-second tick (`wow/main.lua`) only refreshes the window and the status bar. As a safety net `Comm.send`,
  `Comm.sendNow`, `Comm.sendParty`, `Whispers.send`, `Whispers.sayParty`, `Invites.send`, `Input.run`,
  `QuestShare.shareMine`, `TakeLead.ask`, the Group Finder searches and `LfgList.syncRoles`, Find group, fill and
  the right-click menu of Who is looking do nothing.
- **The screens read demo data:** `ns.selfName`, `ns.charDb` (a fresh table per screen), `ns.db` (a copy of the
  saved settings; the log and errors stay the real ones) and the three engines (real `Engine`s that send nothing)
  are swapped, and the model functions the screens ask (`Party.state/members/inGroup/playerClass/playerLevel`,
  `Spec.current/treeOf/indexOf`, `GroupView.members`, `QuestGroup.current/rows`, `Quests.groupQuests`,
  `QuestShare.summary`, `GroupPlaces.of`, the `LfgList` listings and their search state, ...) are replaced and put
  back when it ends. WoW's own functions are never replaced (that taints Blizzard's code): the window asks
  `Party.playerLevel()`, `Party.inGroup()` and `Party.playerClass()` instead of `UnitLevel("player")`,
  `IsInGroup()` and `UnitClass("player")`. `GroupView.swapContext` puts the demo group in place without saving it.
  The saved variables are never written while it runs.
- **Ending:** `Demo.stop` is safe to call twice and runs every step even if one fails; a screen that fails ends the
  demo with a chat line. It puts everything back, shows or hides the window and Who is looking as they were, and
  asks the channel for everyone's queue entries again (`Comm.resync`, a sync request like a newcomer's), since the
  messages that came in meanwhile were not read.

## Releasing

Releases go to CurseForge, Wago and WoWInterface through the BigWigs packager
(`.github/workflows/release.yml`, `.pkgmeta`):

1. Set the new version in `ForeverGroups.toc` (`## Version: 1.2.3`) and commit.
2. Tag it with the same version and a `v` in front, annotated, and push the tag:
   `git tag -a v1.2.3 -m "v1.2.3" && git push origin v1.2.3`.
3. The workflow runs luacheck and busted, checks that the tag matches the .toc
   version, then builds `ForeverGroups/` and uploads it to every site whose id is
   in the .toc (`X-Curse-Project-ID`, `X-Wago-ID`, `X-WoWI-ID`).
4. The project pages' description is not uploaded: when features changed, update
   `OVERVIEW.md` and paste it as the Overview on CurseForge (and the
   description on Wago and WoWInterface) by hand.

The repository needs the secrets `CF_API_KEY`, `WAGO_API_TOKEN` and
`WOWI_API_TOKEN` (Settings → Secrets and variables → Actions), and workflow
permissions set to "Read and write". `python3 scripts/package.py` still builds
the same zip locally in `dist/`.
