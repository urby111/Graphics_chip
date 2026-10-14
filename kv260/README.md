# KV260 hardware test

This is a separate KV260 project for the existing red-point renderer. The CPU
calculates the matrix using `gpu_matrices.c`, stores the 16 matrix words and XYZ
vertices in DDR, then writes START. The FPGA reads the complete matrix first,
streams vertices through the existing Matrix_Vertex / Screen_Position /
Framebuffer_Write modules, and writes a 640x480 color framebuffer in DDR.

The PS DisplayPort controller and DPDMA scan that framebuffer through the KV260
carrier's STDP4320 DisplayPort/HDMI splitter to the onboard HDMI connector.
No custom HDMI transmitter IP is needed for this board route.

The first test displays one static cube frame. The CPU samples its 12 edges into
1,548 points. The FPGA draws the points; the CPU only initializes black pixels,
calculates the matrix, supplies geometry, checks RAM, and configures scanout.
Display starts after all pixel writes have completed. This version does not
implement animation/page flips, filled triangles, or depth testing.

## Equipment and software

- KV260 with its 12 V supply (micro-USB does not power the board).
- Micro-USB connected to J4 for JTAG/UART.
- HDMI cable and a monitor supporting 640x480 at 60 Hz connected to J5.
- Vivado **2023.1**, with Kria K26 device support and KV260 board files.
- The existing **Ubuntu 24.04 WSL** environment, with Python 3 and native GCC.
- A compact ARM compiler unpacked locally in `kv260/toolchain/`. It uses about
  **132 MiB**. The one-time download is 37 MiB; its archives can be discarded
  after extraction. No Vitis installation,
  sudo, or changes to WSL's installed packages are needed.

No microSD card or Ethernet connection is needed. The test is loaded temporarily
over JTAG. Power cycling loses the test; these scripts do not program flash.

## Build and load

From the VGA_PROJ folder in PowerShell:

```powershell
.\kv260\run.ps1 hardware
.\kv260\run.ps1 software
.\kv260\run.ps1 load
```

The default `software` command builds the small standalone CPU executable using
the project-local compiler and AMD driver sources already shipped with Vivado.
The compiler is downloaded only when absent. With the existing hardware files,
just run `software` and `load`; there is no need to rebuild PL.

The original Vitis build is optional. Select it explicitly for both steps:

```powershell
.\kv260\run.ps1 software -SoftwareMode vitis -Xsct 'D:/Xilinx/Vitis/2023.1/bin/xsct.bat'
.\kv260\run.ps1 load -SoftwareMode vitis
```

The hardware build produces `kv260_gpu.bit` and `kv260_gpu.xsa` after synthesis,
implementation and a setup/hold timing check. The compact software build produces
`kv260_test.elf` (about 114 KiB). Its startup and linker keep the application,
stack and descriptors below the GPU region. It reuses `gpu_matrices.c`, with
small sin/cos/round routines replacing libm. These were compared with libm over
7,201 angles and 145 complete Q16.16 matrices. AMD's display drivers are compiled
from the existing Vivado installation.

The compact load script selects temporary JTAG boot for a warm reset, initializes
PS/DDR with Vivado's generated `psu_init.tcl`, programs PL, then downloads and
runs the CPU application at EL3. It needs no FSBL or SD boot image. If initialization
or the debug connection fails, it stops. This first bring-up keeps caches/MMU
disabled and polls DPDMA VSYNC handling instead of configuring CPU interrupts.

Open the board UART in a serial terminal at **115200 baud, 8N1, no flow control**.
This PC currently exposes COM15 and COM16; start with COM15 (normally the lower
FTDI port is UART). The loader also reads CPU progress and counters through JTAG.
Report stage 6 indicates rendering and display link setup completed; other stages
cause a loader error. Serial output itself has not yet been captured.
Typical successful output includes:

```text
KV260 GPU: CPU matrix -> DDR -> FPGA -> HDMI
CPU submitted 16 matrix words and 1548 vertices
GPU complete: accepted=1548 written=... skipped=...
DDR readback: ... red pixels
HDMI configured. Static frame displayed; reset/reload to change scene.
```

Change camera/object position, rotation, focal length, or near plane in
`software/main.c`, then rebuild the software and load again. `make_cube()`
creates the vertices on the board CPU. There is a 16,384-vertex limit.

Edit originals under `software/`; compact sources under `small/build/` are
generated. `small/start.S`, `small/runtime.c`, and `small/link.ld` provide the
small runtime. CPU progress lives at `0x0FF00000`, separate from GPU RAM.

## Data and ownership

