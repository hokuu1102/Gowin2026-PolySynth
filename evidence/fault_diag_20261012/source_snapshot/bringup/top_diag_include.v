// Diagnostic compilation unit. Normal project still compiles rtl/top.v.
`define FAULT_DIAG_BUILD
`include "rtl/top.v"
`undef FAULT_DIAG_BUILD
