// HIMAM sorting block (Fig. 2): two ALMs, pack, and a compare that splits the
// pair into a max and a min candidate, each carrying its (x, W) operands.
//
// Deviation from the paper's Fig. 2 text: it describes an unsigned compare with
// sign muxes, which silently inverts when BOTH weights are negative (larger
// magnitude is then the smaller value). The monotone key below orders all four
// sign combinations correctly for the cost of one conditional inversion.
module sorting_block #(
  parameter int K  = 0,   // 0 = HIMAM ALM (eqs 5-7); 2..10 = LUT-ranking, k-bit ROM
  parameter int KW = (K == 0) ? 32 : K + 11   // key width: sign + 8 exp + (K+2) log bits
) (
  input  logic [31:0] x0,
  input  logic [31:0] w0,
  input  logic [31:0] x1,
  input  logic [31:0] w1,
  output logic [KW-1:0] max_key,
  output logic [31:0] max_x,
  output logic [31:0] max_w,
  output logic [KW-1:0] min_key,
  output logic [31:0] min_x,
  output logic [31:0] min_w
);
  logic [30:0] mag0, mag1;

  generate
    if (K == 0) begin : g_alm
      alm_fp u_alm0 (.x(x0), .w(w0), .mag(mag0));
      alm_fp u_alm1 (.x(x1), .w(w1), .mag(mag1));
    end else begin : g_lut
      alm_lut_fp #(.K(K)) u_alm0 (.x(x0), .w(w0), .mag(mag0));
      alm_lut_fp #(.K(K)) u_alm1 (.x(x1), .w(w1), .mag(mag1));
    end
  endgenerate

  // pack: sign-magnitude -> unsigned-comparable key (product sign == weight sign
  // because activations are non-negative after ReLU)
  // LUT-ranking keeps only the K+10 significant bits of mag (the rest is constant
  // zero), so the key, its registers and the comparators all shrink with K.
  localparam int MW = KW - 1;
  wire [KW-1:0] key0 = {~w0[31], mag0[30 -: MW] ^ {MW{w0[31]}}};
  wire [KW-1:0] key1 = {~w1[31], mag1[30 -: MW] ^ {MW{w1[31]}}};

  wire sel0_is_max = (key0 >= key1);

  always_comb begin
    max_key = sel0_is_max ? key0 : key1;
    max_x   = sel0_is_max ? x0   : x1;
    max_w   = sel0_is_max ? w0   : w1;
    min_key = sel0_is_max ? key1 : key0;
    min_x   = sel0_is_max ? x1   : x0;
    min_w   = sel0_is_max ? w1   : w0;
  end
endmodule
