"""One-shot candidate preparation; refuses to overwrite its baseline."""
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
src = ROOT / 'rtl/w3b/note_manager.v'
old = src.read_text(encoding='utf-8')
ref = OUT / 'note_manager_reference.v'
assert not ref.exists()
ref.write_text(old.replace('module note_manager #(', 'module note_manager_reference #(', 1), encoding='utf-8')
(OUT / 'note_manager.before.v').write_bytes(src.read_bytes())
for name in ['Gowin2026_syn_rsc.xml', 'Gowin2026_syn.rpt.html', 'Gowin2026.log']:
    shutil.copy2(ROOT / 'impl/gwsynthesis' / name, OUT / ('baseline-' + name))
shutil.copy2(ROOT / 'impl/pnr/Gowin2026.rpt.txt', OUT / 'baseline-pnr.rpt.txt')

new = old
# Select the event data once, before distributing it to all voices. The two
# enables are disjoint state decodes. Do not merge gate/axis/reset semantics.
anchor = '    integer i;\n'
wires = '''    // Allocation and retrigger are mutually exclusive FSM states. Select
    // their common payload once, rather than once per voice and per field.
    // This is combinational: all writes retain their original clock edge.
    wire event_write_retrig = (state == ST_RETRIG) && same_en_r;
    wire event_write_alloc  = (state == ST_COMMIT2) && cmt_en_r;
    wire event_write_en = event_write_retrig || event_write_alloc;
    wire [IDX_W-1:0] event_write_idx = event_write_retrig ? same_idx_r : cmt_idx_r;
    wire [2:0] event_write_src = event_write_retrig ? cur_src : cmt_src_r;
    wire [PHASE_W-1:0] event_write_phase = event_write_retrig ? cur_inc : cmt_inc_r;
    wire [VEL_W-1:0] event_write_vel = event_write_retrig ? new_vel : cmt_vel_r;
    wire [TIMBRE_W-1:0] event_write_timbre = event_write_retrig ? new_timbre : cmt_timbre_r;
'''
assert new.count(anchor) == 1
new = new.replace(anchor, wires + anchor)
for field in ['src_r', 'phase_r', 'vel_r', 'timbre_r', 'age_r', 'vtgt_rep']:
    pattern = rf'^\s*{field}\[(?:same_idx_r|cmt_idx_r)\]\s*<=.*\n'
    new, n = re.subn(pattern, '', new, flags=re.M)
    assert n == 2, (field, n)
anchor = '                default: state <= ST_IDLE;\n            endcase\n'
write = '''
            // Same priority as the former ST_RETRIG / ST_COMMIT2 writes:
            // event payload wins over this edge's ramp, pitch update and age.
            // A constant per-voice destination avoids read/modify/write muxes.
            for (i = 0; i < POLY_TARGET; i = i + 1) begin
                if (event_write_en && (event_write_idx == i)) begin
                    src_r[i]    <= event_write_src;
                    phase_r[i]  <= event_write_phase;
                    vel_r[i]    <= event_write_vel;
                    timbre_r[i] <= event_write_timbre;
                    age_r[i]    <= {AGE_W{1'b0}};
                    vtgt_rep[i] <= event_write_vel;
                end
            end
'''
assert new.count(anchor) == 1
new = new.replace(anchor, anchor + write)
src.write_text(new, encoding='utf-8', newline='\n')
print('Prepared shared event payload candidate and immutable baseline')
