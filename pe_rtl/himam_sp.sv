// HIMAM_SP: single-precision Multiply-and-Max/Min processing element.
// Pipeline of Fig. 1(b): N/2 sorting blocks -> comparator trees -> accurate
// multiply-then-add applied to only the two surviving operand pairs.
module himam_sp #(
  parameter int N = 4,
  parameter int K = 0     // ranking key: 0 = ALM, 2..10 = LUT-ranking
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic [N-1:0][31:0]   x,
  input  logic [N-1:0][31:0]   w,
  input  logic [31:0]          bias,
  output logic [31:0]          y
);
  localparam int HALF     = N / 2;
  localparam int KW       = (K == 0) ? 32 : K + 11;
  localparam int BIAS_LAT = 6;   // sort + tree + mul(2) + add(2)

  // ---- step 1: pairwise sort via approximate products --------------------
  logic [HALF-1:0][KW-1:0] smax_key;
  logic [HALF-1:0][31:0]   smax_x, smax_w;
  logic [HALF-1:0][KW-1:0] smin_key;
  logic [HALF-1:0][31:0]   smin_x, smin_w;

  genvar h;
  generate
    for (h = 0; h < HALF; h++) begin : g_sort
      sorting_block #(.K(K)) u_sb (
        .x0(x[2*h]),   .w0(w[2*h]),
        .x1(x[2*h+1]), .w1(w[2*h+1]),
        .max_key(smax_key[h]), .max_x(smax_x[h]), .max_w(smax_w[h]),
        .min_key(smin_key[h]), .min_x(smin_x[h]), .min_w(smin_w[h])
      );
    end
  endgenerate

  logic [HALF-1:0][KW-1:0] r1_max_key;
  logic [HALF-1:0][31:0]   r1_max_x, r1_max_w;
  logic [HALF-1:0][KW-1:0] r1_min_key;
  logic [HALF-1:0][31:0]   r1_min_x, r1_min_w;

  always_ff @(posedge clk) begin
    r1_max_key <= smax_key; r1_max_x <= smax_x; r1_max_w <= smax_w;
    r1_min_key <= smin_key; r1_min_x <= smin_x; r1_min_w <= smin_w;
  end

  // ---- step 2: comparator trees -----------------------------------------
  logic [KW-1:0] ct_max_key;
  logic [31:0]   ct_max_x, ct_max_w;
  logic [KW-1:0] ct_min_key;
  logic [31:0]   ct_min_x, ct_min_w;

  comparator_tree #(.ENTRIES(HALF), .FIND_MAX(1), .KW(KW)) u_ct_max (
    .key(r1_max_key), .xin(r1_max_x), .win(r1_max_w),
    .key_o(ct_max_key), .x_o(ct_max_x), .w_o(ct_max_w)
  );
  comparator_tree #(.ENTRIES(HALF), .FIND_MAX(0), .KW(KW)) u_ct_min (
    .key(r1_min_key), .xin(r1_min_x), .win(r1_min_w),
    .key_o(ct_min_key), .x_o(ct_min_x), .w_o(ct_min_w)
  );

  logic [31:0] r2_max_x, r2_max_w, r2_min_x, r2_min_w;
  always_ff @(posedge clk) begin
    r2_max_x <= ct_max_x; r2_max_w <= ct_max_w;
    r2_min_x <= ct_min_x; r2_min_w <= ct_min_w;
  end

  // ---- step 3: accurate compute on the two survivors ---------------------
  logic [31:0] p_max, p_min, p_sum;

  fp_mul u_mul_max (.clk(clk), .rst_n(rst_n), .a(r2_max_x), .b(r2_max_w), .p(p_max));
  fp_mul u_mul_min (.clk(clk), .rst_n(rst_n), .a(r2_min_x), .b(r2_min_w), .p(p_min));
  fp_add u_add_pp  (.clk(clk), .rst_n(rst_n), .a(p_max),    .b(p_min),    .s(p_sum));

  logic [31:0] bias_dly [0:BIAS_LAT-1];
  integer d;
  always_ff @(posedge clk) begin
    bias_dly[0] <= bias;
    for (d = 1; d < BIAS_LAT; d++) bias_dly[d] <= bias_dly[d-1];
  end

  fp_add u_add_bias (.clk(clk), .rst_n(rst_n),
                       .a(p_sum), .b(bias_dly[BIAS_LAT-1]), .s(y));
endmodule
