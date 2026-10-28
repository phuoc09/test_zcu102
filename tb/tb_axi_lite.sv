`timescale 1ns/1ps
// Bit-exact AXI4-Lite bring-up test for the HIL register front-end.
// Drives the same vectors as the PE simulation (x[0..N-1], w[0..N-1], bias,
// expected y) through AXI reads/writes and compares every output word.
//
// usage: xelab ... tb_axi_lite -generic_top "K=4"
module tb_axi_lite;
  parameter int N     = 16;
  parameter int K     = 4;
  parameter int MAXT  = 2000;

  localparam int XB = 12'h000;
  localparam int WB = 12'h100;
  localparam int BB = 12'h200;
  localparam int CB = 12'h204;
  localparam int SB = 12'h208;
  localparam int YB = 12'h20C;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [39:0] awaddr = 0;
  logic [2:0]  awprot = 0;
  logic        awvalid = 0, awready;
  logic [31:0] wdata = 0;
  logic [3:0]  wstrb = 0;
  logic        wvalid = 0, wready;
  logic [1:0]  bresp;
  logic        bvalid, bready = 0;
  logic [39:0] araddr = 0;
  logic [2:0]  arprot = 0;
  logic        arvalid = 0, arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid, rready = 0;

  logic [511:0] dbg_x, dbg_w;
  logic [31:0]  dbg_bias, dbg_y;
  logic         dbg_start, dbg_done, dbg_swtrig;

  pe_axi_lite #(.N(N), .DESIGN(0), .K(K), .WAIT_CYCLES(12), .ADDR_W(40)) dut (
    .s_axi_aclk    (clk),
    .s_axi_aresetn (rst_n),
    .s_axi_awaddr  (awaddr),
    .s_axi_awprot  (awprot),
    .s_axi_awvalid (awvalid),
    .s_axi_awready (awready),
    .s_axi_wdata   (wdata),
    .s_axi_wstrb   (wstrb),
    .s_axi_wvalid  (wvalid),
    .s_axi_wready  (wready),
    .s_axi_bresp   (bresp),
    .s_axi_bvalid  (bvalid),
    .s_axi_bready  (bready),
    .s_axi_araddr  (araddr),
    .s_axi_arprot  (arprot),
    .s_axi_arvalid (arvalid),
    .s_axi_arready (arready),
    .s_axi_rdata   (rdata),
    .s_axi_rresp   (rresp),
    .s_axi_rvalid  (rvalid),
    .s_axi_rready  (rready),
    .dbg_x_flat    (dbg_x),
    .dbg_w_flat    (dbg_w),
    .dbg_bias      (dbg_bias),
    .dbg_y         (dbg_y),
    .dbg_start     (dbg_start),
    .dbg_done      (dbg_done),
    .dbg_swtrig    (dbg_swtrig)
  );

  task automatic axi_write(input [39:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      awaddr = addr; awvalid = 1;
      wdata  = data; wstrb = 4'hF; wvalid = 1;
      do @(posedge clk); while (!(awready && wready));
      @(negedge clk);
      awvalid = 0; wvalid = 0;
      while (!bvalid) @(posedge clk);
      @(negedge clk);
      bready = 1;
      @(posedge clk);
      @(negedge clk);
      bready = 0;
    end
  endtask

  task automatic axi_read(input [39:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      araddr = addr; arvalid = 1;
      do @(posedge clk); while (!arready);
      @(negedge clk);
      arvalid = 0;
      while (!rvalid) @(posedge clk);
      @(negedge clk);
      data = rdata;
      rready = 1;
      @(posedge clk);
      @(negedge clk);
      rready = 0;
    end
  endtask

  logic [31:0] vx [0:MAXT-1][0:N-1];
  logic [31:0] vw [0:MAXT-1][0:N-1];
  logic [31:0] vb [0:MAXT-1];
  logic [31:0] ey [0:MAXT-1];
  logic [31:0] rd;
  int ntests = 0, err = 0, fd, code, i, j;

  initial begin
    fd = $fopen($sformatf("pevec_n%0d_k%0d.hex", N, K), "r");
    if (fd == 0) begin
      $display("FATAL: no vector file pevec_n%0d_k%0d.hex", N, K);
      $finish;
    end
    forever begin
      for (j = 0; j < N; j++) begin
        code = $fscanf(fd, "%h", vx[ntests][j]);
        if (code != 1) break;
      end
      if (code != 1) break;
      for (j = 0; j < N; j++) code = $fscanf(fd, "%h", vw[ntests][j]);
      code = $fscanf(fd, "%h", vb[ntests]);
      code = $fscanf(fd, "%h", ey[ntests]);
      if (code != 1) break;
      ntests++;
      if (ntests == MAXT) break;
    end
    $fclose(fd);
    if (ntests == 0) begin
      $display("FATAL: vector file empty");
      $finish;
    end

    repeat (8) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // Parameter read-back
    axi_read(40'h0000_0000 + 12'h210, rd);
    if (rd !== N) begin err++; $display("  N_PARAM got %0d exp %0d", rd, N); end
    axi_read(40'h0000_0000 + 12'h214, rd);
    if (rd !== K) begin err++; $display("  K_PARAM got %0d exp %0d", rd, K); end

    // Scratch round-trip proves the AXI path independent of the PE.
    axi_write(40'h0000_0000 + 12'h220, 32'hA5C3_3C5A);
    axi_read (40'h0000_0000 + 12'h220, rd);
    if (rd !== 32'hA5C3_3C5A) begin err++; $display("  SCRATCH got %08h", rd); end

    for (int t = 0; t < ntests; t++) begin
      for (j = 0; j < N; j++)
        axi_write(40'h0000_0000 + XB + 4*j, vx[t][j]);
      for (j = 0; j < N; j++)
        axi_write(40'h0000_0000 + WB + 4*j, vw[t][j]);
      axi_write(40'h0000_0000 + BB, vb[t]);
      axi_write(40'h0000_0000 + CB, 32'h1);

      do axi_read(40'h0000_0000 + SB, rd);
      while (!(rd & 1));

      axi_read(40'h0000_0000 + YB, rd);
      if (rd !== ey[t]) begin
        err++;
        if (err <= 8)
          $display("  y[%0d] got %08h exp %08h", t, rd, ey[t]);
      end
    end

    axi_read(40'h0000_0000 + 12'h21C, rd);
    $display("N=%0d K=%0d AXI %0d vectors, errors=%0d, vec_done=%0d",
             N, K, ntests, err, rd);
    if (err == 0 && rd == ntests)
      $display("N=%0d K=%0d AXI PASS", N, K);
    else
      $display("N=%0d K=%0d AXI FAIL", N, K);
    $finish;
  end
endmodule
