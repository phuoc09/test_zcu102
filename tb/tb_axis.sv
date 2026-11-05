`timescale 1ns/1ps
// Stream test: replays pevec_n16_k<K>.hex through pe_axis as 9-beat records, with
// optional random TVALID gaps and random output TREADY stalls, and checks every Y.
module tb_axis;
  parameter int K = 4;
  parameter int GAPS = 0;       // 1: random input gaps and output back-pressure
  parameter int MAXT = 8192;
  logic clk = 0, rst_n = 0; always #2.5 clk = ~clk;
  logic [127:0] sd, md; logic sv=0, sr, sl=0, mv, mr=1, ml;
  logic [7:0] aa=0, ra=0; logic awv=0, awr, wv=0, wr, bv, br=1, arv=0, arr, rv, rr=1;
  logic [31:0] wd=0, rd; logic [1:0] bresp, rresp;
  pe_axis #(.N(16), .K(K)) dut (.aclk(clk), .aresetn(rst_n),
    .s_axis_tdata(sd), .s_axis_tvalid(sv), .s_axis_tready(sr), .s_axis_tlast(sl),
    .m_axis_tdata(md), .m_axis_tvalid(mv), .m_axis_tready(mr), .m_axis_tlast(ml),
    .s_ctl_awaddr(aa), .s_ctl_awvalid(awv), .s_ctl_awready(awr), .s_ctl_wdata(wd),
    .s_ctl_wstrb(4'hF), .s_ctl_wvalid(wv), .s_ctl_wready(wr), .s_ctl_bresp(bresp),
    .s_ctl_bvalid(bv), .s_ctl_bready(br), .s_ctl_araddr(ra), .s_ctl_arvalid(arv),
    .s_ctl_arready(arr), .s_ctl_rdata(rd), .s_ctl_rresp(rresp), .s_ctl_rvalid(rv),
    .s_ctl_rready(rr));

  logic [31:0] vx [0:MAXT-1][0:15], vw [0:MAXT-1][0:15], vb [0:MAXT-1], ey [0:MAXT-1];
  int nt=0, fd, code, i, j, err=0, got=0, firsterr=-1;
  logic [31:0] tmp, rdv;

  initial begin
    fd = $fopen($sformatf("pevec_n16_k%0d.hex", K), "r");
    if (fd==0) begin $display("FATAL no vector file"); $finish; end
    forever begin
      for (j=0;j<16;j++) begin code=$fscanf(fd,"%h",tmp); if (code!=1) break; vx[nt][j]=tmp; end
      if (code!=1) break;
      for (j=0;j<16;j++) begin code=$fscanf(fd,"%h",tmp); vw[nt][j]=tmp; end
      code=$fscanf(fd,"%h",tmp); vb[nt]=tmp;
      code=$fscanf(fd,"%h",tmp); ey[nt]=tmp;
      nt++; if (nt==MAXT) break;
    end
    nt = (nt/4)*4;
    $display("loaded %0d vectors", nt);
    repeat (5) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);
    @(negedge clk);
    for (i=0;i<nt;i++) for (j=0;j<9;j++) begin
      if (GAPS && ($urandom%4==0)) begin sv=0; repeat ($urandom%5+1) @(negedge clk); end
      sv=1;
      sd = '0;
      if (j<4)      for (int q=0;q<4;q++) sd[32*q+:32]=vx[i][j*4+q];
      else if (j<8) for (int q=0;q<4;q++) sd[32*q+:32]=vw[i][(j-4)*4+q];
      else          sd[31:0]=vb[i];
      sl = (i==nt-1) && (j==8);
      do @(posedge clk); while (!sr);
      @(negedge clk);
    end
    sv=0; sl=0;
  end

  // output side
  always @(negedge clk) if (GAPS) mr <= ($urandom%3 != 0);
  int idx=0;
  always @(posedge clk) if (mv && mr) begin
    for (int q=0;q<4;q++) begin
      if (md[32*q+:32] !== ey[idx]) begin err++; if (firsterr<0) firsterr=idx;
        if (err<5) $display("MISMATCH %0d got %h exp %h", idx, md[32*q+:32], ey[idx]); end
      idx++;
    end
    if (ml) begin
      $display("last at idx=%0d (nt=%0d)", idx, nt);
      @(posedge clk);
      axi_rd(8'h00); $display("CYCLES=%0d", rdv);
      axi_rd(8'h04); $display("VECS=%0d", rdv);
      axi_rd(8'h0C); $display("STALL_IN=%0d", rdv);
      axi_rd(8'h14); $display("STARVE=%0d", rdv);
      $display("K=%0d GAPS=%0d %s errors=%0d vectors=%0d", K, GAPS, (err==0 && idx==nt)?"AXIS PASS":"AXIS FAIL", err, idx);
      $finish;
    end
  end
  task automatic axi_rd(input [7:0] a);
    @(negedge clk); ra=a; arv=1; do @(posedge clk); while(!arr); @(negedge clk); arv=0;
    while(!rv) @(posedge clk); #0.1; rdv = rd; @(posedge clk);
  endtask
  initial begin #(5000000); $display("TIMEOUT"); $finish; end
endmodule
