"""Generate explicit port wiring for the standalone full-module differential TB."""
from pathlib import Path
import re
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
s = (OUT / 'note_manager_reference.v').read_text(encoding='utf-8')
s = re.sub(r'//[^\n]*', '', s)
header = s[s.index('module note_manager_reference'):s.index('\n);')]
ports = re.findall(r'\b(input|output)\s+wire\s*(signed\s+)?(\[[^\]]+\])?\s*(\w+)', header)
params = re.findall(r'parameter integer (\w+)\s*=', header)
decls, connects, checks, inits = [], [], [], []
for direction, signed, width, name in ports:
    if direction == 'input':
        decls.append(f'    reg {signed}{width} {name};')
        inits.append(f'        {name} = 0;')
    else:
        decls.append(f'    wire {width} {name}, ref_{name};')
        checks.append(f'        if ({name} !== ref_{name}) $fatal(1, "DIFF {name} cycle=%0d", cycles);')
    connects.append((name, direction))
instances = []
for module, inst in [('note_manager', 'dut'), ('note_manager_reference', 'ref_dut')]:
    instances.append('    ' + module + ' #(\n        ' + ', '.join(f'.{n}({n})' for n in params) + '\n    ) ' + inst + ' (\n        ' + ',\n        '.join(f'.{n}({"ref_" if inst == "ref_dut" and d == "output" else ""}{n})' for n, d in connects) + '\n    );')
for name in ['state', 'scan_cnt', 'scan_sel', 'best_valid', 'best_idx', 'best_cls', 'best_env', 'best_age',
             'fifo_cnt', 'fifo_wr', 'fifo_rd', 'retrig_low', 'env_level_r', 'env_active_r', 'cmt_en_r', 'same_en_r']:
    checks.append(f'        if (dut.{name} !== ref_dut.{name}) $fatal(1, "DIFF internal {name} cycle=%0d", cycles);')
for name in ['gate_r', 'axis_r', 'src_r', 'phase_r', 'vel_r', 'timbre_r', 'age_r', 'vtgt_rep']:
    checks.append(f'        for (j=0; j<POLY_TARGET; j=j+1) if (dut.{name}[j] !== ref_dut.{name}[j]) $fatal(1, "DIFF {name} voice=%0d cycle=%0d", j, cycles);')
for name in ['vtgt_val', 'vtgt_vld']:
    checks.append(f'        for (j=0; j<(1<<AXIS_W); j=j+1) if (dut.{name}[j] !== ref_dut.{name}[j]) $fatal(1, "DIFF {name} axis=%0d cycle=%0d", j, cycles);')
