# Changelog

## 0.26.0 (2026-11-14)

- Forever Groups speaks German, Spanish and Russian: the window, tooltips, settings and the chat
  lines for you follow your WoW client's language (English otherwise). Dungeon and battleground
  names come from the client in your language. Whispers and party messages stay English, as the
  player reading them may speak any language. Settings → Display → Language picks one yourself
  (Automatic follows WoW); it shows everywhere after a /reload, which it offers.
- A new logo: the party with the crowned leader in gold on leather, in a ring with stars and
  a ribbon reading "Forever Groups". The icon in game (title bar, status bar, addon list) is
  the same party on a round gold-rimmed coin.
- The role you chose wins over your spec: queued only as healer with a Feral (tank) spec, you
  became the tank a few seconds after the group formed (Deadly Boss Mods sets the role from the
  spec), and Forever Groups went along and looked for another healer. Now Deadly Boss Mods'
  role check is skipped while Forever Groups holds your role, and any other change is set back
  at once; only with several roles ticked may it pick between them. This holds after a /reload
  too.
- Filling a group from the Group Finder no longer stalls on "Your party is full": WoW keeps an
  unanswered invite open for a minute and it takes a place in the party, so the filler waits for
  that place instead of inviting players WoW refuses. The group card shows it: an open place
  holds the player invited for it with the time left ("invited 0:18"), or, once given up on, when
  WoW frees the place ("frees in 0:24"). It also whispers first and invites
  a moment later, so a player who is away (AFK, DND) is passed over instead of invited.
- WoW's Group Finder gives at most 100 results per search, and five dungeons together already
  reached that, so groups for the dungeons you ticked could be missing. Now the dungeons you
  ticked (or queued for) are searched on their own, and the other dungeons of your level just
  after, for the numbers in the window (the very first search covers them all at once, so the
  numbers show right away). WoW allows about two searches per five seconds: Forever Groups keeps
  to that, so its searches are no longer refused, and one that has to wait (or that WoW refused
  anyway) goes out on your next key press or click a few seconds later instead of at the next
  refresh. A player listed for several dungeons counts once. Besides key presses and clicks in
  the world, zooming the camera, using an action button and moving the mouse onto the window
  now refresh the results too. Looking alone with one role, the search asks WoW only
  for groups with a place for that role.
- Ticking roles also sets your roles in WoW's Group Finder.
- On a trial account a message at login says that other Forever Groups players can't see you
  in the queue (WoW doesn't let trial accounts send addon messages); the Group Finder still
  works.
- An ask to a group's leader offers one role, no longer "Healer/DPS": the scarcest the group
  still needs of your roles (tank, then healer, then DPS; when the open places are not known,
  healer, then DPS, then tank), and you join with that role. A leader's "what spec?" gets the
  same role back. The leader's invite whispers name the spec of the role they play.
- Whispers name the spec that fits the role you look for: a Feral druid looking only as healer
  asks as "Restoration Druid (Healer)", no longer as "Feral Druid (Healer)".
- The group card shows every member in their own role: two tanks no longer show one of them as
  the healer.
- The "Filling from the Group Finder" window is gone: filling simply happens (`/fg debug on`
  shows it).
- A Battlegrounds tab next to Dungeons and Quests: the battlegrounds for your level bracket
  (Warsong Gulch from 10, Arathi Basin from 20, Darkspear Islands from 30) with who is looking
  for them: Forever Groups players, and in WoW's Group Finder (only Warsong Gulch is listed
  there) solo players by role and the groups that still have room. Who is looking shows them
  too. Find group there puts you in a new Forever Groups battleground queue, where players
  with the addon form a party (two are enough), and at the same time asks a listed group's
  leader to invite you (and joins); after a minute without either it builds your own group
  from listed players: a party of five or a premade of ten,
  which becomes a raid past five. A premade gets at least two healers (a party one; you count
  when you ticked Healer): those places stay open until healers are found, and the card says
  how many it still looks for. Leaving that group stops it. Then sign it up at a battlemaster;
  the card shows the battleground queue (signed up, wait, ready to enter). A party formed in
  the Forever Groups queue fills on from the Group Finder the same way, and while other Forever
  Groups players wait for the same battleground, places stay open for them. You can wait for a
  dungeon, a quest and a battleground at once: once one forms a group, the others are left,
  also when Find group builds your battleground group from the Group Finder. While it looks,
  the roles and battlegrounds it looks with can't be changed (Stop first).
