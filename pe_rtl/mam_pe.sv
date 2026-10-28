// Baseline MAM neuron as originally proposed (Fig. 1(a)): every product is
// computed accurately and only then compared, so all N multipliers are paid for.
module mam_pe #(
  parameter int N = 4
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic [N-1:0][31:0] x,
  input  logic [N-1:0][31:0] w,
  input  logic [31:0]        bias,
  output logic [31:0]        y
);
  localparam int BIAS_LAT = 2 + 1 + 1 + 2;   // mul, key reg, tree reg, add

  logic [N-1:0][31:0] prod;

  genvar i;
  generate
    for (i = 0; i < N; i++) begin : g_mul
      fp_mul u_mul (.clk(clk), .rst_n(rst_n), .a(x[i]), .b(w[i]), .p(prod[i]));
    end
  endgenerate

  // order accurate FP products by a monotone key so one tree serves both signs
  logic [N-1:0][31:0] key;
  generate
    for (i = 0; i < N; i++) begin : g_key
      assign key[i] = {~prod[i][31], prod[i][30:0] ^ {31{prod[i][31]}}};
    end
  endgenerate

  logic [N-1:0][31:0] r_key, r_prod;
  always_ff @(posedge clk) begin
    r_key  <= key;
    r_prod <= prod;
  end

  logic [31:0] max_key, max_val, max_dummy;
  logic [31:0] min_key, min_val, min_dummy;

  comparator_tree #(.ENTRIES(N), .FIND_MAX(1)) u_ct_max (
    .key(r_key), .xin(r_prod), .win(r_prod),
    .key_o(max_key), .x_o(max_val), .w_o(max_dummy)
  );
  comparator_tree #(.ENTRIES(N), .FIND_MAX(0)) u_ct_min (
    .key(r_key), .xin(r_prod), .win(r_prod),
    .key_o(min_key), .x_o(min_val), .w_o(min_dummy)
  );

  logic [31:0] r_max, r_min;
  always_ff @(posedge clk) begin
    r_max <= max_val;
    r_min <= min_val;
  end

  logic [31:0] p_sum;
  fp_add u_add_pp (.clk(clk), .rst_n(rst_n), .a(r_max), .b(r_min), .s(p_sum));

  logic [31:0] bias_dly [0:BIAS_LAT-1];
  integer d;
  always_ff @(posedge clk) begin
    bias_dly[0] <= bias;
    for (d = 1; d < BIAS_LAT; d++) bias_dly[d] <= bias_dly[d-1];
  end

  fp_add u_add_bias (.clk(clk), .rst_n(rst_n),
                       .a(p_sum), .b(bias_dly[BIAS_LAT-1]), .s(y));
endmodule
