# Standalone synthesis only. No pipeline, board programming or bitstream build.
set root [file dirname [file dirname [file normalize [info script]]]]
set out [file join $root verilator rasterizers]
file mkdir $out
foreach module {Line_Draw Triangle_Fill} {
    create_project -in_memory -part xck26-sfvc784-2LV-c
    read_verilog [file join $root VGA_PROJ.srcs sources_1 new ${module}.v]
    synth_design -top $module -mode out_of_context -part xck26-sfvc784-2LV-c
    report_utilization -file [file join $out ${module}_utilization.rpt]
    write_checkpoint -force [file join $out ${module}_synth.dcp]
    close_project
}
puts "Standalone line and triangle modules synthesized successfully."
exit