- Finding a group now simply happens: no more chat lines about asking leaders, inviting players
  from the Group Finder or building your own group, and no "Asking groups to invite you (1
  asked) · own group in 0:24" in the status. You see "In queue" / "Looking for a group", then
  "Group forming" and your group; when you join a group a leader you asked, one line says so:
  "Group found for Ragefire Chasm: you're the Tank."
- The answers of a leader Forever Groups asked for you stay out of your chat too, and when such a
  leader asks back for your level, class or spec ("lvl?", "what spec?"), Forever Groups answers
  for you, unseen (Settings → Messages: "Answer to an asked leader's question"). Whispers from
  anyone else always show.
- A leader's answer is understood in Russian, German, French, Spanish and Portuguese too ("нет",
  "voll", "complet", "да", "ja", "oui", "лвл?", "quel niveau ?"...). Once you're in the leader's
  group, their whispers show again. What a leader answered is in the saved log.
- A Forever Groups tab on WoW's own Group Finder, under its side tabs (and under LFGForever's,
  if you have that): it opens the Forever Groups window.
- `/fg debug on` shows all of it again in chat and in the status (`/fg debug off` hides it);
  everything is always in the saved log for `/fg bugreport`.
- In a group whose leader has no Forever Groups and that still has open places, a "Make me
  leader" button whispers the leader to promote you; once you lead, Forever Groups fills the
  group for you.
- When someone leaves your group, you still get the "Find replacement" popup; new setting
  (Settings → Groups → In the group): "Find a replacement by itself when someone leaves". While
  the run goes on, the window shows the group card with a "Find replacement" button for the open
  place (also after "No" in the popup), no longer the roles, party and dungeon list of a new
  search.
- Back within 15 minutes after a disconnect, you're in the queue again (at the end; within 2
  minutes you keep your place, as before).
- Each dungeon in the list says how much your role is wanted right now: "Tank needed" when
  fewer other tanks are looking than a group needs, next to the groups that need you
  ("3 groups · Healer needed"), or "quiet" when nobody looks; also for the dungeons you didn't
  tick, so you can see where you're wanted. The window is a little wider for it.
- The role tile of the role needed most right now (of those your class can play) says
  "Needed most".
- The group card shows every member with their spec's art (or their class's emblem while the
  spec is not known) and class and spec on one line ("Druid Feral"). A spec that does not play
  the member's role gives way to the one that does: a Feral druid healing shows as Restoration,
  on the card and in the group popup. While the popup asks for your answer the main window
  steps aside, and comes back afterwards if it was open.
- The role tiles show your class: the art of the spec you play each role with (a druid's tank
  tile shows the bear, a priest's healer tile Holy or Discipline), with the role and the spec's
  name at the bottom.
- Playstyle and "I'd like to lead" moved to the line under the role tiles, in place of the tips
  that were there ("Can you play another role too?", "You will most likely play ...").
- The "Your roles" heading is gone: the role tiles come first, right under the tabs.
- The chosen tab (Dungeons or Quests) shows the art of WoW's own Group Finder, and its picture
  runs on into the page below it and fades out. The tab runs into the gold line with rounded
  corners, and that line now is the top edge of the page.

## 0.25.2 (2026-11-13)

- Fixes from a code review: an asked group whose listing can't be read for a moment no longer
  counts as gone (so two leaders aren't asked at once); when the only group's leader says no
  (or it fills up or leaves), your own group is built right away instead of after a minute;
  answers like "no probs", "not full yet" or "we have no tank" are no longer read as a no;
  a leader's answer is matched also when WoW adds the realm to the name, and never taken for
  someone asking to join your group; a questing invite is no longer accepted once Forever
  Groups started inviting players itself; a leader is only kept from being asked again when
  the question was really sent; hiding the whole UI (Alt+Z) no longer closes "Who is looking"
  for good; and the window no longer redraws "Who is looking" twice per update.
- The group card shows the dungeon's picture behind its title, like the group-found popup:
  shaded behind the text and fading into the card, across the window's whole inner panel, with
  the members under it. The member places have rounded corners. Without tabs, the inner panel
  starts right under the title bar.
- No "Connecting..." screen in the window any more: while Forever Groups connects, it shows
  your group or your choices as usual, and in a party no tabs that would disappear a moment
  later. You still see it's connecting: the Find group button reads "Connecting..." until it
  can be pressed, and the dot in the title bar pulses.
- More room between the main window's section headers and their line, so the playstyle box
  and "I'd like to lead" no longer touch it; every header the same.
- The connection moved to the window's title bar: a small dot left of the close button (hover
  for details), with its word only while it isn't simply connected (connecting, a problem, an
  update out). The strip it had above the card is gone when there are no tabs.

