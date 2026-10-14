ENTRY(_start)
MEMORY { DDR (rwx) : ORIGIN = 0x00100000, LENGTH = 0x00e00000 }
SECTIONS {
 .text : { KEEP(*(.text.boot)) *(.text*) } > DDR
 .rodata : { *(.rodata*) } > DDR
 .data : { *(.data*) } > DDR
 .bss (NOLOAD) : { . = ALIGN(256); _bss_start = .; *(.bss*) *(COMMON) . = ALIGN(8); _bss_end = .; } > DDR
 .stack (NOLOAD) : { . = ALIGN(16); . += 65536; _stack_top = .; } > DDR
 /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
