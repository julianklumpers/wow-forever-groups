"""Mutation check: replace `old` by `new` in a file, run busted, put the file back.

Usage (from the repo root):
    python3 tools/mutate.py <file> '<old text>' '<new text>' [spec files...]

Prints KILLED (a test failed: the code is covered) or SURVIVED (no test noticed:
add one). The old text must occur exactly once. The file is put back also when
the run is stopped (Ctrl+C, a kill); after a hard kill the next run puts it back
from the copy kept next to it (<file>.mutate-backup).
"""
import os
import signal
import subprocess
import sys


def restore_left_over(path):
    backup = path + ".mutate-backup"
    if os.path.exists(backup):
        os.replace(backup, path)
        print("RESTORED %s from a run that was killed" % path)


def stop(signum, _frame):
    raise KeyboardInterrupt("signal %d" % signum)


if len(sys.argv) < 4:
    print(__doc__)
    sys.exit(2)
path, old, new = sys.argv[1], sys.argv[2].encode("utf-8"), sys.argv[3].encode("utf-8")
specs = sys.argv[4:]
restore_left_over(path)
source = open(path, "rb").read()
if source.count(old) != 1:
    print("NOMATCH: the old text occurs %d times" % source.count(old))
    sys.exit(1)
for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(sig, stop)
backup = path + ".mutate-backup"
open(backup, "wb").write(source)
try:
    open(path, "wb").write(source.replace(old, new))
    run = subprocess.run(["perl", "-e", "alarm 400; exec @ARGV", ".lua51/bin/busted"] + specs,
                         stdin=subprocess.DEVNULL, capture_output=True, text=True)
    lines = (run.stdout + run.stderr).strip().splitlines()
    summary = [line for line in lines if "successes" in line]
    print(("KILLED " if run.returncode != 0 else "SURVIVED ") + (summary[-1] if summary else (lines or [""])[-1]))
except KeyboardInterrupt:
    print("STOPPED: %s is put back" % path)
    sys.exit(130)
finally:
    open(path, "wb").write(source)
    os.remove(backup)