The first test uses uncached DDR access on the CPU and a `dsb sy` barrier before
START. It is bare metal, not a Linux driver. The region is reserved by the test's
linker and must not be reused for unrelated CPU allocations.

| Address relative to region base | Contents |
|---|---|
| `0x000000` | 16 row-major Q16.16 matrix words, 64 bytes |
| `0x000040` | XYZ Q16.16 records, 12 bytes each |
| `0x100000` | framebuffer A, 1,228,800 bytes |
| `0x300000` | framebuffer B, 1,228,800 bytes |

Default region base: **0x10000000**, size **8 MiB**. Inputs must fit entirely in
the first 1 MiB and must not overlap each other. Framebuffer locations and
stride (2,560 bytes) are fixed. The master supports 32-bit addresses in lower PS
DDR; addresses near the PMU-reserved top of DDR are rejected. No arbitrary Linux
virtual address can be supplied.

Submitted settings and RAM data belong to the FPGA until DONE. Control writes
during BUSY return AXI SLVERR. Accepted settings are captured once at START.

`matrix_valid` is generated by the controller after a RAM response has arrived.
The coefficient is held until `matrix_ready` accepts it. After exactly 16
accepted coefficients, the controller assembles each complete XYZ record and
holds `vertex_valid` and XYZ until `vertex_ready` accepts that vertex.

## Control registers

AXI-Lite base: **0xA0000000**. All accesses are aligned 32-bit words.

| Offset | Meaning |
|---|---|
| `0x00` | Write bit 0 = START |
| `0x04` | STATUS: bit 0 busy; bit 1 sticky done; bit 3 error; bits 7:4 error code |
| `0x08` | Read-only signature `0x4B563031` (KV01) |
| `0x10` | DDR region base |
| `0x14` | Matrix byte offset |
| `0x18` | Vertex byte offset |
| `0x1C` | Vertex count |
| `0x20` | Positive near plane, signed Q16.16 |
| `0x24` | Target buffer, 0=A or 1=B |
| `0x28` | Accepted vertices |
| `0x2C` | Submitted red pixel writes |
| `0x30` | Rejected/offscreen points |

Error codes: 1 invalid configuration; 2 AXI read error; 3 AXI write error. DONE
is sticky until the next accepted START. A failing job may have partially
modified its back buffer; clear it before retrying. DONE waits for outstanding
read/write transactions to drain, including B responses. A stalled/broken bus
is detected by the CPU's polling timeout; reset/reload to recover from a timeout.

The existing writer emits `00RRGGBB`. The adapter translates that to PS DPDMA
RGBA8888 storage (`AABBGGRR` as a little-endian word): opaque red `0xFF0000FF`,
opaque black `0xFF000000`. This also avoids invisible pixels from zero alpha.

## Verification and bring-up status

Run `./kv260/run.ps1 test` for Verilator controller tests and CPU matrix tests.
The controller tests compare complete buffers with an independent fixed-point
reference, use variable DDR latency, independently stall AW/W/B channels, check
matrix-first ordering, busy rejection, empty jobs, invalid addresses, bus
errors, and recovery.

`tests/check_software.py` checks C syntax against the installed AMD driver
declarations using placeholder generated headers. It is an API check only; it
does not replace an A53 BSP compilation or prove HDMI operation.

`tools/smoke_jtag.tcl` is a separate on-board PL/DDR diagnostic: it halts the
CPU, initializes PS/DDR with Vivado's generated initialization script, loads PL,
supplies a known matrix and three vertices through JTAG, and checks three DDR
pixel writes. It does not clear a whole framebuffer, execute the CPU application,
or start HDMI. Run it with XSDB only after the bitstream exists. It resets the
standalone board and leaves the CPU without a running application (the APU may
remain held in reset).

Hardware test status is recorded in `STATUS.md`. A generated bitstream alone
does not establish successful CPU execution, DDR access, or HDMI output.

The compact CPU/DDR/FPGA/display path has now been tested on the connected KV260:
the CPU calculated all matrix words, the GPU processed 1,548 vertices, CPU
readback found 1,076 red pixels, and the user confirmed the cube is visible over
HDMI. The graphics DMA error registers were also zero.

References: [AMD KV260 board/display architecture](https://xilinx.github.io/kria-apps-docs/kv260/2022.1/build/html/docs/smartcamera/docs/introduction.html),
[AMD standalone DisplayPort driver](https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18842318),
[AMD DPDMA example](https://github.com/Xilinx/embeddedsw/tree/xilinx_v2023.1/XilinxProcessorIPLib/drivers/dpdma/examples).
