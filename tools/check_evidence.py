#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_evidence.py -- refuse to commit EMPTY or CONTAMINATED evidence.

WHY THIS EXISTS (both failure modes were hit on 2026-09-22):

  1. EMPTY evidence.
     `sim/evidence/*.log|csv` are tracked and are the ACCEPTANCE evidence.
     Running `bringup/mutation_test.ps1` (or `sim/tb_all.ps1`) REWRITES them --
     and while a mutant is applied, several of them legitimately come out
     0 bytes.  Committing during that window stores EMPTY evidence that looks
     like a passing file.

  2. CONTAMINATED evidence.
     The same scripts write logs full of `FAIL:` lines while a mutant is active.
     A commit taken mid-run then contains FAIL lines as if they were acceptance
     results.  mutation_test.ps1 documents this (see its contamination NOTE) and
     its LAST step re-runs tb_all from clean RTL precisely to undo it.

So: if `build/mutation/.lock` exists, a mutation run is in flight -> refuse.

Usage:
    python tools/check_evidence.py            # check staged/HEAD-tracked files
    python tools/check_evidence.py --quiet    # only the exit code matters

Exit: 0 = ok to commit; 1 = do NOT commit evidence right now.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

LOCK = os.path.join("build", "mutation", ".lock")
EVID = "sim/evidence/"
# files that are legitimately small/empty at rest (headers-only, placeholders)
#
# ⭐ K-117 (2026-09-23): `*.compile.log` files that are EMPTY are NORMAL and
#    CORRECT -- they mean "iverilog compiled this bench and printed nothing",
#    i.e. a CLEAN compile.  This was measured, not assumed:
#       40 *.compile.log files -> 38 empty, 2 non-empty
#       and BOTH non-empty ones contain WARNINGS (dangling port / width mismatch),
#       not successes.
#    So the old blanket "any 0-byte file is bad" rule fired on the healthy case
#    and made the guard refuse EVERY commit (34 false positives at the time).
#    The correct rule is the inverse: for compile logs, empty == clean.
#
#    ⚠️ Deliberately NOT added to ALLOW_EMPTY: ALLOW_EMPTY skips the emptiness
#    check entirely, which would also hide a compile log that SHOULD have
#    content.  Instead the exemption is scoped by suffix below, so a non-empty
#    compile log is still checked for FAIL/error contamination further down.
EMPTY_OK_SUFFIXES = (".compile.log",)
ALLOW_EMPTY = set()


def sh(args):
    r = subprocess.run(args, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return r.stdout or ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    problems = []

    # ── 1) a mutation run is in flight -> evidence is being rewritten ──────
    if os.path.exists(LOCK):
        problems.append(
            "build/mutation/.lock exists -- a mutation run is IN FLIGHT.\n"
            "      sim/evidence/** is being rewritten right now; committing it\n"
            "      would store mid-run (possibly EMPTY or FAIL-filled) logs.\n"
            "      Wait for mutation_test.ps1 to finish (its last step re-runs\n"
            "      tb_all from clean RTL), then commit.")

    # Inspect the index: working files may already belong to the next run.
    tracked = []
    try:
        def git(*args):
            return subprocess.run(["git", *args], capture_output=True,
                                  check=True).stdout

        tracked = [p for p in git("ls-files", "-z", "--", EVID)
                   .decode("utf-8", "surrogateescape").split("\0") if p]
        staged = {p for p in git("diff", "--cached", "--name-only",
                                "--diff-filter=ACMRT", "-z", "--", EVID)
                  .decode("utf-8", "surrogateescape").split("\0") if p}
        empties, dirty = [], []
        for p in tracked:
            data = git("show", ":" + p)
            if not data and p not in ALLOW_EMPTY and not p.endswith(EMPTY_OK_SUFFIXES):
                empties.append(p)
            if p in staged:
                encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
                txt = data.decode(encoding, errors="replace")
                if "FAIL:" in txt or "GREEN(LEAK" in txt:
                    dirty.append(p)
        if empties:
            problems.append("%d indexed evidence file(s) are EMPTY:\n%s" %
                            (len(empties), "\n".join("        " + p for p in empties[:10])))
        if dirty:
            problems.append("%d STAGED evidence file(s) contain FAIL/LEAK lines:\n%s" %
                            (len(dirty), "\n".join("        " + p for p in dirty[:10])))
    except (OSError, subprocess.CalledProcessError) as exc:
        problems.append("Cannot read evidence from Git index: " + str(exc))

    if problems:
        print("REFUSING to commit evidence:")
        for i, p in enumerate(problems, 1):
            print("  %d) %s" % (i, p))
        print()
        print("  (see tools/check_evidence.py header for why this check exists)")
        return 1

    if not a.quiet:
        print("OK: evidence looks clean (%d tracked file(s), none empty, none staged with FAIL)"
              % len(tracked))
    return 0


if __name__ == "__main__":
    sys.exit(main())
