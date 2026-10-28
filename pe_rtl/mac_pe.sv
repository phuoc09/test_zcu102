// Baseline conventional MAC neuron: N accurate FP multipliers feeding a
// registered adder tree. Area and power scale linearly with N, which is the
// behaviour HIMAM's Fig. 4 is measured against.
module mac_pe #(
  parameter int N = 4
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic [N-1:0][31:0] x,
  input  logic [N-1:0][31:0] w,
  input  logic [31:0]        bias,
  output logic [31:0]        y
);
  localparam int LEVELS   = $clog2(N);
  localparam int BIAS_LAT = 2 + 2 * LEVELS;   // multiplier + one adder per level

  logic [N-1:0][31:0] prod;
  logic [31:0] node [0:LEVELS][0:N-1];

  genvar i, lv;
  generate
    for (i = 0; i < N; i++) begin : g_mul
      fp_mul u_mul (.clk(clk), .rst_n(rst_n), .a(x[i]), .b(w[i]), .p(prod[i]));
      assign node[0][i] = prod[i];
    end

    for (lv = 0; lv < LEVELS; lv++) begin : g_lvl
      localparam int HALF = (N >> lv) / 2;
      for (i = 0; i < HALF; i++) begin : g_add
        fp_add u_add (.clk(clk), .rst_n(rst_n),
                        .a(node[lv][2*i]), .b(node[lv][2*i+1]),
                        .s(node[lv+1][i]));
      end
    end
  endgenerate

  logic [31:0] bias_dly [0:BIAS_LAT-1];
  integer d;
  always_ff @(posedge clk) begin
    bias_dly[0] <= bias;
    for (d = 1; d < BIAS_LAT; d++) bias_dly[d] <= bias_dly[d-1];
  end

  fp_add u_add_bias (.clk(clk), .rst_n(rst_n),
                       .a(node[LEVELS][0]), .b(bias_dly[BIAS_LAT-1]), .s(y));
endmodule
