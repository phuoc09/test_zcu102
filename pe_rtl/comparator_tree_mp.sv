// Dual-mode comparator tree. In FP32 mode it reduces one 32-bit lane; in FP16
// mode the two 16-bit halves are reduced independently, which is what lets the
// engine retire two MAM results per cycle at the lower precision.
module comparator_tree_mp #(
  parameter int ENTRIES  = 2,
  parameter bit FIND_MAX = 1
) (
  input  logic                     fp16,
  input  logic [ENTRIES-1:0][31:0] key,
  input  logic [ENTRIES-1:0][31:0] xin,
  input  logic [ENTRIES-1:0][31:0] win,
  output logic [31:0]              key_o,
  output logic [31:0]              x_o,
  output logic [31:0]              w_o
);
  localparam int LEVELS = (ENTRIES <= 1) ? 0 : $clog2(ENTRIES);

  // verilator lint_off UNOPTFLAT
  logic [31:0] k  [0:LEVELS][0:ENTRIES-1];
  logic [31:0] xv [0:LEVELS][0:ENTRIES-1];
  logic [31:0] wv [0:LEVELS][0:ENTRIES-1];
  // verilator lint_on UNOPTFLAT

  genvar lv, i;
  generate
    for (i = 0; i < ENTRIES; i++) begin : g_init
      assign k[0][i]  = key[i];
      assign xv[0][i] = xin[i];
      assign wv[0][i] = win[i];
    end

    for (lv = 0; lv < LEVELS; lv++) begin : g_lvl
      localparam int HALF = (ENTRIES >> lv) / 2;
      for (i = 0; i < HALF; i++) begin : g_cmp
        wire [31:0] ka = k[lv][2*i];
        wire [31:0] kb = k[lv][2*i+1];
        wire take_full = FIND_MAX ? (ka        >= kb)        : (ka        <= kb);
        wire take_hi   = FIND_MAX ? (ka[31:16] >= kb[31:16]) : (ka[31:16] <= kb[31:16]);
        wire take_lo   = FIND_MAX ? (ka[15:0]  >= kb[15:0])  : (ka[15:0]  <= kb[15:0]);
        wire sel_hi = fp16 ? take_hi : take_full;
        wire sel_lo = fp16 ? take_lo : take_full;

        assign k [lv+1][i] = {sel_hi ? ka[31:16]            : kb[31:16],
                              sel_lo ? ka[15:0]             : kb[15:0]};
        assign xv[lv+1][i] = {sel_hi ? xv[lv][2*i][31:16]   : xv[lv][2*i+1][31:16],
                              sel_lo ? xv[lv][2*i][15:0]    : xv[lv][2*i+1][15:0]};
        assign wv[lv+1][i] = {sel_hi ? wv[lv][2*i][31:16]   : wv[lv][2*i+1][31:16],
                              sel_lo ? wv[lv][2*i][15:0]    : wv[lv][2*i+1][15:0]};
      end
    end
  endgenerate

  assign key_o = k [LEVELS][0];
  assign x_o   = xv[LEVELS][0];
  assign w_o   = wv[LEVELS][0];
endmodule
