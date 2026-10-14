# Run with Vitis 2023.1 xsct, after create_project.tcl has exported the XSA.
set here [file dirname [file normalize [info script]]]
set repo [file dirname $here]
if {![file exists [file join $here kv260_gpu.xsa]]} {error "Build the hardware XSA first"}
setws [file join $here vitis_workspace]
if {![file exists [file join $here vitis_workspace kv260 platform.spr]]} {
 platform create -name kv260 -hw [file join $here kv260_gpu.xsa] -proc psu_cortexa53_0 -os standalone
} else {
 platform read [file join $here vitis_workspace kv260 platform.spr]
 platform config -updatehw [file join $here kv260_gpu.xsa]
}
platform active kv260
bsp config stdin psu_uart_1
bsp config stdout psu_uart_1
platform generate
if {![file exists [file join $here vitis_workspace kv260_fsbl .project]]} {
 app create -name kv260_fsbl -platform kv260 -domain standalone_domain -template {Zynq MP FSBL}
}
app build -name kv260_fsbl
file copy -force [file join $here vitis_workspace kv260_fsbl Debug kv260_fsbl.elf] [file join $here fsbl.elf]
if {![file exists [file join $here vitis_workspace kv260_test .project]]} {
 app create -name kv260_test -platform kv260 -domain standalone_domain -template {Empty Application(C)}
}
set stage [file join $here software_stage]
file mkdir $stage
foreach name {main.c display.c display.h} {
 file copy -force [file join $here software $name] [file join $stage $name]
}
file copy -force [file join $repo gpu_matrices.c] [file join $stage gpu_matrices.c]
# Included into main.c for reuse; do not compile the CLI source separately.
file rename -force [file join $stage gpu_matrices.c] [file join $stage gpu_matrices.inc]
set f [open [file join $stage main.c]];set code [read $f];close $f
set code [string map {"gpu_matrices.c" "gpu_matrices.inc"} $code]
set f [open [file join $stage main.c] w];puts -nonewline $f $code;close $f
importsources -name kv260_test -path $stage
file copy -force [file join $stage gpu_matrices.inc] [file join $here vitis_workspace kv260_test src gpu_matrices.inc]
# Keep application/stack/heap below GPU RAM, which occupies 0x10000000..0x107fffff.
set linker [file join $here vitis_workspace kv260_test src lscript.ld]
if {![file exists $linker]} {error "Vitis did not create the expected linker script"}
set f [open $linker];set ld [read $f];close $f
if {![regexp {psu_ddr_0_MEM_0\s*:\s*ORIGIN\s*=\s*0x[0-9A-Fa-f]+,\s*LENGTH\s*=\s*0x[0-9A-Fa-f]+} $ld]} {
 error "Cannot safely reserve GPU RAM in the generated linker script"
}
regsub {psu_ddr_0_MEM_0\s*:\s*ORIGIN\s*=\s*0x[0-9A-Fa-f]+,\s*LENGTH\s*=\s*0x[0-9A-Fa-f]+} $ld \
 {psu_ddr_0_MEM_0 : ORIGIN = 0x00100000, LENGTH = 0x0ff00000} ld
set f [open $linker w];puts -nonewline $f $ld;close $f
app config -name kv260_test -add libraries m
app build -name kv260_test
set elf [file join $here vitis_workspace kv260_test Debug kv260_test.elf]
if {![file exists $elf]} {error "CPU ELF was not produced"}
file copy -force $elf [file join $here kv260_test.elf]
puts "CPU executable: [file join $here kv260_test.elf]"
