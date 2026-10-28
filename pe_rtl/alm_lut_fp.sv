// LUT-ranking key, FP32 only. Drop-in for alm_fp: same ports, same packed
// {exponent, fraction} magnitude, so sorting_block, the comparator tree and the
// rest of the PE are untouched.
//
//   ALM (eqs 5-7):  D* = D or (D-1)/2, E* = E or E+1, R = D*x + D*w, then a
//                   R<0 branch that doubles the significand and decrements E.
//   here:           L = ROM[k top mantissa bits] (true log2(1+D)), S = Lx + Lw.
//                   L is in [0,1), so S in [0,2) and its carry bit lands in the
//                   exponent sum directly: no E* increment, no D* subtract, no
//                   renormalise branch, one narrow adder instead of a 24-bit one.
//
// The key is only ever compared, so it is not a valid float; S is left-aligned
// in the fraction field and the unused low bits are constant zero (the
// comparator in front of them then synthesises to a K+10 bit compare).
(* use_dsp = "no" *)
module alm_lut_fp #(
  parameter int K = 6
) (
  input  logic [31:0] x,     // activation, assumed >= 0 (ReLU)
  input  logic [31:0] w,     // weight
  output logic [30:0] mag
);
  localparam int C    = K + 2;
  localparam int BIAS = 127;
  localparam int EMAX = 255;
  localparam int ES   = 11;

  wire [7:0] ex = x[30:23];
  wire [7:0] ew = w[30:23];

  logic [C-1:0] lx, lw;
  log_rom #(.K(K)) u_rom_x (.addr(x[22 -: K]), .q(lx));
  log_rom #(.K(K)) u_rom_w (.addr(w[22 -: K]), .q(lw));

  wire [C:0] s     = {1'b0, lx} + {1'b0, lw};
  wire       carry = s[C];

  wire signed [ES:0] exp_sum = $signed({{(ES-7){1'b0}}, ex}) + $signed({{(ES-7){1'b0}}, ew})
                             - BIAS + $signed({{ES{1'b0}}, carry});

  wire is_zero = (ex == '0) || (ew == '0);

  always_comb begin
    if (is_zero || exp_sum <= 0) mag = '0;
    else if (exp_sum >= EMAX)    mag = {8'hFF, 23'b0};
    else                         mag = {exp_sum[7:0], s[C-1:0], {(23-C){1'b0}}};
  end
endmodule
