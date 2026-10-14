# KV260 bring-up status — 14 October 2026

Prepared: a separate KV260 Vivado design with AXI-Lite control, AXI DDR access,
matrix-first loading, the existing three graphics stages, and color framebuffer
writes. CPU source calculates the matrix on the ARM, supplies sampled cube
vertices, waits for DONE, checks DDR, and configures PS DPDMA/DisplayPort for the
carrier's HDMI output. JTAG build/load scripts and setup instructions are saved.

Verified:

- Powered KV260 detected through USB JTAG (PS, PL, and Cortex-A53 targets).
- Verilator RTL lint passes.
- Controller tests pass for complete framebuffer comparisons on A and B,
  variable DDR delays, independent AXI address/data acceptance, held responses,
  matrix-before-vertex order, busy rejection, empty draws, invalid allocations,
  read/write errors, and fault recovery.
- CPU-generated default scene passes through the controller simulation:
  1,548 vertices and 1,076 red pixels, checked against an independent reference.
- Existing CPU matrix self-tests pass with compiler warnings treated as errors.
- CPU/display source syntax checks pass against installed AMD driver headers.
  This uses placeholder generated configuration headers; it is not an ARM BSP build.
- Vivado synthesis, placement, routing and bitstream generation complete for
  xck26-sfvc784-2LV-c. `kv260_gpu.bit` and `kv260_gpu.xsa` are exported.
- Routed 100 MHz timing passes: setup slack 3.655 ns, hold slack 0.010 ns,
  zero setup/hold failing endpoints. See `timing_summary.rpt`.
- The design was loaded temporarily onto the user's KV260 over USB JTAG.
  Generated PS initialization configured DDR and the PL clock/reset. A known
  matrix plus three vertices were supplied through JTAG; hardware reported
  accepted=3, written=3, skipped=0, DONE with no error, and all three expected
  DDR addresses contained opaque red pixels. See `hardware_smoke.log`.

- The default software/load commands now use a compact GNU AArch64 toolchain
  unpacked into the project. It requires 132 MiB plus 37 MiB of package archives.
  No Vitis installation, sudo, or change to WSL's installed packages is needed.
- Compact math passes 7,201 angle comparisons and 145 exact Q16.16 matrix
  comparisons against libm and the existing CPU calculator.
- The 116,656-byte CPU program was compiled, loaded and executed on Cortex-A53 #0.
  It calculated the matrix on-board and wrote matrix/vertices to DDR. All 16
  matrix words match the host reference. Hardware reported accepted=1548,
  written=1548, skipped=0, DONE with no error. CPU framebuffer readback found
  1,076 opaque red pixels and otherwise opaque black.
- CPU display setup established a successful DisplayPort link through the
  carrier's HDMI splitter. CPU report stage 6 indicates rendering and display
  setup completed. See `small/hardware_run.log`.
- The user confirmed the red cube is visible on the connected HDMI display.
- A read-only check found the graphics DMA channel enabled, with normal and
  extended DMA error status both zero.

Current board state: the full standalone CPU program and GPU are running, with
the rendered cube in framebuffer B, visibly confirmed on the user's HDMI screen.
No flash or SD was changed. Power cycling returns to
normal boot mode. No Vitis or FSBL is needed for the compact path.

Windows exposes USB serial ports COM15 and COM16. The lower port is normally
the board UART; start with COM15 at 115200 baud. CPU progress was checked through
JTAG RAM reads; serial output itself has not been captured.