## 0.25.1 (2026-11-13)

- The whispers Forever Groups sends for you (asking a leader, before an invite, answers to "heal?")
  no longer show as "To ..." lines in your own chat; the other player still gets them. Answers
  that come back always show. Settings → Messages: "Hide the whispers Forever Groups sends for me".
- Ticking a dungeon that wasn't searched yet searches WoW's Group Finder right away, so "Who is
  looking" and the counts show its players and groups at once; unticking one updates the list
  without a new search. New results show the moment they arrive.
- Main window: while you choose alone, "Your roles" now comes first, with "Looking now" under
  it; the "Not in the queue" / "Not looking for a questing group" line is gone. On both tabs.
- "Who is looking" is now a drawer on the side of the main window instead of a separate window
  behind a small link: it's open by default and follows what you pick in the main window. A tab
  with the Group Finder eye on the window's edge opens and closes it, and it stays the way you
  left it. The "Who is looking »" link is gone; `/fg queue` still opens it.
- Asking groups in WoW's Group Finder to invite you now asks one leader at a time, and the
  next only after 20 seconds without an invite (it used to whisper three leaders within a few
  seconds). Two invites can no longer arrive at once, leaving one leader waiting for nothing.
  The same for group quests.
- It doesn't wait the full 20 seconds when it's clear nothing will come: the next leader is
  asked at once when the group leaves the Group Finder or has no place for your role any more,
  or when the leader whispers a clear no ("sorry, full", "nope"). A leader who whispers yes
  ("sure, sec") gets up to 30 seconds more for the invite, even past the moment Forever Groups
  would start building your own group. Their whisper still shows in your chat as usual.
- When a leader you asked invites you, you join right away instead of having to click the
  invite in time (also after "Request to join" in "Who is looking"). Settings → Joining: "Join
  a group I asked to invite me by itself". Invites from leaders you didn't ask are never
  accepted for you. WoW's role window for that invite is closed for you and your role is set:
  DPS when the group still has a DPS place, else tank, else healer (of the roles you ticked).
- Recently listed groups are asked first; a listing that has been up for half an hour or more
  and still isn't full (often an away leader) comes last.
- A leader who was asked isn't asked again for 15 minutes, also when you queue again or reload.

## 0.25.0 (2026-11-12)

- Fixes: "Request to join" on a questing group in "Who is looking" no longer causes an error
  (it now asks for a quest of yours in that zone). Quest listings are no longer filtered by your
  dungeon playstyle. Questing parties no longer show dungeon roles under Needs. An open "Who is
  looking" switches along when the main window changes page by itself (a group formed, a queue
  left). With "Who is looking" open on the Quests tab, the dungeon queue's Group Finder
  results still refresh. A quest in a zone that wasn't searched shows no counts instead of
  zeros.
- "Who is looking": sorting a table by a column no longer sorts the other tables too; each
  table keeps its own order until you close the game or reload, then it's back to the default.
  A small arrow next to the column a table is sorted by shows the direction (up: A to Z, tank
  first; down: highest level or longest waiting first), instead of the "reversed order" note.
- Playstyle is no longer required: "Any" is the new default and groups you with everyone, so
  more players fit together. The playstyle moved from its own section to a dropdown on the
  "Your roles" header, with WoW's own dropdown button and menu; pick one there (or `/fg style relaxed`, `/fg style any`) to be grouped
  with like-minded players only. A playstyle you picked before is kept. Your own WoW Group
  Finder listing still says Relaxed when you have no preference, since WoW requires one.
- "I'd like to lead" on the roles header: when a group forms with you, you become its leader (a
  party that queues together keeps its own leader). Forever Groups then doesn't ask listed
  groups to invite you; it builds the group for you, with you as leader. The button then reads
  "Find players" ("Find questing players" on the Quests tab). It's set separately for
  dungeons and for group quests.
