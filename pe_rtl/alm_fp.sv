// Approximate logarithmic multiplier parameterised by format (HIMAM Fig. 3,
// eqs 5-7). Emits the packed magnitude only: HIMAM never needs the
// antilogarithm because the value is used solely as a comparison key.
(* use_dsp = "no" *)
module alm_fp #(
  parameter int EXP_W  = 8,
  parameter int MANT_W = 23
) (
  input  logic [EXP_W+MANT_W:0]   x,     // activation, assumed >= 0 (ReLU)
  input  logic [EXP_W+MANT_W:0]   w,     // weight
  output logic [EXP_W+MANT_W-1:0] mag    // approximate |x*w| as {exponent, mantissa}
);
  localparam int W    = EXP_W + MANT_W + 1;
  localparam int BIAS = (1 << (EXP_W - 1)) - 1;
  localparam int EMAX = (1 << EXP_W) - 1;
  localparam int ES   = EXP_W + 3;                 // signed exponent headroom

  // ---- pre-process: eq (5), the "-1 / >>1 / +1" datapath of Fig. 3 -------
  function automatic logic signed [MANT_W:0] d_star(input logic [MANT_W-1:0] d);
    // d is in [0,1); when d >= 0.5 return (d-1)/2, else d
    d_star = d[MANT_W-1] ? ($signed({1'b1, d}) >>> 1) : $signed({1'b0, d});
  endfunction

  wire [EXP_W-1:0]  ex = x[W-2 -: EXP_W];
  wire [EXP_W-1:0]  ew = w[W-2 -: EXP_W];
  wire [MANT_W-1:0] dx = x[MANT_W-1:0];
  wire [MANT_W-1:0] dw = w[MANT_W-1:0];

  wire [EXP_W:0] ex_star = {1'b0, ex} + {{EXP_W{1'b0}}, dx[MANT_W-1]};
  wire [EXP_W:0] ew_star = {1'b0, ew} + {{EXP_W{1'b0}}, dw[MANT_W-1]};
  wire signed [MANT_W:0] dx_star = d_star(dx);
  wire signed [MANT_W:0] dw_star = d_star(dw);

  // ---- MUL block: eqs (6)-(7) -------------------------------------------
  wire signed [MANT_W+1:0] r = dx_star + dw_star;          // eq (6)
  wire neg = r[MANT_W+1];

  wire signed [ES:0] exp_sum = $signed({2'b0, ex_star}) + $signed({2'b0, ew_star})
                             - BIAS - $signed({{ES{1'b0}}, neg});
  wire [MANT_W-1:0] d_p = neg ? (r[MANT_W-1:0] << 1) : r[MANT_W-1:0];

  wire is_zero = (ex == '0) || (ew == '0);

  always_comb begin
    if (is_zero || exp_sum <= 0) mag = '0;
    else if (exp_sum >= EMAX)    mag = {{EXP_W{1'b1}}, {MANT_W{1'b0}}};
    else                         mag = {exp_sum[EXP_W-1:0], d_p};
  end
endmodule
