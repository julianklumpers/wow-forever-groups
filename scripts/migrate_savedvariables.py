#!/usr/bin/env python3
"""Copies the settings of DungeonQueue (the addon's old name) to Forever Groups, for every account and character
under a WoW WTF folder: SavedVariables/DungeonQueue.lua becomes SavedVariables/ForeverGroups.lua with the tables
renamed. Existing ForeverGroups.lua files are left alone unless --force is given. Run it with WoW closed, or WoW
overwrites the files on exit.

Usage: migrate_savedvariables.py <path to WTF> [--force]"""
import os
import sys


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    wtf, force = sys.argv[1], "--force" in sys.argv[2:]
    for folder, _, files in os.walk(wtf):
        if os.path.basename(folder) != "SavedVariables" or "DungeonQueue.lua" not in files:
            continue
        target = os.path.join(folder, "ForeverGroups.lua")
        if os.path.exists(target) and not force:
            print("kept   " + target)
            continue
        with open(os.path.join(folder, "DungeonQueue.lua"), encoding="utf-8") as source:
            text = source.read()
        text = text.replace("DungeonQueueCharDB", "ForeverGroupsCharDB").replace("DungeonQueueDB", "ForeverGroupsDB")
        with open(target, "w", encoding="utf-8") as out:
            out.write(text)
        print("wrote  " + target)


if __name__ == "__main__":
    main()
