# Keypad regression compatibility

Current Icarus rejects `continue` at the original sweep line 325 (compile exit 2, `red/compile.log`). Replace that unsupported statement with an equivalent `if (kk != 12 && kk != 15)` body guard. Long-press keys remain covered by the following sections. All original assertions retained; RTL unchanged.

Green compile/run exit 0 and explicit PASS (`green/`). This is a test compatibility repair, not a new hardware keypad implementation.
