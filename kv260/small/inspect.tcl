# Read-only checks while the CPU continues displaying the frame.
connect
targets -set -filter {name =~ "PSU"}
configparams force-mem-accesses 1
puts "CPU_PROGRESS: [mrd -value 0x0ff00000 9]"
puts "DMA_ISR: [mrd -value 0xfd4c0004]"
puts "DMA_EISR: [mrd -value 0xfd4c0014]"
puts "DMA_GFX_CONTROL_STATUS: [mrd -value 0xfd4c0518 2]"
disconnect
