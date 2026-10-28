// Binary comparator tree that reduces ENTRIES candidates to the single max (or
// min) key while carrying the associated (x, W) operand pair along with it.
// ENTRIES is expected to be a power of two (N/2 for N = 4, 8, 16).
module comparator_tree #(
  parameter int ENTRIES  = 2,
  parameter bit FIND_MAX = 1,
  parameter int KW       = 32     // key width (narrow for LUT-ranking)
) (
  input  logic [ENTRIES-1:0][KW-1:0] key,
  input  logic [ENTRIES-1:0][31:0] xin,
  input  logic [ENTRIES-1:0][31:0] win,
  output logic [KW-1:0]              key_o,
  output logic [31:0]              x_o,
  output logic [31:0]              w_o
);
  localparam int LEVELS = (ENTRIES <= 1) ? 0 : $clog2(ENTRIES);

  // verilator lint_off UNOPTFLAT
  // Level-indexed, so the apparent self-reference is a false positive: every
  // element of level lv+1 depends only on level lv.
  logic [KW-1:0] k [0:LEVELS][0:ENTRIES-1];
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
        wire take_a = FIND_MAX ? (k[lv][2*i] >= k[lv][2*i+1])
                               : (k[lv][2*i] <= k[lv][2*i+1]);
        assign k [lv+1][i] = take_a ? k [lv][2*i] : k [lv][2*i+1];
        assign xv[lv+1][i] = take_a ? xv[lv][2*i] : xv[lv][2*i+1];
        assign wv[lv+1][i] = take_a ? wv[lv][2*i] : wv[lv][2*i+1];
      end
    end
  endgenerate

  assign key_o = k [LEVELS][0];
  assign x_o   = xv[LEVELS][0];
  assign w_o   = wv[LEVELS][0];
endmodule
