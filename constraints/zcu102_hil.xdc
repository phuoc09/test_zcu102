# ZCU102 (xczu9eg-ffvb1156-2-e) -- HIL board constraints.
# 300 MHz Silicon Labs SI570 user-programmable differential clock (board part
# 3.4 interface "user_si570_sysclk"): AL8/AL7, DIFF_SSTL12.  The G21/F21
# "sysclk" pins sit in a high-density bank and cannot drive the MMCM (DRC
# PLHDIO-4), so they are not used.
set_property PACKAGE_PIN AL8 [get_ports sysclk_p]
set_property PACKAGE_PIN AL7 [get_ports sysclk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {sysclk_p sysclk_n}]
create_clock -period 3.333 -name sysclk_p [get_ports sysclk_p]
