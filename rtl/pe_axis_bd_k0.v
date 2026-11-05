// Verilog shell with bus-interface attributes for IP Integrator module reference.
// N=16, HIMAM_SP, K=0.  Stream: 128-bit records (9 beats/vector), see pe_axis.sv.
module pe_axis_bd_k0 (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis:s_ctl, ASSOCIATED_RESET aresetn, FREQ_HZ 200000000" *)
  input aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input aresetn,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 s_axis TDATA" *)
  input [127:0] s_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 s_axis TVALID" *)
  input s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 s_axis TREADY" *)
  output s_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 s_axis TLAST" *)
  input s_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 m_axis TDATA" *)
  output [127:0] m_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 m_axis TVALID" *)
  output m_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 m_axis TREADY" *)
  input m_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 m_axis TLAST" *)
  output m_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl AWADDR" *)
  input [7:0] s_ctl_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl AWVALID" *)
  input s_ctl_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl AWREADY" *)
  output s_ctl_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl WDATA" *)
  input [31:0] s_ctl_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl WSTRB" *)
  input [3:0] s_ctl_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl WVALID" *)
  input s_ctl_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl WREADY" *)
  output s_ctl_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl BRESP" *)
  output [1:0] s_ctl_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl BVALID" *)
  output s_ctl_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl BREADY" *)
  input s_ctl_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl ARADDR" *)
  input [7:0] s_ctl_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl ARVALID" *)
  input s_ctl_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl ARREADY" *)
  output s_ctl_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl RDATA" *)
  output [31:0] s_ctl_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl RRESP" *)
  output [1:0] s_ctl_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl RVALID" *)
  output s_ctl_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm_rtl:1.0 s_ctl RREADY" *)
  input s_ctl_rready
);
  pe_axis #(.N(16), .DESIGN(0), .K(0)) u (.aclk(aclk),.aresetn(aresetn),.s_axis_tdata(s_axis_tdata),.s_axis_tvalid(s_axis_tvalid),.s_axis_tready(s_axis_tready),.s_axis_tlast(s_axis_tlast),.m_axis_tdata(m_axis_tdata),.m_axis_tvalid(m_axis_tvalid),.m_axis_tready(m_axis_tready),.m_axis_tlast(m_axis_tlast),.s_ctl_awaddr(s_ctl_awaddr),.s_ctl_awvalid(s_ctl_awvalid),.s_ctl_awready(s_ctl_awready),.s_ctl_wdata(s_ctl_wdata),.s_ctl_wstrb(s_ctl_wstrb),.s_ctl_wvalid(s_ctl_wvalid),.s_ctl_wready(s_ctl_wready),.s_ctl_bresp(s_ctl_bresp),.s_ctl_bvalid(s_ctl_bvalid),.s_ctl_bready(s_ctl_bready),.s_ctl_araddr(s_ctl_araddr),.s_ctl_arvalid(s_ctl_arvalid),.s_ctl_arready(s_ctl_arready),.s_ctl_rdata(s_ctl_rdata),.s_ctl_rresp(s_ctl_rresp),.s_ctl_rvalid(s_ctl_rvalid),.s_ctl_rready(s_ctl_rready));
endmodule
