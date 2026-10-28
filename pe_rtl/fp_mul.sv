// Accurate FP multiplier parameterised by format, LUT-only.
// Defaults are FP32; FP16 is (EXP_W=5, MANT_W=10). Subnormals flush to zero.
(* use_dsp = "no" *)
module fp_mul #(
  parameter int EXP_W  = 8,
  parameter int MANT_W = 23
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic [EXP_W+MANT_W:0] a,
  input  logic [EXP_W+MANT_W:0] b,
  output logic [EXP_W+MANT_W:0] p
);
  localparam int W      = EXP_W + MANT_W + 1;
  localparam int SIG_W  = MANT_W + 1;
  localparam int PROD_W = 2 * SIG_W;
  localparam int EW     = EXP_W + 2;               // signed exponent headroom
  localparam int BIAS   = (1 << (EXP_W - 1)) - 1;
  localparam int EMAX   = (1 << EXP_W) - 1;

  wire [EXP_W-1:0] a_exp = a[W-2 -: EXP_W];
  wire [EXP_W-1:0] b_exp = b[W-2 -: EXP_W];
  wire a_zero = (a_exp == '0);
  wire b_zero = (b_exp == '0);
  wire [SIG_W-1:0] a_sig = {~a_zero, a[MANT_W-1:0]};
  wire [SIG_W-1:0] b_sig = {~b_zero, b[MANT_W-1:0]};

  logic                s0_sign;
  logic signed [EW:0]  s0_exp;
  logic [PROD_W-1:0]   s0_prod;
  logic                s0_zero;

  always_ff @(posedge clk) begin
    s0_sign <= a[W-1] ^ b[W-1];
    s0_exp  <= $signed({2'b0, a_exp}) + $signed({2'b0, b_exp}) - BIAS;
    s0_prod <= a_sig * b_sig;
    s0_zero <= a_zero | b_zero;
  end

  logic signed [EW:0]  n_exp;
  logic [SIG_W-1:0]    n_mant;
  logic                guard, sticky, round_bit;

  always_comb begin
    // significands are in [1,2), so the product lands in [1,4)
    if (s0_prod[PROD_W-1]) begin
      n_exp  = s0_exp + 1;
      n_mant = s0_prod[PROD_W-1 -: SIG_W];
      guard  = s0_prod[PROD_W-SIG_W-1];
      sticky = |s0_prod[PROD_W-SIG_W-2:0];
    end else begin
      n_exp  = s0_exp;
      n_mant = s0_prod[PROD_W-2 -: SIG_W];
      guard  = s0_prod[PROD_W-SIG_W-2];
      sticky = |s0_prod[PROD_W-SIG_W-3:0];
    end
    round_bit = guard & (sticky | n_mant[0]);
  end

  wire [SIG_W:0]      rounded = {1'b0, n_mant} + round_bit;
  wire                rcarry  = rounded[SIG_W];
  wire [MANT_W-1:0]   r_mant  = rcarry ? rounded[SIG_W-1:1] : rounded[MANT_W-1:0];
  wire signed [EW:0]  r_exp   = rcarry ? n_exp + 1 : n_exp;

  always_ff @(posedge clk) begin
    if (!rst_n)                     p <= '0;
    else if (s0_zero || r_exp <= 0) p <= {s0_sign, {(W-1){1'b0}}};
    else if (r_exp >= EMAX)         p <= {s0_sign, {EXP_W{1'b1}}, {MANT_W{1'b0}}};
    else                            p <= {s0_sign, r_exp[EXP_W-1:0], r_mant};
  end
endmodule
