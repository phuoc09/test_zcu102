// HIMAM_MP: multi-precision variant. FP32 mode retires one MAM result per
// cycle; FP16 mode packs two independent results per cycle, which is where the
// paper's 2x FP16 throughput comes from.
//
// Deviation from the paper: it reuses the shared multi-format units of [16]
// (FPnew), whereas this build instantiates separate FP32 and FP16 accurate
// units and muxes them. That costs area but keeps both modes independently
// verifiable; the scaling trend against parallelism is unaffected.
module himam_mp #(
  parameter int N = 4
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               fp16,
  input  logic [N-1:0][31:0] x,
  input  logic [N-1:0][31:0] w,
  input  logic [31:0]        bias,   // FP32 value, or two packed FP16 values
  output logic [31:0]        y
);
  localparam int HALF     = N / 2;
  localparam int BIAS_LAT = 6;

  // ---- step 1: pairwise sort --------------------------------------------
  logic [HALF-1:0][31:0] smax_key, smax_x, smax_w;
  logic [HALF-1:0][31:0] smin_key, smin_x, smin_w;

  genvar h;
  generate
    for (h = 0; h < HALF; h++) begin : g_sort
      sorting_block_mp u_sb (
        .fp16(fp16),
        .x0(x[2*h]),   .w0(w[2*h]),
        .x1(x[2*h+1]), .w1(w[2*h+1]),
        .max_key(smax_key[h]), .max_x(smax_x[h]), .max_w(smax_w[h]),
        .min_key(smin_key[h]), .min_x(smin_x[h]), .min_w(smin_w[h])
      );
    end
  endgenerate

  logic [HALF-1:0][31:0] r1_max_key, r1_max_x, r1_max_w;
  logic [HALF-1:0][31:0] r1_min_key, r1_min_x, r1_min_w;
  logic r1_fp16;

  always_ff @(posedge clk) begin
    r1_max_key <= smax_key; r1_max_x <= smax_x; r1_max_w <= smax_w;
    r1_min_key <= smin_key; r1_min_x <= smin_x; r1_min_w <= smin_w;
    r1_fp16    <= fp16;
  end

  // ---- step 2: comparator trees -----------------------------------------
  logic [31:0] ct_max_key, ct_max_x, ct_max_w;
  logic [31:0] ct_min_key, ct_min_x, ct_min_w;

  comparator_tree_mp #(.ENTRIES(HALF), .FIND_MAX(1)) u_ct_max (
    .fp16(r1_fp16), .key(r1_max_key), .xin(r1_max_x), .win(r1_max_w),
    .key_o(ct_max_key), .x_o(ct_max_x), .w_o(ct_max_w)
  );
  comparator_tree_mp #(.ENTRIES(HALF), .FIND_MAX(0)) u_ct_min (
    .fp16(r1_fp16), .key(r1_min_key), .xin(r1_min_x), .win(r1_min_w),
    .key_o(ct_min_key), .x_o(ct_min_x), .w_o(ct_min_w)
  );

  logic [31:0] r2_max_x, r2_max_w, r2_min_x, r2_min_w;
  always_ff @(posedge clk) begin
    r2_max_x <= ct_max_x; r2_max_w <= ct_max_w;
    r2_min_x <= ct_min_x; r2_min_w <= ct_min_w;
  end

  // ---- step 3: accurate compute on the survivors ------------------------
  logic [31:0] p32_max, p32_min, s32;
  fp_mul #(.EXP_W(8), .MANT_W(23)) u32_mmax (.clk(clk), .rst_n(rst_n), .a(r2_max_x), .b(r2_max_w), .p(p32_max));
  fp_mul #(.EXP_W(8), .MANT_W(23)) u32_mmin (.clk(clk), .rst_n(rst_n), .a(r2_min_x), .b(r2_min_w), .p(p32_min));
  fp_add #(.EXP_W(8), .MANT_W(23)) u32_app  (.clk(clk), .rst_n(rst_n), .a(p32_max),  .b(p32_min),  .s(s32));

  logic [15:0] p16h_max, p16h_min, s16h;
  logic [15:0] p16l_max, p16l_min, s16l;
  fp_mul #(.EXP_W(5), .MANT_W(10)) u16h_mmax (.clk(clk), .rst_n(rst_n), .a(r2_max_x[31:16]), .b(r2_max_w[31:16]), .p(p16h_max));
  fp_mul #(.EXP_W(5), .MANT_W(10)) u16h_mmin (.clk(clk), .rst_n(rst_n), .a(r2_min_x[31:16]), .b(r2_min_w[31:16]), .p(p16h_min));
  fp_add #(.EXP_W(5), .MANT_W(10)) u16h_app  (.clk(clk), .rst_n(rst_n), .a(p16h_max),        .b(p16h_min),        .s(s16h));
  fp_mul #(.EXP_W(5), .MANT_W(10)) u16l_mmax (.clk(clk), .rst_n(rst_n), .a(r2_max_x[15:0]),  .b(r2_max_w[15:0]),  .p(p16l_max));
  fp_mul #(.EXP_W(5), .MANT_W(10)) u16l_mmin (.clk(clk), .rst_n(rst_n), .a(r2_min_x[15:0]),  .b(r2_min_w[15:0]),  .p(p16l_min));
  fp_add #(.EXP_W(5), .MANT_W(10)) u16l_app  (.clk(clk), .rst_n(rst_n), .a(p16l_max),        .b(p16l_min),        .s(s16l));

  // The output mux must follow the mode of the data leaving the bias adder,
  // which is two stages later than the bias itself.
  localparam int OUT_LAT = BIAS_LAT + 2;

  logic [31:0]         bias_dly [0:BIAS_LAT-1];
  logic [OUT_LAT-1:0]  fp16_dly;
  integer d;
  always_ff @(posedge clk) begin
    bias_dly[0] <= bias;
    fp16_dly[0] <= fp16;
    for (d = 1; d < BIAS_LAT; d++) bias_dly[d] <= bias_dly[d-1];
    for (d = 1; d < OUT_LAT;  d++) fp16_dly[d] <= fp16_dly[d-1];
  end

  wire [31:0] bias_al = bias_dly[BIAS_LAT-1];
  logic [31:0] y32;
  logic [15:0] y16h, y16l;
  fp_add #(.EXP_W(8), .MANT_W(23)) u32_abias  (.clk(clk), .rst_n(rst_n), .a(s32),  .b(bias_al),        .s(y32));
  fp_add #(.EXP_W(5), .MANT_W(10)) u16h_abias (.clk(clk), .rst_n(rst_n), .a(s16h), .b(bias_al[31:16]), .s(y16h));
  fp_add #(.EXP_W(5), .MANT_W(10)) u16l_abias (.clk(clk), .rst_n(rst_n), .a(s16l), .b(bias_al[15:0]),  .s(y16l));

  assign y = fp16_dly[OUT_LAT-1] ? {y16h, y16l} : y32;
endmodule
