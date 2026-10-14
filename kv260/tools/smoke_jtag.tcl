# Diagnostic only: PC supplies three known points while the A53 is halted.
# This tests real PL/DDR before the Vitis CPU application is available.
# It does not exercise on-board CPU matrix calculation or HDMI.
set here [file dirname [file dirname [file normalize [info script]]]]
set init [file join $here build kv260_gpu.gen sources_1 bd system ip system_ps_0 psu_init.tcl]
foreach artifact [list [file join $here kv260_gpu.bit] $init] {
 if {![file exists $artifact]} {error "Missing hardware artifact $artifact"}
}
connect
targets -set -filter {name =~ "Cortex-A53 #0"}
catch {stop} ;# Core may already be held in reset after a previous JTAG session.
targets -set -filter {name =~ "PSU"}
mwr 0xFF5E0200 0x0100
rst -system
after 2000
targets -set -filter {name =~ "PSU"}
mask_write 0xFFCA0038 0x1FF 0x1FF
source $init
psu_init
targets -set -filter {name =~ "PL"}
fpga -file [file join $here kv260_gpu.bit]
targets -set -filter {name =~ "PSU"}
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config
# XSDB's default PS memory map does not include this new private PL aperture.
# DDR/PL clocks and reset have now been initialized; allow accesses to it.
set saved_access_mode [configparams force-mem-accesses]
configparams force-mem-accesses 1
proc word {addr} {return [expr [lindex [mrd -value $addr] 0]]}
if {[word 0xA0000008]!=0x4b563031} {error "GPU signature missing"}
# Focal=320, Z=W=input Z. Inputs: (-1,-1,4), (1,-1,4), (0,1,4).
set words {0x01400000 0 0 0 0 0x01400000 0 0 0 0 0x00010000 0 0 0 0x00010000 0
 0xffff0000 0xffff0000 0x00040000 0x00010000 0xffff0000 0x00040000 0 0x00010000 0x00040000}
set addr 0x10000000
foreach value $words {mwr $addr $value;incr addr 4}
# Exact addresses: buffer B + (y*640+x)*4. Initialize only the three tested pixels.
set pixels [list [expr {0x10300000+(320*640+240)*4}] \
 [expr {0x10300000+(320*640+400)*4}] [expr {0x10300000+(160*640+320)*4}]]
foreach addr $pixels {mwr $addr 0xff000000}
foreach {addr value} {0xA0000010 0x10000000 0xA0000014 0 0xA0000018 64
 0xA000001c 3 0xA0000020 65536 0xA0000024 1 0xA0000000 1} {mwr $addr $value}
set finished 0
for {set i 0} {$i<100} {incr i} {
 set status [word 0xA0000004]
 if {$status & 2} {set finished 1;break}
 after 100
}
if {!$finished || ($status & 8)} {error "GPU did not finish successfully: $status"}
if {[word 0xA0000028]!=3 || [word 0xA000002c]!=3 || [word 0xA0000030]!=0} {
 error "Unexpected hardware vertex counters"
}
foreach addr $pixels {
 set actual [word $addr]
 if {($actual & 0xffffffff)!=0xff0000ff} {error "Unexpected DDR pixel at $addr: $actual"}
}
puts "PASS: hardware DDR matrix/vertex fetch, 3 transformed points, 3 red pixel writes and DONE."
puts "CPU is not running an application; this diagnostic does not test the CPU program or HDMI."
configparams force-mem-accesses $saved_access_mode
disconnect
