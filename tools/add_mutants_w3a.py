# add_mutants_w3a.py -- append the W3a mutation set (M77..M87) to mutation_test.ps1
#
# STATUS: ALREADY APPLIED (2026-09-23).  M77..M87 are in the catalogue.
#   => re-running now exits 1 with "REFUSING: M77 already present".
#   That is INTENTIONAL -- this script is idempotent-by-refusal, never a silent
#   double-insert.  Keep it as the worked example / template for the NEXT module's
#   mutant set, and as the home of the three guards below.
#
# WHY THIS IS A SCRIPT AND NOT HAND-EDITED:
#   The mutants catalogue is a PowerShell array of hashtables, and every entry needs
#   a `find` string that must appear EXACTLY ONCE in the target file.  Hand-editing
#   11 entries with escaped quotes is how you get anchor rot (K-87: a mutant whose
#   anchor no longer matches guards NOTHING, yet the run used to still print PASS).
#   So: build the entries programmatically, then VERIFY each anchor before writing.
#
# THE THREE TRAPS THIS SCRIPT GUARDS AGAINST (K-120 -- all three were hit for real):
#   1. A trailing comma before the array's closing ")" is ILLEGAL in PowerShell.
#      The original file's last entry (M44) deliberately omits it, so the FINAL
#      mutant we emit must omit it too.
#   2. Anchors must be pure ASCII.  Copying an RTL line that carries a Chinese
#      comment into `find` both adds non-ASCII bytes (K-116) and breaks the parse.
#   3. Inserted lines must use the HOST file's line endings.  mutation_test.ps1 is
#      LF-only; joining the block with "\r\n" mixed in CRLF and broke parsing with
#      an error message that pointed at the data, not at the invisible \r.
#   => All three produce "Missing expression after ','" at a line that looks fine,
#      so NEVER trust the reported line number; run Parser::ParseFile afterwards.
#
# ASCII ONLY.  PowerShell 5.1 decodes BOM-less UTF-8 as GBK (K-38/U61).

import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "bringup", "mutation_test.ps1")

# (id, file, find, repl, why)
MUTANTS = [
    # ---- W3a axis_map (M77..M79) -------------------------------------------------
    ("M77", r"rtl\w3a\axis_map.v",
     "wire [KW-1:0] key_sel = (key_idx >= N_KEY) ? KEY_MAX : key_idx[KW-1:0];",
     "wire [KW-1:0] key_sel = key_idx[KW-1:0];",
     "W3a axis_map: the table-top CLAMP is removed -> pos at full scale reads past the table (wrap to bottom / X). Must be caught."),

    ("M78", r"rtl\w3a\axis_map.v",
     "wire [PHASE_W-1:0] inc_delta = inc_hi - inc_lo;",
     "wire [PHASE_W-1:0] inc_delta = {PHASE_W{1'b0}};",
     "W3a axis_map: the interpolation slope is forced to zero -> dual-press interpolation degrades to 'only the lower key' (glissando silently dies). Must be caught."),

    ("M79", r"rtl\w3a\axis_map.v",
     "assign phase_valid_o = pos_valid_i;",
     "assign phase_valid_o = 1'b0;",
     "W3a axis_map: the valid strobe is killed -> phase_inc is produced but never handed over. Must be caught."),

    # ---- W3a event_extract (M80..M83) -------------------------------------------
    ("M80", r"rtl\w3a\event_extract.v",
     "if (refr[scan_axis] == 16'd0) begin",
     "if (1'b1) begin",
     "W3a event_extract: the refractory gate is removed -> a bouncing key emits repeated note_on. Must be caught."),

    ("M81", r"rtl\w3a\event_extract.v",
     "refr  [scan_axis] <= REFRACT_N[15:0];",
     "refr  [scan_axis] <= 16'hFFFF;",
     "W3a event_extract: the refractory counter is set to its MAX -> the key is blocked forever (fires once, never again). Must be caught."),

    ("M82", r"rtl\w3a\event_extract.v",
     "if (pos_i[scan_axis*POS_W +: POS_W] < REL_TH) begin",
     "if (pos_i[scan_axis*POS_W +: POS_W] < TRIG_TH) begin",
     "W3a event_extract: hysteresis removed (release threshold == trigger threshold) -> a bouncing contact emits repeated on/off. Must be caught."),

    ("M83", r"rtl\w3a\event_extract.v",
     "evt_axis_o  <= q_axis [q_rd];",
     "evt_axis_o  <= q_axis [q_rd] ^ 4'h1;",
     "W3a event_extract: the axis field of a dequeued event is corrupted -> note_on arrives but plays the WRONG key. Must be caught."),

    # ---- W3a param_extract (M84..M87) ------------------------------------------
    ("M84", r"rtl\w3a\param_extract.v",
     "vel_value_o <= vel_of(dt_hold[emit_axis]);",
     "vel_value_o <= 8'd255 - vel_of(dt_hold[emit_axis]);",
     "W3a param_extract: the velocity polarity is inverted -> a fast press reads as quiet (the feature is silently backwards). Must be caught."),

    ("M85", r"rtl\w3a\param_extract.v",
     "dt_hold[scan_axis] <= frame_cnt - t1_stamp[scan_axis];",
     "dt_hold[scan_axis] <= frame_cnt;",
     "W3a param_extract: dt drops the t1 timestamp term -> the measured interval no longer reflects how fast the key was pressed (velocity becomes meaningless). Must be caught."),

    ("M86", r"rtl\w3a\param_extract.v",
     "dt_hold[scan_axis] <= 16'd0;",
     "dt_hold[scan_axis] <= 16'hFFFF;",
     "W3a param_extract: the underflow guard wraps to MAX instead of clamping to 0 -> a t2-before-t1 ordering turns the LOUDEST hit into the QUIETEST. Must be caught."),

    ("M87", r"rtl\w3a\param_extract.v",
     "if (!was_above_t2[scan_axis] && t1_seen[scan_axis]) begin",
     "if (1'b1) begin",
     "W3a param_extract: the edge/hold gate on the deep threshold is removed -> dt is recomputed every frame (velocity floods and jitters). Must be caught."),
]


