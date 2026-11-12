# Changelog

## 0.23.2 (2026-11-12)

- Fake players for testing (`/fg fake`) get made-up names instead of "Fake 1", "Fake 2"…
- Fake players only queue for the dungeons of your level.
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
