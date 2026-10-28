// Uniform wrapper so all three processing elements synthesise under one top
// name with flat ports. Pure wiring: it adds no logic of its own, which keeps
// the area comparison between DESIGN variants honest.
//   DESIGN 0 = himam_sp, 1 = mac_pe, 2 = mam_pe, 3 = himam_mp
// fp16 is only meaningful for himam_mp and is left dangling for the others.
module pe_top #(
  parameter int N      = 4,
  parameter int DESIGN = 0,
  parameter int K      = 0      // himam_sp only: 0 = ALM, 2..10 = LUT-ranking
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              fp16,
  input  logic [N*32-1:0]   x_flat,
  input  logic [N*32-1:0]   w_flat,
  input  logic [31:0]       bias,
  output logic [31:0]       y
);
  logic [N-1:0][31:0] x, w;

  always_comb begin
    for (int i = 0; i < N; i++) begin
      x[i] = x_flat[i*32 +: 32];
      w[i] = w_flat[i*32 +: 32];
    end
  end

  generate
    if (DESIGN == 0) begin : g_himam
      himam_sp #(.N(N), .K(K)) u_pe (.clk(clk), .rst_n(rst_n), .x(x), .w(w), .bias(bias), .y(y));
    end else if (DESIGN == 1) begin : g_mac
      mac_pe   #(.N(N)) u_pe (.clk(clk), .rst_n(rst_n), .x(x), .w(w), .bias(bias), .y(y));
    end else if (DESIGN == 2) begin : g_mam
      mam_pe   #(.N(N)) u_pe (.clk(clk), .rst_n(rst_n), .x(x), .w(w), .bias(bias), .y(y));
    end else begin : g_himam_mp
      himam_mp #(.N(N)) u_pe (.clk(clk), .rst_n(rst_n), .fp16(fp16),
                              .x(x), .w(w), .bias(bias), .y(y));
    end
  endgenerate
endmodule
