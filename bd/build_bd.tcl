# Build the ZCU102 block design for one HIMAM HIL configuration.
# usage: vivado -mode batch -source build_bd.tcl -tclargs <K>
# K = 0 (original ALM) or 4 (LUT-ranking, narrow key).  N is fixed at 16.
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set rtl_pe [file normalize $root/pe_rtl]
set proj_dir [file normalize $root/vivado/hil_k$k]
set part xczu9eg-ffvb1156-2-e

create_project hil_k$k $proj_dir -part $part -force
set_property board_part xilinx.com:zcu102:part0:3.4 [current_project]

add_files -norecurse [glob $rtl_pe/*.sv]
add_files -norecurse [glob $root/rtl/*.sv]
add_files -norecurse [glob $root/rtl/*.v]
add_files -fileset constrs_1 -norecurse $root/constraints/zcu102_hil.xdc
update_compile_order -fileset sources_1

# The BD's ILA cell forces its AXI-monitor model params (44 probes).  Create a
# plain probe ILA as a standalone IP instead and instantiate it inside the PE
# wrapper, where it sees the unfiltered PE signals.
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_pe
set ip [get_ips ila_pe]
set_property -dict [list \
  CONFIG.C_ENABLE_ILA_AXI_MON {false} \
  CONFIG.C_NUM_OF_PROBES {7} \
  CONFIG.C_DATA_DEPTH {1024} \
  CONFIG.C_PROBE0_WIDTH {1} \
  CONFIG.C_PROBE1_WIDTH {512} \
  CONFIG.C_PROBE2_WIDTH {512} \
  CONFIG.C_PROBE3_WIDTH {32} \
  CONFIG.C_PROBE4_WIDTH {32} \
  CONFIG.C_PROBE5_WIDTH {1} \
  CONFIG.C_PROBE6_WIDTH {1} \
] $ip
generate_target {instantiation_template synthesis simulation} $ip

create_bd_design hil
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
                    -config {apply_board_preset "1"} $ps
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {200} \
] $ps

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps]

# The PS PL0 clock cannot produce exactly 200 MHz from the board's 1500 MHz
# IOPLL (Vivado gives 187.5 MHz).  Use the ZCU102 300 MHz SI570 differential
# clock and an MMCM: 300 -> 1200 (VCO) -> 200 MHz exactly.  The PS HPM0 FPD
# AXI port has its own asynchronous ACLK, so it is clocked by this 200 MHz
# domain while DDR/UART stay on the PS clocks.
set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
set_property -dict [list \
  CONFIG.PRIM_IN_FREQ {300.000} \
  CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.USE_LOCKED {true} \
  CONFIG.USE_RESET {false} \
] $cw
create_bd_port -dir I -type clk -freq_hz 300000000 sysclk_p
create_bd_port -dir I -type clk -freq_hz 300000000 sysclk_n
connect_bd_net [get_bd_ports sysclk_p] [get_bd_pins clk_wiz_0/clk_in1_p]
connect_bd_net [get_bd_ports sysclk_n] [get_bd_pins clk_wiz_0/clk_in1_n]

set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ic

if {$k == 0} {
  set pe [create_bd_cell -type module -reference pe_axi_lite_bd_k0 pe]
} else {
  set pe [create_bd_cell -type module -reference pe_axi_lite_bd_k4 pe]
}

# ---- AXI ---------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
                    [get_bd_intf_pins axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] \
                    [get_bd_intf_pins pe/s_axi]

# ---- clocks / resets ---------------------------------------------------
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
               [get_bd_pins rst_ps/slowest_sync_clk] \
               [get_bd_pins axi_ic/ACLK] \
               [get_bd_pins axi_ic/S00_ACLK] \
               [get_bd_pins axi_ic/M00_ACLK] \
               [get_bd_pins pe/s_axi_aclk] \
               [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]
connect_bd_net [get_bd_pins clk_wiz_0/locked] \
               [get_bd_pins rst_ps/ext_reset_in] \
               [get_bd_pins rst_ps/dcm_locked]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn] \
               [get_bd_pins axi_ic/ARESETN] \
               [get_bd_pins axi_ic/S00_ARESETN] \
               [get_bd_pins axi_ic/M00_ARESETN] \
               [get_bd_pins pe/s_axi_aresetn]

# ---- address map -------------------------------------------------------
assign_bd_address -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
                  -offset 0xA0000000 -range 4K \
                  [get_bd_addr_segs -of_objects [get_bd_intf_pins pe/s_axi]] -force

validate_bd_design
save_bd_design

set wrapper [make_wrapper -files [get_files hil.bd] -top]
add_files -norecurse $wrapper
set_property top hil_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "BD_DONE k=$k wrapper=$wrapper"
