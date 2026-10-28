// AXI4-Lite register front-end for the HIMAM/MAM processing element.
//
// One vector = N activations + N weights + bias.  Software writes them into
// the register file, pulses START, polls DONE, reads Y.  The PE itself is the
// exact RTL used for the area/power/SIM results (pe_top), so whatever the
// hardware returns is bit-identical to the model the testbench checked.
//
// Register map (byte offsets, 32-bit registers):
//   0x000 + 4*i  X[i]        i = 0 .. N-1
//   0x100 + 4*i  W[i]        i = 0 .. N-1
//   0x200        BIAS
//   0x204        CTRL        bit0 = START (also clears DONE), bit1 = clear DONE
//   0x208        STATUS      bit0 = DONE, bit1 = BUSY, bit2 = SW trigger seen
//   0x20C        Y
//   0x210        N (RO)
//   0x214        K (RO)      0 = original ALM, 4/6/8 = LUT-ranking
//   0x218        WAIT_CYCLES (RO)
//   0x21C        VEC_DONE    increments on every completed vector
//   0x220        SCRATCH     read/write, used to prove the AXI path
//   0x224        SWTRIG      write 1 -> one-cycle ILA trigger pulse
module pe_axi_lite #(
  parameter int N           = 16,
  parameter int DESIGN      = 0,     // 0 = himam_sp
  parameter int K           = 4,     // ranking key
  parameter int WAIT_CYCLES = 12,    // >= PE latency (8); see README
  parameter int ADDR_W      = 40
) (
  input  logic                s_axi_aclk,
  input  logic                s_axi_aresetn,

  input  logic [ADDR_W-1:0]   s_axi_awaddr,
  input  logic [2:0]          s_axi_awprot,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,
  input  logic [31:0]         s_axi_wdata,
  input  logic [3:0]          s_axi_wstrb,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready,
  input  logic [ADDR_W-1:0]   s_axi_araddr,
  input  logic [2:0]          s_axi_arprot,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,
  output logic [31:0]         s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready,

  // Hierarchical debug pins, consumed by the ILA (not part of the AXI bus).
  output logic [N*32-1:0]     dbg_x_flat,
  output logic [N*32-1:0]     dbg_w_flat,
  output logic [31:0]         dbg_bias,
  output logic [31:0]         dbg_y,
  output logic                dbg_start,
  output logic                dbg_done,
  output logic                dbg_swtrig
);

  localparam int LAT = WAIT_CYCLES;

  localparam logic [11:0] X_BASE   = 12'h000;
  localparam logic [11:0] W_BASE   = 12'h100;
  localparam logic [11:0] A_BIAS   = 12'h200;
  localparam logic [11:0] A_CTRL   = 12'h204;
  localparam logic [11:0] A_STATUS = 12'h208;
  localparam logic [11:0] A_Y      = 12'h20C;
  localparam logic [11:0] A_N      = 12'h210;
  localparam logic [11:0] A_K      = 12'h214;
  localparam logic [11:0] A_WAIT   = 12'h218;
  localparam logic [11:0] A_VEC    = 12'h21C;
  localparam logic [11:0] A_SCR    = 12'h220;
  localparam logic [11:0] A_TRIG   = 12'h224;

  // ---------------------------------------------------------------- state --
  logic [N-1:0][31:0] x_reg, w_reg;
  logic [31:0]        bias_reg, scratch_reg;
  logic [N-1:0][31:0] x_run, w_run;
  logic [31:0]        bias_run, y_reg, vec_done;
  logic               done, busy, start_pulse, sw_pulse;
  logic [7:0]         lat_cnt;

  logic [N*32-1:0]    x_flat, w_flat;
  logic [31:0]        pe_y;

  always_comb begin
    for (int i = 0; i < N; i++) begin
      x_flat[i*32 +: 32] = x_run[i];
      w_flat[i*32 +: 32] = w_run[i];
    end
  end

  pe_top #(.N(N), .DESIGN(DESIGN), .K(K)) u_pe (
    .clk    (s_axi_aclk),
    .rst_n  (s_axi_aresetn),
    .fp16   (1'b0),
    .x_flat (x_flat),
    .w_flat (w_flat),
    .bias   (bias_run),
    .y      (pe_y)
  );

  // ------------------------------------------------------------ AXI writes --
  logic                aw_have, w_have;
  logic [ADDR_W-1:0]   awaddr_q;
  logic [31:0]         wdata_q;
  logic [3:0]          wstrb_q;
  logic                bvalid_q;
  logic [11:0]         wr_addr;

  assign wr_addr = awaddr_q[11:0];

  assign s_axi_awready = !aw_have;
  assign s_axi_wready  = !w_have;
  assign s_axi_bvalid  = bvalid_q;
  assign s_axi_bresp   = 2'b00;

  function automatic logic [31:0] merge_bytes(
    input logic [31:0] old_v,
    input logic [31:0] new_v,
    input logic [3:0]  strb
  );
    logic [31:0] r;
    for (int b = 0; b < 4; b++)
      r[8*b +: 8] = strb[b] ? new_v[8*b +: 8] : old_v[8*b +: 8];
    return r;
  endfunction

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      aw_have     <= 1'b0;
      w_have      <= 1'b0;
      awaddr_q    <= '0;
      wdata_q     <= '0;
      wstrb_q     <= '0;
      bvalid_q    <= 1'b0;

      x_reg       <= '0;
      w_reg       <= '0;
      bias_reg    <= '0;
      scratch_reg <= '0;
      x_run       <= '0;
      w_run       <= '0;
      bias_run    <= '0;
      y_reg       <= '0;
      vec_done    <= '0;
      done        <= 1'b0;
      busy        <= 1'b0;
      start_pulse <= 1'b0;
      sw_pulse    <= 1'b0;
      lat_cnt     <= '0;
    end else begin
      start_pulse <= 1'b0;
      sw_pulse    <= 1'b0;

      if (s_axi_awvalid && s_axi_awready) begin
        aw_have  <= 1'b1;
        awaddr_q <= s_axi_awaddr;
      end
      if (s_axi_wvalid && s_axi_wready) begin
        w_have  <= 1'b1;
        wdata_q <= s_axi_wdata;
        wstrb_q <= s_axi_wstrb;
      end

      // One write completes when both halves have arrived and the previous
      // response has been accepted.  BRESP is always OKAY.
      if (aw_have && w_have && !bvalid_q) begin
        aw_have  <= 1'b0;
        w_have   <= 1'b0;
        bvalid_q <= 1'b1;

        if (wr_addr >= X_BASE && wr_addr < X_BASE + 4*N) begin
          x_reg[wr_addr[7:2]] <= merge_bytes(x_reg[wr_addr[7:2]], wdata_q, wstrb_q);
        end else if (wr_addr >= W_BASE && wr_addr < W_BASE + 4*N) begin
          w_reg[wr_addr[7:2]] <= merge_bytes(w_reg[wr_addr[7:2]], wdata_q, wstrb_q);
        end else begin
          case (wr_addr)
            A_BIAS: begin
              bias_reg <= merge_bytes(bias_reg, wdata_q, wstrb_q);
            end
            A_CTRL: begin
              if (wdata_q[1]) done <= 1'b0;
              if (wdata_q[0] && !busy) begin
                // Freeze the operands for the whole PE latency; software may
                // start loading the next vector as soon as DONE is seen.
                x_run       <= x_reg;
                w_run       <= w_reg;
                bias_run    <= bias_reg;
                busy        <= 1'b1;
                done        <= 1'b0;
                lat_cnt     <= LAT[7:0];
                start_pulse <= 1'b1;
              end
            end
            A_SCR: begin
              scratch_reg <= merge_bytes(scratch_reg, wdata_q, wstrb_q);
            end
            A_TRIG: begin
              if (wdata_q[0]) sw_pulse <= 1'b1;
            end
            default: ; // writes to RO / unmapped registers are ignored
          endcase
        end
      end

      if (bvalid_q && s_axi_bready) bvalid_q <= 1'b0;

      // PE result collection.  lat_cnt is armed to WAIT_CYCLES on START and
      // counts down; WAIT_CYCLES >= the 8-cycle PE latency, so y_reg always
      // captures a settled output.
      if (busy) begin
        if (lat_cnt == 8'd0) begin
          busy     <= 1'b0;
          done     <= 1'b1;
          y_reg    <= pe_y;
          vec_done <= vec_done + 32'd1;
        end else begin
          lat_cnt <= lat_cnt - 8'd1;
        end
      end
    end
  end

  // ------------------------------------------------------------- AXI reads --
  logic              rvalid_q;
  logic [31:0]       rdata_q;
  logic [ADDR_W-1:0] araddr_q;

  assign s_axi_arready = !rvalid_q;
  assign s_axi_rvalid  = rvalid_q;
  assign s_axi_rdata   = rdata_q;
  assign s_axi_rresp   = 2'b00;

  function automatic logic [31:0] read_mux(input logic [11:0] a);
    logic [31:0] r;
    r = 32'h0;
    if (a >= X_BASE && a < X_BASE + 4*N)
      r = x_reg[a[7:2]];
    else if (a >= W_BASE && a < W_BASE + 4*N)
      r = w_reg[a[7:2]];
    else begin
      case (a)
        A_BIAS:   r = bias_reg;
        A_CTRL:   r = {30'b0, busy, done};
        A_STATUS: r = {29'b0, sw_pulse, busy, done};
        A_Y:      r = y_reg;
        A_N:      r = N[31:0];
        A_K:      r = K[31:0];
        A_WAIT:   r = LAT[31:0];
        A_VEC:    r = vec_done;
        A_SCR:    r = scratch_reg;
        A_TRIG:   r = 32'h0;
        default:  r = 32'h0;
      endcase
    end
    return r;
  endfunction

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
      araddr_q <= '0;
    end else begin
      if (s_axi_arvalid && s_axi_arready) begin
        araddr_q <= s_axi_araddr;
        rdata_q  <= read_mux(s_axi_araddr[11:0]);
        rvalid_q <= 1'b1;
      end else if (rvalid_q && s_axi_rready) begin
        rvalid_q <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------ debug --
  assign dbg_x_flat = x_flat;
  assign dbg_w_flat = w_flat;
  assign dbg_bias   = bias_run;
  assign dbg_y      = pe_y;
  assign dbg_start  = start_pulse;
  assign dbg_done   = done;
  assign dbg_swtrig = sw_pulse;

endmodule