body = '''
    integer cycles=0, j, k, v, n, wait_count, seed=32'h31b2026;
    integer commits=0, retriggers=0, collision_edges=0, drops=0;
    reg [POLY_TARGET-1:0] written=0;
    always #5 clk_i = ~clk_i;
    always @(posedge clk_i) begin
        if (rst_n_i) begin
            if (dut.state == 4 && dut.cmt_en_r) begin
                commits=commits+1; written[dut.cmt_idx_r]=1;
            end
            if (dut.state == 5 && dut.same_en_r) retriggers=retriggers+1;
            if ((dut.state == 4 || dut.state == 5) && sample_tick_i && pitch_upd_valid_i && vel_upd_valid_i)
                collision_edges=collision_edges+1;
            if (dut.fifo_drop) drops=drops+1;
        end
        #1;
        cycles=cycles+1;
CHECKS
    end
    task drive;
        input integer mode;
        begin
            @(negedge clk_i);
            sample_tick_i = ($random(seed) & 3) == 0;
            note_valid_i = mode == 2 ? (($random(seed) & 3) != 0) : 0;
            note_axis_i = $random(seed);
            note_src_i = $unsigned($random(seed)) % 5;
            note_kind_i = $unsigned($random(seed)) % 3;
            note_phase_inc_i = $random(seed);
            note_velocity_i = $random(seed);
            evt_timbre_i = $random(seed);
            evt_timbre_valid_i = $random(seed);
            default_timbre_i = $random(seed);
            vel_upd_valid_i = $random(seed);
            vel_upd_axis_i = $random(seed);
            vel_upd_src_i = $unsigned($random(seed)) % 5;
            vel_upd_value_i = $random(seed);
            pitch_upd_valid_i = $random(seed);
            pitch_upd_axis_i = $random(seed);
            pitch_upd_src_i = $unsigned($random(seed)) % 5;
            pitch_upd_value_i = $random(seed);
            event_lost_clr_i = (($random(seed) & 255) == 0);
            base_commit_i = (($random(seed) & 63) == 0);
            case ($random(seed) & 3)
                0: base_semi_i=0; 1: base_semi_i=12; 2: base_semi_i=24; 3: base_semi_i=127;
            endcase
            transpose_semi_i = $random(seed);
            for (v=0; v<POLY_TARGET; v=v+1) begin
                env_level_i[v*ENV_W +: ENV_W] = mode == 0 ? 0 : $random(seed);
                env_active_i[v] = mode == 0 ? 0 : ($random(seed) & 1);
            end
            // Explicit collisions with the actual destination voice. Event
            // writes must win over ramp / pitch / age on exactly this edge.
            if ((dut.state == 4 && dut.cmt_en_r) || (dut.state == 5 && dut.same_en_r)) begin
                n = dut.state == 5 ? dut.same_idx_r : dut.cmt_idx_r;
                sample_tick_i=1; vel_upd_valid_i=1; pitch_upd_valid_i=1;
                pitch_upd_axis_i=dut.axis_r[n]; pitch_upd_src_i=dut.src_r[n];
                vel_upd_axis_i=dut.axis_r[n]; vel_upd_src_i=dut.src_r[n];
            end
        end
    endtask
    initial begin
INITS
        repeat (3) @(negedge clk_i);
        rst_n_i=1;
        // Fill ordinary and AUX pools, then same-source/axis reuse and steal.
        for (k=0; k<240; k=k+1) begin
            drive(0);
            note_valid_i=1; note_axis_i=k%16; note_src_i=(k/16)%5;
            note_kind_i=0; note_velocity_i=k; note_phase_inc_i=32'h12340000+k;
            for (wait_count=0; wait_count<POLY_TARGET+10; wait_count=wait_count+1) drive(0);
        end
        // Continuous busy FIFO, drops, all event kinds, release tails and reset.
        for (k=0; k<12000; k=k+1) begin
            drive(2);
            rst_n_i = (k%3000 != 2999);
        end
        rst_n_i=1;
        for (k=0; k<2000; k=k+1) drive(1);
        @(negedge clk_i);
        if (commits < POLY_TARGET || retriggers < 10 || collision_edges < 20 || drops < 10)
            $fatal(1, "FAIL insufficient coverage c=%0d r=%0d collisions=%0d drops=%0d", commits,retriggers,collision_edges,drops);
        if (written !== {POLY_TARGET{1'b1}}) $fatal(1, "FAIL unvisited voice %h", written);
        $display("PASS: tb_note_manager_write_share P=%0d T3=%0d cycles=%0d commits=%0d retriggers=%0d collisions=%0d drops=%0d all_voice_mask=%h", POLY_TARGET,T3_EN,cycles,commits,retriggers,collision_edges,drops,written);
        $finish;
    end
    initial begin #2000000; $fatal(1, "FAIL watchdog"); end
endmodule
'''.replace('CHECKS', '\n'.join(checks)).replace('INITS', '\n'.join(inits))
param_text = header[header.index('#(')+2:header.index(') (')].replace('RESERVED_N  = 0', 'RESERVED_N  = 5')
text = '''`timescale 1ns/1ps
// Actual RTL versus frozen pre-change RTL, checked after every system edge.
// Reference is archived with the experiment, never regenerated from the DUT.
`include "evidence/h5/cls-next-20261004/note_manager_reference.v"
module tb_note_manager_write_share #(
''' + param_text + '\n);\n' + '\n'.join(decls + instances) + body
(ROOT / 'tb/w3b/tb_note_manager_write_share.sv').write_text(text, encoding='utf-8')
