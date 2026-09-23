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

    # ── 2) tracked evidence files that are empty on disk ──────────────────
    tracked = [p for p in sh(["git", "ls-files", EVID]).splitlines() if p.strip()]
    empties = []
    for p in tracked:
        if p in ALLOW_EMPTY or not os.path.isfile(p):
            continue
        try:
            if os.path.getsize(p) == 0:
                empties.append(p)
        except OSError:
            pass
    if empties:
        problems.append(
            "%d tracked evidence file(s) are EMPTY on disk:\n%s\n"
            "      Empty evidence is worse than none: it looks like a passing file."
            % (len(empties), "\n".join("        " + e for e in empties[:10])))

    # ── 3) staged evidence that contains FAIL lines ───────────────────────
    staged = [p for p in sh(["git", "diff", "--cached", "--name-only",
                             "--", EVID]).splitlines() if p.strip()]
    dirty = []
    for p in staged:
        if not os.path.isfile(p):
            continue
        try:
            txt = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "FAIL:" in txt or "GREEN(LEAK" in txt:
            dirty.append(p)
    if dirty:
        problems.append(
            "%d STAGED evidence file(s) contain FAIL/LEAK lines:\n%s\n"
            "      That is a mutant run's output, not acceptance evidence."
            % (len(dirty), "\n".join("        " + d for d in dirty[:10])))

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
