// Dual-mode sorting block. FP32 mode sorts one pair; FP16 mode sorts the two
// packed 16-bit lanes independently. Six ALMs: two FP32 plus two per FP16 lane.
module sorting_block_mp (
  input  logic        fp16,
  input  logic [31:0] x0,
  input  logic [31:0] w0,
  input  logic [31:0] x1,
  input  logic [31:0] w1,
  output logic [31:0] max_key,
  output logic [31:0] max_x,
  output logic [31:0] max_w,
  output logic [31:0] min_key,
  output logic [31:0] min_x,
  output logic [31:0] min_w
);
  // ---- FP32 lane --------------------------------------------------------
  logic [30:0] m32_0, m32_1;
  alm_fp #(.EXP_W(8), .MANT_W(23)) u32_0 (.x(x0), .w(w0), .mag(m32_0));
  alm_fp #(.EXP_W(8), .MANT_W(23)) u32_1 (.x(x1), .w(w1), .mag(m32_1));

  wire [31:0] k32_0 = {~w0[31], m32_0 ^ {31{w0[31]}}};
  wire [31:0] k32_1 = {~w1[31], m32_1 ^ {31{w1[31]}}};

  // ---- FP16 lanes -------------------------------------------------------
  logic [14:0] m16_0h, m16_0l, m16_1h, m16_1l;
  alm_fp #(.EXP_W(5), .MANT_W(10)) u16_0h (.x(x0[31:16]), .w(w0[31:16]), .mag(m16_0h));
  alm_fp #(.EXP_W(5), .MANT_W(10)) u16_0l (.x(x0[15:0]),  .w(w0[15:0]),  .mag(m16_0l));
  alm_fp #(.EXP_W(5), .MANT_W(10)) u16_1h (.x(x1[31:16]), .w(w1[31:16]), .mag(m16_1h));
  alm_fp #(.EXP_W(5), .MANT_W(10)) u16_1l (.x(x1[15:0]),  .w(w1[15:0]),  .mag(m16_1l));

  wire [31:0] k16_0 = {{~w0[31], m16_0h ^ {15{w0[31]}}},
                       {~w0[15], m16_0l ^ {15{w0[15]}}}};
  wire [31:0] k16_1 = {{~w1[31], m16_1h ^ {15{w1[31]}}},
                       {~w1[15], m16_1l ^ {15{w1[15]}}}};

  wire [31:0] key0 = fp16 ? k16_0 : k32_0;
  wire [31:0] key1 = fp16 ? k16_1 : k32_1;

  wire take_full = (key0        >= key1);
  wire take_hi   = (key0[31:16] >= key1[31:16]);
  wire take_lo   = (key0[15:0]  >= key1[15:0]);
  wire sel_hi = fp16 ? take_hi : take_full;
  wire sel_lo = fp16 ? take_lo : take_full;

  assign max_key = {sel_hi ? key0[31:16] : key1[31:16],
                    sel_lo ? key0[15:0]  : key1[15:0]};
  assign max_x   = {sel_hi ? x0[31:16]   : x1[31:16],
                    sel_lo ? x0[15:0]    : x1[15:0]};
  assign max_w   = {sel_hi ? w0[31:16]   : w1[31:16],
                    sel_lo ? w0[15:0]    : w1[15:0]};
  assign min_key = {sel_hi ? key1[31:16] : key0[31:16],
                    sel_lo ? key1[15:0]  : key0[15:0]};
  assign min_x   = {sel_hi ? x1[31:16]   : x0[31:16],
                    sel_lo ? x1[15:0]    : x0[15:0]};
  assign min_w   = {sel_hi ? w1[31:16]   : w0[31:16],
                    sel_lo ? w1[15:0]    : w0[15:0]};
endmodule
