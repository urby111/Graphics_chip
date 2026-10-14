# Run with Vivado 2023.1 from any directory:
# vivado -mode batch -source scripts/update_design_view.tcl
# Add -tclargs --check to also elaborate and verify the RTL hierarchy.
# This script updates the source-view project only. It never connects to hardware.
set repo [file dirname [file dirname [file normalize [info script]]]]
source [file join $repo kv260 graphics_sources.tcl]
open_project [file join $repo VGA_PROJ.xpr]

# A part is required by Vivado's RTL elaborator; no board or pin mapping is used.
set_property part xck26-sfvc784-2LV-c [current_project]
if {[get_property board_part [current_project]] ne ""} {
 set_property board_part "" [current_project]
}
foreach fileset {sources_1 constrs_1 sim_1 utils_1} {
 set old_files [get_files -quiet -of_objects [get_filesets $fileset]]
 if {[llength $old_files]} {remove_files -fileset $fileset $old_files}
}
add_files -norecurse -fileset sources_1 $kv260_graphics_sources
set_property top KV260_GPU [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
set_property top KV260_GPU [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]

# Keep the CPU sources and explanation available in the project's Utility Sources.
add_files -norecurse -fileset utils_1 [list \
 [file join $repo docs design_sources.md] \
 [file join $repo kv260 software main.c] \
 [file join $repo kv260 software display.c] \
 [file join $repo kv260 software display.h] \
 [file join $repo gpu_matrices.c]]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

if {[get_property top [get_filesets sources_1]] ne "KV260_GPU"} {
 error "Incorrect design-view top"
}
if {[get_property board_part [current_project]] ne ""} {
 error "The design view must not have a board preset"
}
if {[llength [get_files -quiet -of_objects [get_filesets constrs_1]]]} {
 error "The design view must not contain pin constraints"
}
if {[llength [get_files -of_objects [get_filesets sources_1]]] != 7} {
 error "Expected exactly seven custom graphics RTL sources"
}
if {[lsearch -exact $argv --check] >= 0} {
 synth_design -rtl -name rtl_1 -top KV260_GPU -part xck26-sfvc784-2LV-c
 foreach instance {registers engine memory engine/transform engine/projection engine/writer} {
  if {[llength [get_cells -quiet $instance]] != 1} {
   error "Missing RTL hierarchy instance: $instance"
  }
 }
 puts "PASS: current KV260 graphics RTL elaborates with registers, engine, memory and all three graphics stages."
 close_design
}
close_project
puts "PASS: VGA_PROJ.xpr is the KV260 RTL source view, with no board preset or pin constraints."
