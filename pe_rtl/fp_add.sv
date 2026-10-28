// Accurate FP adder parameterised by format, LUT-only. Round to nearest even,
// subnormals flush to zero. Defaults to FP32; FP16 is (EXP_W=5, MANT_W=10).
(* use_dsp = "no" *)
module fp_add #(
  parameter int EXP_W  = 8,
  parameter int MANT_W = 23
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic [EXP_W+MANT_W:0] a,
  input  logic [EXP_W+MANT_W:0] b,
  output logic [EXP_W+MANT_W:0] s
);
  localparam int W     = EXP_W + MANT_W + 1;
  localparam int SIG_W = MANT_W + 1;
  localparam int EXT_W = SIG_W + 3;                // guard, round, sticky room
  localparam int SUM_W = EXT_W + 1;
  localparam int EW    = EXP_W + 2;
  localparam int EMAX  = (1 << EXP_W) - 1;

  function automatic [7:0] lzc(input logic [SUM_W-1:0] v);
    int i;
    begin
      lzc = SUM_W;
      for (i = 0; i < SUM_W; i++)
        if (v[SUM_W-1-i] && lzc == SUM_W) lzc = i[7:0];
    end
  endfunction

  wire [EXP_W-1:0] a_exp = a[W-2 -: EXP_W];
  wire [EXP_W-1:0] b_exp = b[W-2 -: EXP_W];
  wire a_zero = (a_exp == '0);
  wire b_zero = (b_exp == '0);
  wire a_gt   = (a[W-2:0] >= b[W-2:0]);            // IEEE bit pattern orders magnitudes

  wire [W-1:0] big = a_gt ? a : b;
  wire [W-1:0] sml = a_gt ? b : a;
  wire         bz  = a_gt ? a_zero : b_zero;
  wire         sz  = a_gt ? b_zero : a_zero;

  wire [EXT_W-1:0] big_sig = {~bz, big[MANT_W-1:0], 3'b000};
  wire [EXT_W-1:0] sml_sig = {~sz, sml[MANT_W-1:0], 3'b000};
  wire [EXP_W-1:0] diff    = big[W-2 -: EXP_W] - sml[W-2 -: EXP_W];
  wire [EXP_W-1:0] shamt   = (diff > EXT_W[EXP_W-1:0]) ? EXT_W[EXP_W-1:0] : diff;

  wire [EXT_W-1:0] sml_shift = sml_sig >> shamt;
  wire             lost      = |(sml_sig & ~({EXT_W{1'b1}} << shamt));
  wire             op_sub    = a[W-1] ^ b[W-1];

  logic             s0_sign;
  logic [EXP_W-1:0] s0_exp;
  logic [SUM_W-1:0] s0_sum;
  logic             s0_lost, s0_bothzero;

  // Bits shifted out during alignment are worth less than one LSB. For an add
  // that is a plain truncation, but a subtract must borrow: OR-ing them into
  // the LSB is a no-op whenever that LSB is already set and loses 1 ULP.
  always_ff @(posedge clk) begin
    s0_sign     <= big[W-1];
    s0_exp      <= big[W-2 -: EXP_W];
    s0_sum      <= op_sub ? ({1'b0, big_sig} - {1'b0, sml_shift} - lost)
                          : ({1'b0, big_sig} + {1'b0, sml_shift});
    s0_lost     <= lost;
    s0_bothzero <= a_zero & b_zero;
  end

  logic [SUM_W-1:0]  n_sum;
  logic signed [EW:0] n_exp;
  logic [7:0]        lz;
  logic              norm_drop;

  always_comb begin
    lz = lzc(s0_sum);
    norm_drop = 1'b0;
    if (s0_sum[SUM_W-1]) begin                     // carry out of the add
      n_sum     = s0_sum >> 1;
      n_exp     = $signed({2'b0, s0_exp}) + 1;
      norm_drop = s0_sum[0];                       // bit shifted off must survive
    end else begin
      // lz == 1 already means the leading one sits at bit EXT_W-1, i.e. normal
      n_sum = s0_sum << (lz - 8'd1);
      n_exp = $signed({2'b0, s0_exp}) - $signed({1'b0, lz - 8'd1});
    end
  end

  wire              guard   = n_sum[2];
  wire              sticky  = |n_sum[1:0] | s0_lost | norm_drop;
  wire [SIG_W-1:0]  mant    = n_sum[EXT_W-1 -: SIG_W];
  wire              rnd     = guard & (sticky | mant[0]);
  wire [SIG_W:0]    rounded = {1'b0, mant} + rnd;
  wire              rcarry  = rounded[SIG_W];
  wire [MANT_W-1:0] r_mant  = rcarry ? rounded[SIG_W-1:1] : rounded[MANT_W-1:0];
  wire signed [EW:0] r_exp  = rcarry ? n_exp + 1 : n_exp;

  always_ff @(posedge clk) begin
    if (!rst_n)                                        s <= '0;
    else if (s0_bothzero || s0_sum == '0 || r_exp <= 0) s <= '0;
    else if (r_exp >= EMAX)                            s <= {s0_sign, {EXP_W{1'b1}}, {MANT_W{1'b0}}};
    else                                               s <= {s0_sign, r_exp[EXP_W-1:0], r_mant};
  end
endmodule
