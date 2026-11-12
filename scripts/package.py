#!/usr/bin/env python3
"""Builds dist/ForeverGroups-<version>.zip: the files the .toc loads, the .toc and the README, in a Forever Groups
folder, ready to unzip into Interface/AddOns. Tests, tools and the probe addon stay out."""
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOC = os.path.join(ROOT, "ForeverGroups.toc")


def main():
    files, version = ["ForeverGroups.toc", "README.md", "LICENSE", "media/icon.tga"], None
    with open(TOC, encoding="utf-8") as toc:
        for line in toc:
            line = line.strip()
            match = re.match(r"^## Version:\s*(\S+)", line)
            if match:
                version = match.group(1)
            elif line and not line.startswith("#"):
                files.append(line.replace("\\", "/"))
    missing = [f for f in files if not os.path.isfile(os.path.join(ROOT, f))]
    if missing:
        sys.exit("missing files: " + ", ".join(missing))
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    target = os.path.join(ROOT, "dist", "ForeverGroups-%s.zip" % version)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in files:
            archive.write(os.path.join(ROOT, name), "ForeverGroups/" + name)
    print("%s (%d files)" % (target, len(files)))


if __name__ == "__main__":
    main()
