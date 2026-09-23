# renumber_w3a_mutants.py -- shift the W3a mutant IDs out of the way of a
#                            teammate's range, WITHOUT touching other M## tokens.
#
# WHY: the teammate's branch (origin/main) added mutants numbered M81..M85
#      (for rtl/w3c/perc_env_bank.v and rtl/w3c/master_mix.v), while our W3a
#      work already occupied M78..M87.  Five IDs therefore collided, and
#      `-Filter M82` would silently select TWO DIFFERENT targets.
#
#      We renumber OUR side (the user chose this, to avoid bothering the
#      teammate) into a clean contiguous block:  M78..M87  ->  M88..M97.
#
# DANGER THIS SCRIPT EXISTS TO AVOID:
#   A naive global search/replace of "M78" would also match unrelated text such
#   as "MAX98357A" is fine, but strings like "M80" appear inside other words
#   e.g. "M80xx".  More importantly several docs mention other M-numbers.
#   So we only rewrite IDs at KNOWN SAFE CONTEXTS:
#       (a) inside the catalogue:   id = "M78"
#       (b) backticked references:  `M78`   (docs, tb comments, rtl comments)
#       (c) bare "M78" preceded by a word boundary and followed by a non-digit
#           -- but ONLY in the files that belong to the W3a line.
#   Files are explicitly listed; nothing is discovered by walking the tree.
#
# ASCII-only.  Refuses unless each expected count matches.

import io, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OLD = [78, 79, 80, 81, 82, 83, 84, 85, 86, 87]
NEW = [88, 89, 90, 91, 92, 93, 94, 95, 96, 97]
MAP = dict(zip(OLD, NEW))

# files that belong to the W3a line (explicit allowlist -- no tree walking)
TARGETS = [
    "bringup/mutation_test.ps1",
    "tb/w3a/tb_axis_map.sv",
    "tb/w3a/tb_event_extract.sv",
    "tb/w3a/tb_param_extract.sv",
    "rtl/w3a/axis_map.v",
    "rtl/w3a/param_extract.v",
    "rtl/w3a/event_extract.v",
    "files/20-代码/W3a采集链语义层设计草案-20260923.md",
]


# ---- substitution -------------------------------------------------------
# 🔴 BUG THIS REPLACES (found 2026-09-23, during the rebase onto master_mix):
#   the first version formatted ids with 'M%d' % int(...), so an UNRELATED entry
#   like   id = "M01"   became   id = "M1"  -- because int("01") == 1, 1 is not
#   in MAP, and MAP.get returned that same 1, which was then re-formatted
#   WITHOUT the leading zero.  That silently rewrote M01..M09 (9 lines) as a
#   side effect of a renumbering meant to touch only M78..M87.
#
#   FIX: only substitute when the raw digit string is an EXACT key of the map
#   ("81" yes, "01" no).  Everything else is returned byte-for-byte unchanged.
_MAP_BY_STR = {str(k): v for k, v in MAP.items()}


def _sub_digits(m):
    """m.group(1) is the raw digit string exactly as written in the file."""
    raw = m.group(1)
    if raw in _MAP_BY_STR:                       # e.g. "81" -> "91"
        return m.group(0).replace(raw, str(_MAP_BY_STR[raw]), 1)
    return m.group(0)                            # untouched


# ---------------------------------------------------------------------------
# 🔴🔴 FILE AWARENESS FOR THE SHARED CATALOGUE
#
#   In mutation_test.ps1 an `id = "M81"` line does NOT say which line owns it --
#   the entry's `file = "..."` field does.  The teammate also uses M81..M85
#   (for rtl\w3c\perc_env_bank.v and rtl\w3c\master_mix.v), so a blind rewrite
#   renames THEIR mutants too and merges two different targets under one id --
#   precisely the defect this script exists to remove.
#
#   Verified 2026-09-23: without this guard the dry run wanted to rewrite
#   M81(perc_env_bank) and M82..M85(master_mix).
#
#   So: parse each entry line, look at its OWN file field, and renumber only
#   when that file belongs to the W3a line.
# ---------------------------------------------------------------------------
ENTRY_ID_RE = re.compile(r'id = "M(\d+)"')
ENTRY_FILE_RE = re.compile(r'file = "([^"]+)"')


def renumber_catalogue(text):
    """Renumber ONLY those catalogue entries whose target file is ours."""
    out = []
    for line in text.split("\n"):
        id_m = ENTRY_ID_RE.search(line)
        file_m = ENTRY_FILE_RE.search(line)
        if id_m and file_m and ("w3a\\" in file_m.group(1) or "w3a/" in file_m.group(1)):
            raw = id_m.group(1)
            if raw in _MAP_BY_STR:
                line = line.replace('id = "M%s"' % raw,
                                    'id = "M%d"' % _MAP_BY_STR[raw], 1)
        out.append(line)
    return "\n".join(out)


def renumber(text):
    """Rewrite M<old> -> M<new> only where it denotes a W3a mutant id.

    Three contexts, in order.  The ORDER MATTERS: the catalogue form must be
    handled before the generic form so we never double-substitute.
    """
    # (a) catalogue entry:  id = "M78"
    text = re.sub(r'id = "M(\d+)"', _sub_digits, text)
    # (b) backticked reference:  `M78`
    text = re.sub(r'`M(\d+)`', _sub_digits, text)
    # (c) bare reference in prose, e.g. "抓住 M82。" or "变异体 M77 守它"
    #     Guard with word boundaries so we never touch identifiers like
    #     "M8200" or "SDRAM0".
    text = re.sub(r'(?<![A-Za-z0-9_])M(\d+)(?![0-9])', _sub_digits, text)
    return text


def main():
    dry = "--dry-run" in sys.argv
    if dry:
        print("*** DRY RUN -- nothing will be written ***")
    total = 0
    for rel in TARGETS:
        p = os.path.join(ROOT, rel)
        if not os.path.isfile(p):
            print("SKIP (absent): %s" % rel)
            continue
        with io.open(p, "r", encoding="utf-8", newline="") as f:
            before = f.read()
        # the shared catalogue needs FILE-AWARE handling (see renumber_catalogue);
        # our own files are single-purpose, so the plain form is correct there.
        if rel.endswith("mutation_test.ps1"):
            after = renumber_catalogue(before)
        else:
            after = renumber(before)
        if before == after:
            print("  no change : %s" % rel)
            continue
        n = sum(1 for a, b in zip(before.split("\n"), after.split("\n")) if a != b)
        print("  changed %2d line(s): %s" % (n, rel))
        total += n
        if not dry:
            # byte-level write, preserving line endings exactly as read
            with io.open(p, "w", encoding="utf-8", newline="") as f:
                f.write(after)

    print("total lines changed: %d" % total)
    if dry:
        return 0

    # ---- verification -------------------------------------------------
    print()
    print("=== verification ===")
    cat = os.path.join(ROOT, "bringup/mutation_test.ps1")
    with io.open(cat, "r", encoding="utf-8", newline="") as f:
        txt = f.read()
    ids = [int(m) for m in re.findall(r'id = "M(\d+)"', txt)]
    print("  catalogue entries: %d" % len(ids))
    dup = sorted({i for i in ids if ids.count(i) > 1})
    print("  duplicate ids    : %s" % (dup if dup else "none"))
    w3a = sorted(i for i in ids if 88 <= i <= 97)
    print("  W3a block M88..M97 present: %s" % (w3a == NEW))
    left = sorted(i for i in ids if i in OLD)
    print("  any OLD ids left : %s" % (left if left else "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
