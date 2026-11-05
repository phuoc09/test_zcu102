# ZCU102 block design: PS DDR -> AXI DMA (MM2S) -> pe_axis -> AXI DMA (S2MM) -> PS DDR.
# usage: vivado -mode batch -source build_bd_dma.tcl -tclargs <K>
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set rtl_pe [file normalize $root/pe_rtl]
set proj_dir [file normalize $root/vivado/dma_k$k]
set part xczu9eg-ffvb1156-2-e

create_project dma_k$k $proj_dir -part $part -force
set_property board_part xilinx.com:zcu102:part0:3.4 [current_project]
add_files -norecurse [glob $rtl_pe/*.sv]
add_files -norecurse $root/rtl/pe_axis.sv
add_files -norecurse $root/rtl/pe_axis_bd_k$k.v
add_files -fileset constrs_1 -norecurse $root/constraints/zcu102_hil.xdc
update_compile_order -fileset sources_1

create_bd_design dma
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
] $ps

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps]
set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
set_property -dict [list CONFIG.PRIM_IN_FREQ {300.000} \
  CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.USE_LOCKED {true} CONFIG.USE_RESET {false}] $cw
create_bd_port -dir I -type clk -freq_hz 300000000 sysclk_p
create_bd_port -dir I -type clk -freq_hz 300000000 sysclk_n
connect_bd_net [get_bd_ports sysclk_p] [get_bd_pins clk_wiz_0/clk_in1_p]
connect_bd_net [get_bd_ports sysclk_n] [get_bd_pins clk_wiz_0/clk_in1_n]

# No scatter-gather: one simple transfer covers the whole buffer (26-bit length).
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
  CONFIG.c_include_sg {0} \
  CONFIG.c_sg_include_stscntrl_strm {0} \
  CONFIG.c_include_mm2s {1} CONFIG.c_include_s2mm {1} \
  CONFIG.c_m_axi_mm2s_data_width {128} CONFIG.c_m_axis_mm2s_tdata_width {128} \
  CONFIG.c_m_axi_s2mm_data_width {128} CONFIG.c_s_axis_s2mm_tdata_width {128} \
  CONFIG.c_mm2s_burst_size {256} CONFIG.c_s2mm_burst_size {256} \
  CONFIG.c_sg_length_width {26} CONFIG.c_addr_width {40} \
] $dma

set pe [create_bd_cell -type module -reference pe_axis_bd_k$k pe]

set ic_c [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ic_ctl]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $ic_c
set ic_d [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ic_dat]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $ic_d

connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins ic_ctl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_ctl/M00_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ic_ctl/M01_AXI] [get_bd_intf_pins pe/s_ctl]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins ic_dat/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins ic_dat/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_dat/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins pe/s_axis]
connect_bd_intf_net [get_bd_intf_pins pe/m_axis] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

set clk [get_bd_pins clk_wiz_0/clk_out1]
connect_bd_net $clk [get_bd_pins rst_ps/slowest_sync_clk] \
  [get_bd_pins ic_ctl/ACLK] [get_bd_pins ic_ctl/S00_ACLK] [get_bd_pins ic_ctl/M00_ACLK] [get_bd_pins ic_ctl/M01_ACLK] \
  [get_bd_pins ic_dat/ACLK] [get_bd_pins ic_dat/S00_ACLK] [get_bd_pins ic_dat/S01_ACLK] [get_bd_pins ic_dat/M00_ACLK] \
  [get_bd_pins axi_dma_0/s_axi_lite_aclk] [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
  [get_bd_pins pe/aclk] \
  [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins rst_ps/ext_reset_in] [get_bd_pins rst_ps/dcm_locked]
set rn [get_bd_pins rst_ps/peripheral_aresetn]
connect_bd_net $rn [get_bd_pins ic_ctl/ARESETN] [get_bd_pins ic_ctl/S00_ARESETN] [get_bd_pins ic_ctl/M00_ARESETN] [get_bd_pins ic_ctl/M01_ARESETN] \
  [get_bd_pins ic_dat/ARESETN] [get_bd_pins ic_dat/S00_ARESETN] [get_bd_pins ic_dat/S01_ARESETN] [get_bd_pins ic_dat/M00_ARESETN] \
  [get_bd_pins axi_dma_0/axi_resetn] [get_bd_pins pe/aresetn]

assign_bd_address -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  -offset 0xA0000000 -range 64K [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg] -force
assign_bd_address -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  -offset 0xA0010000 -range 4K [get_bd_addr_segs pe/s_ctl/*] -force
assign_bd_address -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW] -force
assign_bd_address -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW] -force

validate_bd_design
save_bd_design
set wrapper [make_wrapper -files [get_files dma.bd] -top]
add_files -norecurse $wrapper
set_property top dma_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "BD_DONE k=$k wrapper=$wrapper"
