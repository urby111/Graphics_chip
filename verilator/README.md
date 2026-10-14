# VGA frame capture

`sim_main.cpp` drives the 100 MHz FPGA clock, waits for the VGA timing to wrap
to the start of a clean frame, and records the first complete 640x480 visible
frame.

Run from PowerShell:

```powershell
.\verilator\run.ps1
```

The default output is `verilator/first_frame.hex`. Pass another path with:

```powershell
.\verilator\run.ps1 -Output .\screen\first_frame.hex
```

The file contains exactly 307,200 lines in row-major order. Each line is one
12-bit VGA color in `RGB` hexadecimal form; for example, `F00` is red, `0F0`
is green, and `FFF` is white.

The RTL loads `font_aligned.hex` from the project root. `font.hex` is an
identical copy for manual use. Both files are full 640x480 monochrome
framebuffers (80 bytes per scanline), not RGB viewer input.

The 254 native 8x8 glyphs occupy a spaced 16x16 character table starting at
pixel (16,16). Each cell is 16x16: an unchanged 8x8 glyph plus 8 blank pixels
of horizontal and vertical spacing. Codes 00 and 01 are missing from the
source and remain blank; codes 02 through FF retain their positions.
For example, uppercase A (code 41) begins at pixel (32,80).
The original glyph data and trailing metadata remain in `font_glyphs.hex`.
Do not load that raw backup directly into the VGA framebuffer.
To rebuild the aligned framebuffer from that original, run:

```powershell
.\verilator\align_font.ps1
.\verilator\run.ps1 -Output .\screen\first_frame.hex
.\verilator\check_font_frame.ps1
```

The converter excludes the metadata after the first 2032 bytes, preserves
glyph order, and fills unused pixels with black. Line breaks in the hex file
are only for readability; the byte order determines the screen layout.

The check compares all 307200 simulated pixels with the packed framebuffer,
with no timing offset permitted. It also writes `screen/first_frame.png`
and an enlarged table preview at `screen/font_preview.png`.
The RTL prefetches the next pixel to compensate for synchronous RAM latency.

Open the RGB capture in the C++ viewer from the project root:

```powershell
.\screen\vga_screen.exe .\screen\first_frame.hex
```
