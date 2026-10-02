from pathlib import Path
import shutil,hashlib,json,subprocess
root=Path.cwd(); ev=root/'evidence/nm-scan-predecode-20261002b'; b=ev/'baseline'; b.mkdir(exist_ok=True)
shutil.copytree(root/'impl',b/'impl',dirs_exist_ok=True)
for f in ['rtl/w3b/note_manager.v','constr/top.cst','constr/top.sdc','Gowin2026.gprj','build_cli.tcl']:
 p=b/f;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/f,p)
files=[p for d in ['rtl','constr','ip'] for p in (root/d).rglob('*') if p.is_file()]+[root/'Gowin2026.gprj',root/'build_cli.tcl',root/'impl/Gowin2026_process_config.json']
(ev/'baseline-hashes.json').write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
(ev/'baseline-git.txt').write_bytes(subprocess.check_output(['git','log','-1','--format=fuller']))
p=root/'rtl/w3b/note_manager.v';s=p.read_text(encoding='utf-8');s=s.replace('    reg [SW-1:0]     scan_cnt;','''    reg [SW-1:0]     scan_cnt;
    // Registered predecode: same edge as scan_cnt, no extra scan/commit cycle.
    // Keep the one-hot state and eight-voice group boundaries in the netlist.
    (* syn_preserve = 1 *) reg [POLY_TARGET-1:0] scan_sel;
    localparam integer SCAN_GROUPS = (POLY_TARGET + 7) / 8;
    localparam integer SCAN_ATTR_W = 5 + AXIS_W + 3 + ENV_W + AGE_W;
    (* syn_keep = 1 *) wire [SCAN_ATTR_W-1:0] scan_group [0:SCAN_GROUPS-1];
    wire [SCAN_ATTR_W-1:0] scan_merge [0:SCAN_GROUPS];
    assign scan_merge[0] = {SCAN_ATTR_W{1'b0}};
    genvar sg, sl;
    generate
        for (sg = 0; sg < SCAN_GROUPS; sg = sg + 1) begin : g_scan_group
            wire [SCAN_ATTR_W-1:0] leaf [0:7];
            for (sl = 0; sl < 8; sl = sl + 1) begin : g_scan_voice
                if (sg*8+sl < POLY_TARGET) begin : g_present
                    assign leaf[sl] = {SCAN_ATTR_W{scan_sel[sg*8+sl]}} &
                        {hold_mask[sg*8+sl], pool_mask[sg*8+sl],
                         free_mask[sg*8+sl], gate_mask[sg*8+sl],
                         env_active_r[sg*8+sl], axis_r[sg*8+sl],
                         src_r[sg*8+sl],
                         env_level_r[(sg*8+sl)*ENV_W +: ENV_W], age_r[sg*8+sl]};
                end else begin : g_padding
                    assign leaf[sl] = {SCAN_ATTR_W{1'b0}};
                end
            end
            assign scan_group[sg] = leaf[0] | leaf[1] | leaf[2] | leaf[3]
                                 | leaf[4] | leaf[5] | leaf[6] | leaf[7];
            assign scan_merge[sg+1] = scan_merge[sg] | scan_group[sg];
        end
    endgenerate''')
a=s.index('    wire               cand_hold ');z=s.index('    //  ',a)
s=s[:a]+'''    wire cand_hold, cand_pool, cand_free, cand_gate, cand_active;
    wire [AXIS_W-1:0] cand_axis;
    wire [2:0] cand_src;
    wire [ENV_W-1:0] cand_env;
    wire [AGE_W-1:0] cand_age;
    assign {cand_hold, cand_pool, cand_free, cand_gate, cand_active,
            cand_axis, cand_src, cand_env, cand_age} = scan_merge[SCAN_GROUPS];
    wire cand_rel = (~cand_gate) & cand_active;
'''+s[z:]
s=s.replace('(axis_r[cand_idx] == cur_axis)','(cand_axis == cur_axis)').replace('(src_r[cand_idx]  != cur_src)','(cand_src  != cur_src)').replace('&& gate_mask[cand_idx];','&& cand_gate;')
s=s.replace('    wire [ENV_W-1:0]   cand_env   = env_level_r[cand_idx*ENV_W +: ENV_W];\n','').replace('    wire [AGE_W-1:0]   cand_age   = age_r[cand_idx];\n','')
s=s.replace('            scan_cnt      <= {SW{1\'b0}};',"            scan_cnt      <= {SW{1'b0}};\n            scan_sel      <= {{(POLY_TARGET-1){1'b0}}, 1'b1};")
s=s.replace("                        scan_cnt   <= {SW{1'b0}};","                        scan_cnt   <= {SW{1'b0}};\n                        scan_sel   <= {{(POLY_TARGET-1){1'b0}}, 1'b1};")
s=s.replace("                        scan_cnt <= scan_cnt + 1'b1;","                        scan_cnt <= scan_cnt + 1'b1;\n                        scan_sel <= scan_sel << 1;")
s=s.replace('// ⭐ 每拍只考察一个 voice ⇒ 深度 = 32:1 mux + 一级比较','// One candidate per edge; advance both indices only before the last item.')
p.write_bytes(s.replace('\n','\r\n').encode('utf-8'))
