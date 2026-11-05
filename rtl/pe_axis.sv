// AXI4-Stream front-end for the HIMAM/MAM PE, fed by AXI DMA.
//
// Input record (one vector) = 9 beats of 128 bit = 36 words:
//   beat 0..3 : X[0..15]   (4 words per beat, word 0 in TDATA[31:0])
//   beat 4..7 : W[0..15]
//   beat 8    : word 0 = BIAS, words 1..3 = padding
// Output: four 32-bit Y words packed per 128-bit beat (vector 4j in [31:0]).
// TLAST on the last input beat of the final record is forwarded to the output beat that
// carries that vector (the count must be a multiple of 4).
//
// pe_top is a free-running pipeline (latency 8, no valid) and a record takes 9 beats, so
// at most one vector is in flight; input is back-pressured only while a packed output beat
// is still waiting for the DMA.  Wrapper counters (AXI4-Lite, see below) separate
// PE-bound from stream-bound behaviour.
//
// Stats register map (AXI4-Lite, 32-bit):
//   0x00 CYCLES    clocks from first accepted input beat to last output beat (cleared by 0x10)
//   0x04 VECS      vectors completed
//   0x08 K         ranking key compiled in
//   0x0C STALL_IN  clocks with TVALID=1 and TREADY=0 on the input stream
//   0x10 CLEAR     write anything
//   0x14 STARVE    clocks while running with TVALID=0 on the input (DMA not supplying)
module pe_axis #(
  parameter int N      = 16,
  parameter int DESIGN = 0,
  parameter int K      = 4,
  parameter int LAT    = 8          // pe_top latency in clocks
) (
  input  logic         aclk,
  input  logic         aresetn,

  input  logic [127:0] s_axis_tdata,
  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,
  input  logic         s_axis_tlast,

  output logic [127:0] m_axis_tdata,
  output logic         m_axis_tvalid,
  input  logic         m_axis_tready,
  output logic         m_axis_tlast,

  input  logic [7:0]   s_ctl_awaddr,
  input  logic         s_ctl_awvalid,
  output logic         s_ctl_awready,
  input  logic [31:0]  s_ctl_wdata,
  input  logic [3:0]   s_ctl_wstrb,
  input  logic         s_ctl_wvalid,
  output logic         s_ctl_wready,
  output logic [1:0]   s_ctl_bresp,
  output logic         s_ctl_bvalid,
  input  logic         s_ctl_bready,
  input  logic [7:0]   s_ctl_araddr,
  input  logic         s_ctl_arvalid,
  output logic         s_ctl_arready,
  output logic [31:0]  s_ctl_rdata,
  output logic [1:0]   s_ctl_rresp,
  output logic         s_ctl_rvalid,
  input  logic         s_ctl_rready
);
  localparam int NB = 2*N/4 + 1;                 // 9 beats per record

  logic [N-1:0][31:0] x_q, w_q;
  logic [31:0]        bias_q;
  logic [3:0]         beat;
  logic               hold_v;                    // packed output beat waiting for the DMA
  logic               in_fire;
  logic               last_rec_q;                // current record carries TLAST

  assign s_axis_tready = (beat != NB-1) || !hold_v;
  assign in_fire       = s_axis_tvalid && s_axis_tready;

  // PE operands: registered words + the bias beat straight from the stream, so the PE
  // sees stable inputs from the clock after the last beat.
  logic [N*32-1:0] x_flat, w_flat;
  logic [31:0]     bias_in, pe_y;
  logic [N*32-1:0] x_run, w_run;
  logic [31:0]     bias_run;
  logic            pe_go;

  always_comb begin
    for (int i = 0; i < N; i++) begin
      x_flat[i*32 +: 32] = x_q[i];
      w_flat[i*32 +: 32] = w_q[i];
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      beat <= '0; pe_go <= 1'b0; last_rec_q <= 1'b0;
      x_run <= '0; w_run <= '0; bias_run <= '0;
    end else begin
      pe_go <= 1'b0;
      if (in_fire) begin
        if (beat < 4) begin
          for (int j = 0; j < 4; j++) x_q[beat*4 + j] <= s_axis_tdata[32*j +: 32];
        end else if (beat < 8) begin
          for (int j = 0; j < 4; j++) w_q[(beat-4)*4 + j] <= s_axis_tdata[32*j +: 32];
        end else begin
          bias_q <= s_axis_tdata[31:0];
        end
        if (beat == NB-1) begin
          beat       <= '0;
          x_run      <= x_flat;
          w_run      <= w_flat;
          bias_run   <= s_axis_tdata[31:0];
          pe_go      <= 1'b1;
          last_rec_q <= s_axis_tlast;
        end else begin
          beat <= beat + 1'b1;
        end
      end
    end
  end

  pe_top #(.N(N), .DESIGN(DESIGN), .K(K)) u_pe (
    .clk(aclk), .rst_n(aresetn), .fp16(1'b0),
    .x_flat(x_run), .w_flat(w_run), .bias(bias_run), .y(pe_y)
  );

  // Valid / last follow the pipeline (pe_go is the cycle x_run is loaded; y appears LAT later).
  logic [LAT:0] vpipe, lpipe;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin vpipe <= '0; lpipe <= '0; end
    else begin
      vpipe <= {vpipe[LAT-1:0], pe_go};
      lpipe <= {lpipe[LAT-1:0], pe_go & last_rec_q};
    end
  end
  wire y_v = vpipe[LAT];
  wire y_l = lpipe[LAT];

  // Pack four Y per output beat.
  logic [1:0]   pk;
  logic [127:0] pk_data, nxt;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      pk <= '0; hold_v <= 1'b0; m_axis_tdata <= '0; m_axis_tlast <= 1'b0; pk_data <= '0;
    end else begin
      if (hold_v && m_axis_tready) hold_v <= 1'b0;
      if (y_v) begin
        pk_data[32*pk +: 32] <= pe_y;
        pk <= pk + 1'b1;
        if (pk == 2'd3 || y_l) begin
          nxt = pk_data; nxt[32*pk +: 32] = pe_y;
          m_axis_tdata <= nxt;
          m_axis_tlast <= y_l;
          hold_v       <= 1'b1;
          pk           <= '0;
        end
      end
    end
  end
  assign m_axis_tvalid = hold_v;

  // ---------------------------------------------------------------- stats --
  logic        running;
  logic [31:0] cyc, vecs, stall_in, starve;
  logic        clr;
  always_ff @(posedge aclk) begin
    if (!aresetn || clr) begin
      running <= 1'b0; cyc <= '0; vecs <= '0; stall_in <= '0; starve <= '0;
    end else begin
      if (in_fire) running <= 1'b1;
      if (running) begin
        if (!(m_axis_tvalid && m_axis_tready && m_axis_tlast)) cyc <= cyc + 1'b1;
        if (s_axis_tvalid && !s_axis_tready) stall_in <= stall_in + 1'b1;
        if (!s_axis_tvalid) starve <= starve + 1'b1;
      end
      if (m_axis_tvalid && m_axis_tready && m_axis_tlast) running <= 1'b0;
      if (y_v) vecs <= vecs + 1'b1;
    end
  end

  // Simple one-outstanding AXI4-Lite slave.
  logic aw_h, w_h, b_v, r_v; logic [7:0] aw_a; logic [31:0] w_d, r_d;
  assign s_ctl_awready = !aw_h;
  assign s_ctl_wready  = !w_h;
  assign s_ctl_bvalid  = b_v;  assign s_ctl_bresp = 2'b00;
  assign s_ctl_arready = !r_v;
  assign s_ctl_rvalid  = r_v;  assign s_ctl_rresp = 2'b00; assign s_ctl_rdata = r_d;
  assign clr = aw_h && w_h && !b_v && (aw_a == 8'h10);
  always_ff @(posedge aclk) begin
    if (!aresetn) begin aw_h<=0; w_h<=0; b_v<=0; r_v<=0; aw_a<=0; w_d<=0; r_d<=0; end
    else begin
      if (s_ctl_awvalid && s_ctl_awready) begin aw_h <= 1; aw_a <= s_ctl_awaddr; end
      if (s_ctl_wvalid  && s_ctl_wready)  begin w_h  <= 1; w_d  <= s_ctl_wdata;  end
      if (aw_h && w_h && !b_v) begin aw_h <= 0; w_h <= 0; b_v <= 1; end
      if (b_v && s_ctl_bready) b_v <= 0;
      if (s_ctl_arvalid && s_ctl_arready) begin
        r_v <= 1;
        case (s_ctl_araddr)
          8'h00: r_d <= cyc;
          8'h04: r_d <= vecs;
          8'h08: r_d <= K;
          8'h0C: r_d <= stall_in;
          8'h14: r_d <= starve;
          default: r_d <= 32'hDEADBEEF;
        endcase
      end
      if (r_v && s_ctl_rready) r_v <= 0;
    end
  end
endmodule
