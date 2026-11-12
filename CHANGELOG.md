# Changelog

## 0.25.0 (2026-11-12)

- Playstyle is no longer required: "Any" is the new default and groups you with everyone, so
  more players fit together. The playstyle moved from its own section to a dropdown on the
  "Your roles" header; pick one there (or `/fg style relaxed`, `/fg style any`) to be grouped
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
  Hidden while "I'd like to lead" is on, since you then build your own group.
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
