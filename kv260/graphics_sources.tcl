# The custom graphics RTL shared by the hardware build and root design view.
# Source this file to obtain absolute paths in kv260_graphics_sources.
set kv260_source_dir [file dirname [file normalize [info script]]]
set kv260_shared_dir [file join [file dirname $kv260_source_dir] VGA_PROJ.srcs sources_1 new]
set kv260_graphics_sources [list \
 [file join $kv260_source_dir rtl KV260_GPU.v] \
 [file join $kv260_source_dir rtl kv260_regs.v] \
 [file join $kv260_source_dir rtl kv260_engine.v] \
 [file join $kv260_source_dir rtl kv260_memory.v] \
 [file join $kv260_shared_dir Matrix_Vertex.v] \
 [file join $kv260_shared_dir Screen_Position.v] \
 [file join $kv260_shared_dir Framebuffer_Write.v]]
