# No Vitis or FSBL: initialize PS through generated Tcl, then load freestanding ELF.
set kv [file dirname [file dirname [file normalize [info script]]]]
set init [file join $kv build kv260_gpu.gen sources_1 bd system ip system_ps_0 psu_init.tcl]
foreach file [list $init [file join $kv kv260_gpu.bit] [file join $kv kv260_test.elf]] {
 if {![file exists $file]} {error "Missing $file"}
}
connect
targets -set -filter {name =~ "Cortex-A53 #0"}
catch {stop}
targets -set -filter {name =~ "PSU"}
mwr 0xff5e0200 0x0100
rst -system
after 2000
targets -set -filter {name =~ "PSU"}
mask_write 0xffca0038 0x1ff 0x1ff
source $init
psu_init
targets -set -filter {name =~ "PL"}
fpga -file [file join $kv kv260_gpu.bit]
targets -set -filter {name =~ "PSU"}
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config
configparams force-mem-accesses 1
mwr 0x0ff00000 0 16
targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor -clear-registers
dow [file join $kv kv260_test.elf]
con
after 15000
puts "CPU_REPORT: [mrd -value 0x0ff00000 16]"
puts "CPU_MATRIX: [mrd -value 0x10000000 16]"
puts "GPU_STATUS: [mrd -value 0xa0000004]"
set cpu_stage [lindex [mrd -value 0x0ff00004] 0]
if {$cpu_stage!=6} {error "CPU rendering/display setup stopped at report stage $cpu_stage; see CPU_REPORT above."}
puts "CPU executable started. Check HDMI; UART is normally COM15 at 115200 baud."
disconnect
