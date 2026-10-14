# Current KV260 design and source guide

The KV260 is the hardware target. The original VGA/font top was an earlier
milestone; it is not the custom graphics top used by the current board build.

## What to open in Vivado

**Open `VGA_PROJ.xpr` to read and edit the graphics design.** Its top is
`KV260_GPU`, and it references the same seven source files used by the board
build. No source copies are made. There is no board preset or pin constraint
file in this project; Vivado's K26 device selection is needed for RTL analysis.

Choose **RTL Analysis > Open Elaborated Design**, then open the schematic or
expand the Design Sources hierarchy:

```text
KV260_GPU                         kv260/rtl/KV260_GPU.v
  registers: kv260_regs           kv260/rtl/kv260_regs.v
  engine: kv260_engine            kv260/rtl/kv260_engine.v
    transform: Matrix_Vertex     VGA_PROJ.srcs/sources_1/new/Matrix_Vertex.v
    projection: Screen_Position  VGA_PROJ.srcs/sources_1/new/Screen_Position.v
    writer: Framebuffer_Write    VGA_PROJ.srcs/sources_1/new/Framebuffer_Write.v
  memory: kv260_memory            kv260/rtl/kv260_memory.v
```

The Utility Sources section also provides the CPU scene/display sources and
this guide. The CPU files run on the ARM processor, so they do not appear as
modules in the FPGA hierarchy.

**Open `kv260/build/kv260_gpu.xpr` for the complete board system.** This generated
project contains the Zynq processing system, clock/reset logic, AXI interconnects
and custom GPU. Its top is `system_wrapper`; its block design is `system.bd`.
It is recreated by `kv260/create_project.tcl`, not maintained by editing
generated HDL. The root source-view project omits these vendor IP wrappers
to keep the custom graphics logic easy to follow.

## What the board build uses

| Source or artifact | Role |
| --- | --- |
| `kv260/rtl/` | Control registers, graphics controller and DDR AXI interface |
| `VGA_PROJ.srcs/sources_1/new/Matrix_Vertex.v` | Matrix multiplication with overflow detection |
| `VGA_PROJ.srcs/sources_1/new/Screen_Position.v` | Perspective divide, clipping and screen coordinates |
| `VGA_PROJ.srcs/sources_1/new/Framebuffer_Write.v` | Pixel address generation and write validation |
| `kv260/graphics_sources.tcl` | Shared list of the seven custom RTL files |
| `kv260/software/main.c` | CPU scene, matrix/vertex submission and framebuffer checks |
| `gpu_matrices.c` | Shared CPU matrix calculation code |
| `kv260/software/display.c` and `display.h` | CPU display controller / DPDMA setup for HDMI |
| `kv260/small/` | Compact CPU startup, runtime, build and JTAG loader |
| `kv260/kv260_gpu.bit` | FPGA image loaded by the JTAG loader |
| `kv260/kv260_test.elf` | CPU program loaded by the JTAG loader |

The default CPU build generates adapted sources under `kv260/small/build/`
from the originals. Edit `kv260/software/` and the shared calculator, rather
than generated C files. See [KV260 instructions](../kv260/README.md).

Editing a source file does not change the running board. Hardware changes need
a hardware rebuild; CPU changes need a software rebuild; then the JTAG load
step applies the new artifacts. [Recorded bring-up results](../kv260/STATUS.md)
describe the last documented run, not a live reading of the board.

## Refresh the source-view project

From the repository root in PowerShell:

```powershell
& 'C:/Xilinx/Vivado/2023.1/bin/vivado.bat' -mode batch -source scripts/update_design_view.tcl -tclargs --check
```

This refreshes `VGA_PROJ.xpr` and checks its RTL hierarchy. It does not connect
to the board, assign pins, run implementation, or generate/load a bitstream.
Close the project in any other Vivado window before refreshing it, and reopen
it afterward if you were viewing an older in-memory version.

## Earlier and standalone modules

`vga_3colors.v` and `System_Memory.v` implement the original font/VGA path.
`GPU_Pipeline.v` is the separate local-framebuffer VGA simulation demo.
`Projector.v`, `sin_cos_lut.v`, and `Projector_To_Frame.v` belong to the earlier
projection path. `Line_Draw.v` and `Triangle_Fill.v` are standalone rasterizers
with tests; they are not integrated into the current board point renderer.
`temp.v` and the Basys 3 pin constraints are legacy experiments.

These files remain in the repository, but are excluded from the root design
view so they cannot be mistaken for the active KV260 rendering path.
