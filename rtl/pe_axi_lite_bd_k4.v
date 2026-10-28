// Verilog-2001 shell so Vivado's block-design "module reference" can use the
// SystemVerilog PE front-end (module reference rejects .sv top files).
// N=16, K=4 LUT-ranking.
module pe_axi_lite_bd_k4 (
  input  wire        s_axi_aclk,
  input  wire        s_axi_aresetn,
  input  wire [39:0] s_axi_awaddr,
  input  wire [2:0]  s_axi_awprot,
  input  wire        s_axi_awvalid,
  output wire        s_axi_awready,
  input  wire [31:0] s_axi_wdata,
  input  wire [3:0]  s_axi_wstrb,
  input  wire        s_axi_wvalid,
  output wire        s_axi_wready,
  output wire [1:0]  s_axi_bresp,
  output wire        s_axi_bvalid,
  input  wire        s_axi_bready,
  input  wire [39:0] s_axi_araddr,
  input  wire [2:0]  s_axi_arprot,
  input  wire        s_axi_arvalid,
  output wire        s_axi_arready,
  output wire [31:0] s_axi_rdata,
  output wire [1:0]  s_axi_rresp,
  output wire        s_axi_rvalid,
  input  wire        s_axi_rready,
  output wire [511:0] dbg_x_flat,
  output wire [511:0] dbg_w_flat,
  output wire [31:0]  dbg_bias,
  output wire [31:0]  dbg_y,
  output wire         dbg_start,
  output wire         dbg_done,
  output wire         dbg_swtrig
);
  pe_axi_lite_n16_k4 u_impl (
    .s_axi_aclk    (s_axi_aclk),
    .s_axi_aresetn (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .dbg_x_flat    (dbg_x_flat),
    .dbg_w_flat    (dbg_w_flat),
    .dbg_bias      (dbg_bias),
    .dbg_y         (dbg_y),
    .dbg_start     (dbg_start),
    .dbg_done      (dbg_done),
    .dbg_swtrig    (dbg_swtrig)
  );

  // Plain-probe ILA (standalone IP instantiated here, not a BD ILA cell).
  // 1024 x (1 + 512 + 512 + 32 + 32 + 1 + 1) bits, clocked at the 200 MHz PE clock.
  ila_pe u_ila (
    .clk    (s_axi_aclk),
    .probe0 (dbg_start),
    .probe1 (dbg_x_flat),
    .probe2 (dbg_w_flat),
    .probe3 (dbg_bias),
    .probe4 (dbg_y),
    .probe5 (dbg_done),
    .probe6 (dbg_swtrig)
  );
endmodule