- "Who is looking" tables fold to one line with a summary ("Groups (18) · 12 need DPS"). By
  default the groups are open and the players folded; with "I'd like to lead" on it's the other
  way round, right away when you tick it. Fold or open one yourself and it stays that way until
  you change "I'd like to lead".
- Group quests get the same overview as dungeons: on the Quests tab, "Looking now", per quest
  who is looking in its zone and the groups there that need you, and "Who is looking »" lists
  the questing queue plus the players and groups listed in WoW's Group Finder (Quests & Zones)
  in those zones and in every zone suggested for your level, also without group quests of your
  own. An open "Who is looking" switches along when you switch tabs.
- "Who is looking" shows a Group Finder listing's note in its tooltip (often which quest a
  group is for), for groups and for solo players who wrote one.
- Next to each dungeon's counts: how many groups in WoW's Group Finder need one of your roles
  ("5 groups", hover for the leaders), and the total in "Looking now" ("14 groups need you").
  Hidden while "I'd like to lead" is on or "Ask groups in WoW's Group Finder to invite me" is
  off, since Forever Groups then builds your own group; "Who is looking" still lists them.
- "Who is looking" has no tabs any more: one framed block per source, Forever Groups (Parties,
  Players) and WoW Group Finder (Groups, Players), each table with its count (an empty one is a
  single line) and the same columns, including a new "Needs" column: the
  places a party or group still has open. A small number on a needed role says how many (2 DPS
  still needed); the tooltip also says how many are in the group. "+3" after a name means the leader
  plus three. Hover a party or group to see who is in it.
- Filling from WoW's Group Finder no longer holds a role for a Forever Groups player who is
  building a group of their own, or when your own group isn't in the queue (e.g. "Fill from
  Group Finder" for your party); the fill window keeps saying which role it leaves to them.

## 0.24.0 (2026-11-12)

- Fake players for testing (`/fg fake`) get made-up names instead of "Fake 1", "Fake 2"…
- Fake players only queue for the dungeons of your level.
- Fake players get a class and spec that fit their roles (a tank fake is a Protection Warrior or
  Paladin), shown in class colours in the popup and in "Who is looking".
- "Who is looking" shows Forever Groups players in their class colour.
- After a test group with fake players the window no longer shows an empty group card under
  "Not in the queue".
- Fake players are always grouped with you: with many fakes, or fakes added before you joined,
  they used to form groups among themselves and no proposal came.
- Right-click a player in "Who is looking" to whisper or invite them.
- "Who is looking" has a Groups tab: groups in WoW's Group Finder for your dungeons, with the
  roles they still need, their size and how long they're listed. Right-click a group to
  request to join (a whisper to the leader asking for an invite) or to whisper the leader.
  The leader's invite is then recognised, with a sound and a note to accept it.
- "Who is looking" opens docked to the right of the main window, moves with it and closes
  with it.
- "Who is looking" is a table: columns Role, Name, Level, Dungeons and Time, for Forever
  Groups players and the Group Finder list alike. Click a column header to sort, again to
  reverse (replaces the sort buttons). A long dungeon list is shortened ("RFC, HoT, RoL, +32").
- Once everyone accepted the proposal you join the group by yourself: the invite from the
  group's leader is accepted for you (no second click). Invites from anyone else never are.
  Settings → Groups → "Join the group by itself once everyone accepted" turns it off.
- Joining by itself also works when the leader's invite arrives before the last Accept reaches
  you, never accepts an invite from a leader whose group is more than 2 minutes old, and marks
  WoW's invite popup accepted so closing it cannot decline.
- A "Request to join" from Who is looking is kept when you press Stop or `/fg leave`, so the
  leader's invite is still recognised, and it no longer delays building your own group.
- `/fg fake` also queues the fakes for dungeons you picked outside your level.
- Who is looking docks on the right side on small screens too; the sort tooltips on the Groups
  tab name the right column; the fallback right-click menu closes when you click elsewhere.
- Setting a role waits for the server: a player who just joined no longer looks like they
  switched roles, which made the addon invite a second healer from the Group Finder.
- Forever Groups players come first: a role that someone with the addon waiting in the queue can
  play is not filled from WoW's Group Finder (also when a Group Finder player declines); the
  Group Finder only fills the other roles, or that role after all if no group forms within 20 s.