def main():
    with io.open(SCRIPT, "r", encoding="utf-8", newline="") as f:
        txt = f.read()

    # --- 1) verify every anchor appears exactly once -------------------------
    bad = []
    for mid, fname, find, repl, why in MUTANTS:
        path = os.path.join(ROOT, fname)
        if not os.path.isfile(path):
            bad.append((mid, "FILE MISSING", fname))
            continue
        with io.open(path, "r", encoding="utf-8", newline="") as g:
            body = g.read()
        n = body.count(find)
        if n != 1:
            bad.append((mid, "anchor count = %d" % n, find[:70]))

    if bad:
        print("ANCHOR CHECK FAILED -- nothing written:")
        for mid, reason, detail in bad:
            print("  %s : %s : %s" % (mid, reason, detail))
        return 1

    print("anchor check OK: all %d anchors appear exactly once" % len(MUTANTS))

    # --- 1b) ASCII guard (K-116) -------------------------------------------
    #   mutation_test.ps1 must stay ASCII-clean.  An earlier attempt embedded the
    #   RTL's Chinese comment inside an anchor -> the file gained non-ASCII bytes
    #   AND PowerShell failed to parse it.  Anchors must therefore stay ASCII.
    for mid, _f, find, repl, _w in MUTANTS:
        for label, s in (("find", find), ("repl", repl)):
            bad_chars = [c for c in s if ord(c) > 127]
            if bad_chars:
                print("REFUSING: %s %s contains non-ASCII %r (K-116)"
                      % (mid, label, "".join(bad_chars)))
                return 1
    print("ascii check OK: every find/repl is pure ASCII")

    # --- 2) refuse if the ids already exist ---------------------------------
    for mid, _f, _a, _b, _w in MUTANTS:
        if ('id = "%s"' % mid) in txt:
            print("REFUSING: %s already present in mutation_test.ps1" % mid)
            return 1

    # --- 3) build the block and insert before the array terminator ----------
    lines = []
    lines.append("  # ---- W3a semantic layer: axis_map / event_extract / param_extract (2026-09-23)")
    lines.append("  #      These are the modules that turn ADC samples into note events")
    lines.append("  #      (i.e. 'press a key -> sound').  An unguarded W3a chain means the")
    lines.append("  #      instrument can silently stop making sound with every test still green.")
    for idx, (mid, fname, find, repl, why) in enumerate(MUTANTS):
        e_find = find.replace('"', '\\"')
        e_repl = repl.replace('"', '\\"')
        # ⚠️ TRAILING COMMA: PowerShell rejects a trailing "," before the closing ")"
        #    of an array literal ("Missing expression after ','").  The original file's
        #    LAST entry (M44) deliberately has no comma.  Since our block is inserted
        #    directly before ")"" , the FINAL mutant we emit becomes the new last entry
        #    and must therefore omit its comma.
        comma = "" if idx == len(MUTANTS) - 1 else ","
        lines.append('  @{ id = "%s"; file = "%s"; find = "%s"; repl = "%s"; why = "%s" }%s'
                     % (mid, fname, e_find, e_repl, why, comma))
    block = "\n".join(lines) + "\n"

    # insert just before the array terminator: the first line that is exactly ")"
    marker = '@{ id = "M44";'
    idx44 = txt.find(marker)
    if idx44 < 0:
        print("REFUSING: could not locate the M44 entry to anchor the insertion")
        return 1

    # The catalogue ends with a bare ")" on its own line.
    term = txt.find("\n)", idx44)
    if term < 0:
        print("REFUSING: could not locate the array terminator after M44")
        return 1

    # ⚠️ LINE ENDINGS: this file is LF-only.  Joining the block with "\r\n" mixed
    #    CRLF into an LF file and PowerShell then failed with
    #    "Missing expression after ','" -- a parse error that points at the DATA,
    #    not at the invisible \r.  Always match the host file's convention.
    new_txt = txt[:term] + "\n" + block + txt[term + 1:]

    # --- 4) atomic replace -------------------------------------------------
    tmp = SCRIPT + ".tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(new_txt)
    os.replace(tmp, SCRIPT)

    print("wrote %d mutants (M77..M87) into mutation_test.ps1" % len(MUTANTS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
