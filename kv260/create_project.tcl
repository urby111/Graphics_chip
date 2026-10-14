# Vivado 2023.1. Build the complete KV260 hardware project separately from the RTL view.
set here [file dirname [file normalize [info script]]]
set repo [file dirname $here]
set out [file join $here build]
create_project kv260_gpu $out -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
source [file join $here graphics_sources.tcl]
add_files $kv260_graphics_sources
create_bd_design system
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
# Use the board vendor's carrier preset, including UART1, DP lanes and reference clock.
set board_file [get_property FILE_NAME [get_board_parts xilinx.com:kv260_som:part0:1.4]]
set board_store [file dirname [file dirname [file dirname $board_file]]]
set carrier [file join $board_store kv260_carrier 1.3 preset.xml]
if {![file exists $carrier]} { error "Cannot find KV260 carrier preset: $carrier" }
set f [open $carrier]; set xml [read $f]; close $f
set carrier_properties [list]
foreach {entry name value} [regexp -all -inline {<user_parameter name="([^"]+)" value="([^"]+)"\s*/>} $xml] {
 # The carrier XML also contains presets for camera/I2C IP. Only PS properties belong here.
 if {[string match "CONFIG.PSU*" $name]} {lappend carrier_properties $name $value}
}
set_property -dict $carrier_properties $ps
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {0} \
 CONFIG.PSU__USE__M_AXI_GP2 {0} CONFIG.PSU__USE__S_AXI_GP2 {1} \
 CONFIG.PSU__FPGA_PL0_ENABLE {1} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100}] $ps
set gpu [create_bd_cell -type module -reference KV260_GPU gpu]
set ctl [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 control]
set mem [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 memory]
set_property CONFIG.NUM_SI 1 $ctl
set_property CONFIG.NUM_MI 1 $ctl
set_property CONFIG.NUM_SI 1 $mem
set_property CONFIG.NUM_MI 1 $mem
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 reset]
set_property CONFIG.C_EXT_RESET_HIGH 0 $rst
set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 locked]
set_property CONFIG.CONST_VAL 1 $one
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins control/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins control/M00_AXI] [get_bd_intf_pins gpu/S_AXI]
connect_bd_intf_net [get_bd_intf_pins gpu/M_AXI] [get_bd_intf_pins memory/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins memory/M00_AXI] [get_bd_intf_pins ps/S_AXI_HP0_FPD]
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins ps/maxihpm0_fpd_aclk] \
 [get_bd_pins ps/saxihp0_fpd_aclk] [get_bd_pins gpu/clk] \
 [get_bd_pins control/aclk] [get_bd_pins memory/aclk] [get_bd_pins reset/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins reset/ext_reset_in]
connect_bd_net [get_bd_pins locked/dout] [get_bd_pins reset/dcm_locked]
connect_bd_net [get_bd_pins reset/peripheral_aresetn] [get_bd_pins gpu/resetn] \
 [get_bd_pins control/aresetn] [get_bd_pins memory/aresetn]
assign_bd_address
set ctl_seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data] -filter {NAME =~ *gpu*}]
if {[llength $ctl_seg]!=1} {error "GPU control mapping is ambiguous: $ctl_seg"}
set_property offset 0xA0000000 $ctl_seg
set_property range 4K $ctl_seg
validate_bd_design
save_bd_design
generate_target all [get_files system.bd]
set wrappers [make_wrapper -files [get_files system.bd] -top]
add_files -norecurse $wrappers
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
foreach path [concat $setup_paths $hold_paths] {
 if {[get_property SLACK $path]<0} {error "Timing closure failed"}
}
report_timing_summary -file [file join $here timing_summary.rpt]
write_hw_platform -fixed -include_bit -force -file [file join $here kv260_gpu.xsa]
file copy -force [file join $out kv260_gpu.runs impl_1 system_wrapper.bit] [file join $here kv260_gpu.bit]
puts "KV260 hardware build complete."