- Players who log in see who is looking for a questing group within seconds (the "waiting" counts
  on the Quests tab), instead of after up to 45 seconds.
- Filling from WoW's Group Finder stalls less: results stay usable for 5 minutes instead of 2,
  and while you play they are refreshed every 30 seconds, so a player who declines is replaced
  at once and new listings are seen.
- A Group Finder player who doesn't answer the invite is replaced after 30 seconds instead of
  60 (70 for questing groups).
- The leader sends all invites at once instead of half a second apart, so the group is together
  right after the last Accept.
- The "Group found!" popup shows the dungeon's loading screen as a banner in the style of
  ForeverDungeonJournal's cards (name on a soft dark top, playstyle, level range and your role
  in the corners, a bronze edge): the classic ones and
  Forever's own (Hall of Thanes, Ruins of Lordaeron, Excavation Site, City of Dalaran, Krol'dok
  Stronghold, Blackmaw Hold, Shaper's Terrace), all from the game itself. The Drowned City and
  Alcaz Prison keep the plain look for now.
- A place the leader fills from WoW's Group Finder shows as its own row in the "Group found!"
  popup ("Open · from the Group Finder"), so it always shows five places.
- The "Group found!" popup lists tank, healer, then DPS, with names in class colours, a crown
  on the leader, your own row lit up, spec (or "fake") under each name and "3/5 accepted" next
  to the timer. After you accept, the buttons make way for "Waiting for the others".
- While you wait in one queue the Dungeons/Quests tabs are hidden; a link "Also find a questing
  group »" (or "dungeon group") opens the other one. Waiting in both shows the tabs again.

## 0.23.1 (2026-11-12)

- Also released on Wago.
- A changelog per version, shown with every release.

## 0.23.0 (2026-11-12)

- The hidden channel is now called ForeverGroupsNet; your character leaves the old
  DungeonQueueNet channel once. Older test versions (DungeonQueue) can no longer group with
  this one.
- Shorter README for players.

## 0.22.0 (2026-11-12)

- WoW's Group Finder list also refreshes when you click in the game world (a target, an NPC,
  the ground), not only on key presses. Still at most every 10 seconds and never in combat.

## 0.21.1 (2026-11-12)

- "I'm the {spec}" is no longer added to the "group found" invite and the questing invite.

## 0.21.0 (2026-11-12)

- Settings in one window with tabs: Groups, Messages, Display.
- `/fg messages` opens the Messages tab.

## 0.20.0 (2026-11-12)

- Every whisper and party message can be rewritten (in any language) or turned off, with
  placeholders like {dungeon}, {role} and {spec} and a live preview.

## 0.19.6 (2026-11-12)

- New logo and icon.

## 0.19.2 (2026-11-12)

- Players who whisper about your listed questing group ("heal?") get an invite while their role
  is open.

## 0.19.1 (2026-11-12)

- Tabs come back once the group left the dungeon or the shared quests are turned in.
- Boss counter: a new group or a boss killed again starts a new run; kills in other instances
  no longer count.
- The dungeon and quest searches no longer invite for both at once.
- "Shared quests done, leave the group?" now also shows when members share other quests.
- "You did not accept in time" instead of "You declined" when a proposal ran out.
- Fixes for boss fights (Group Finder list, party chat).

## 0.19.0 (2026-11-11)

- Renamed to Forever Groups. New commands `/fg` and `/forevergroups` (`/dq` still works).

## 0.18.0 (2026-11-11)

- Status bar icons to share your quests and to fold out the quest progress under the bar
  (replaces the separate progress window).

## 0.17.0 (2026-11-11)

- New status bar: addon icon, full dungeon name and a progress line (bosses or players found).

## 0.16.x (2026-11-11)

- Specs of party members without the addon, read by inspecting them out of combat.
- Bosses shown as "4/7 bosses".
- No more Lua errors during boss fights.

## 0.15.x (2026-11-11)

- The group card stays inside the dungeon, with the status bar.
- See where everyone is: "inside" or the distance to the entrance.
- "no addon" for players without Forever Groups.
- The Dungeons/Quests tabs hide while you're in a group.

## 0.14 and earlier

- First test versions (as DungeonQueue): dungeon and questing queues, playstyles, WoW Group
  Finder support, group card, quest sharing and progress.
