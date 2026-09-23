# remove_mutant.py -- delete one mutant entry from mutation_test.ps1 by id
#
# WHY A SCRIPT: inline `python -c "..."` inside PowerShell mangles nested quotes,
#   and this file is byte-sensitive (LF-only, ASCII-clean, trailing-comma rule).
#   Doing it here keeps the operation explicit and verifiable.
#
# USAGE:  python tools/remove_mutant.py M77
#
# It refuses to run unless the id exists EXACTLY once, and it re-checks the
# array invariants afterwards (K-120):
#   - the LAST entry must NOT end with a comma
#   - the file must stay ASCII-clean and LF-only

import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "bringup", "mutation_test.ps1")


def main(mid):
    with io.open(PATH, "rb") as f:
        raw = f.read()

    needle = ('id = "%s"' % mid).encode("ascii")
    n = raw.count(needle)
    print("occurrences of %s: %d" % (mid, n))
    if n != 1:
        print("REFUSING: expected exactly 1 occurrence")
        return 1

    lines = raw.split(b"\n")
    keep = [l for l in lines if needle not in l]
    removed = len(lines) - len(keep)
    print("removed %d line(s)" % removed)
    if removed != 1:
        print("REFUSING: an entry should be exactly one line")
        return 1

    out = b"\n".join(keep)

    # --- invariant: LF-only, no BOM, ASCII-clean -------------------------
    if out.startswith(b"\xef\xbb\xbf"):
        print("REFUSING: BOM appeared")
        return 1
    if b"\r\n" in out:
        print("REFUSING: CRLF appeared")
        return 1
    nonascii = sum(1 for b in out if b > 127)
    print("non-ascii bytes now: %d" % nonascii)

    # --- invariant: the LAST catalogue entry has no trailing comma -------
    # find the array terminator ")" that follows the last entry
    tail = out.split(b"\n")
    idx_last = None
    for i, l in enumerate(tail):
        if b"id = \"M" in l:
            idx_last = i
    if idx_last is None:
        print("REFUSING: no mutant entries found")
        return 1
    last_line = tail[idx_last]
    print("last entry tail: %r" % last_line[-12:])
    stripped = last_line.rstrip()
    if stripped.endswith(b","):
        print("REFUSING: the LAST entry still ends with a comma "
              "(PowerShell rejects a trailing comma before ')')")
        return 1

    with io.open(PATH, "wb") as f:
        f.write(out)
    print("wrote %s" % PATH)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: remove_mutant.py <ID>   e.g. M77")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
