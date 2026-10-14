# Temporary RAM/JTAG test. Does not write QSPI flash or SD.
# Requires the KV260 12 V supply and USB JTAG/UART cable.
set here [file dirname [file normalize [info script]]]
foreach artifact {kv260_gpu.bit kv260_gpu.xsa kv260_test.elf fsbl.elf} {
 if {![file exists [file join $here $artifact]]} {error "Missing $artifact; finish the builds first"}
}
connect
targets -set -filter {name =~ "Cortex-A53 #0"}
catch {stop} ;# A previous diagnostic may have left the APU held in reset.
# Reset for a standalone session; do not use this against an active Linux system.
targets -set -filter {name =~ "PSU"}
# Select JTAG for this warm reset only. No persistent boot setting is changed.
mwr 0xFF5E0200 0x0100
rst -system
after 2000
targets -set -filter {name =~ "PSU"}
# Enable access to PMU registers before loading a generated FSBL.
mask_write 0xFFCA0038 0x1FF 0x1FF
if {![file exists [file join $here fsbl.elf]]} {
 error "Missing fsbl.elf. Build a Zynq MP FSBL from the same XSA in Vitis and place it in kv260/."
}
targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor -clear-registers
dow [file join $here fsbl.elf]
set exit_breakpoint [bpadd -addr &XFsbl_Exit]
con -block -timeout 30
bpremove $exit_breakpoint
targets -set -filter {name =~ "PL"}
fpga -file [file join $here kv260_gpu.bit]
targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor -clear-registers
dow [file join $here kv260_test.elf]
con
puts "CPU program running. Read UART at 115200 baud and check HDMI."
disconnect
