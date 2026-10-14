# Complete red-point GPU demo

Run from PowerShell in the project directory:

```powershell
.\verilator\run_gpu_demo.ps1 -View
```

This rebuilds the C scene generator, runs the Verilator model, compares the
displayed image with an independent fixed-point reference, and opens the existing
Windows viewer. The result is captured from the HDL's **actual VGA RGB outputs**
after reading its RAM, not drawn by the C program.

```text
demo_scene.txt (camera, object, view, points)
    -> gpu_matrices.c (matrix + vertex words)
    -> GPU_Pipeline.v
         Matrix_Vertex -> Screen_Position -> Framebuffer_Write
             -> System_Memory (two buffers) -> VGA scanout
    -> verilator/gpu_demo/gpu_frame.hex -> screen/vga_screen.exe
```

Only **one new design source** was added: `GPU_Pipeline.v`. The existing
`System_Memory.v` gained an optional writable, double-buffered mode. Its default
mode still loads the original font. `vga_3colors.v` and its memory testbench only
gained tied-off connections for the additional RAM ports. The three existing
matrix/projection/writer modules are reused unchanged.

## Change the camera and points

Edit `demo_scene.txt`, then rerun the same command. All positions use ordinary
real numbers. Rotations in this file are **pitch, yaw, roll**, in degrees:

```text
camera 0 0 0   0 0 0
object 0 0 6   20 30 0
view 320 1
vertex -1 -1 0
vertex  1 -1 0
vertex  0  1 0
```

- `camera`: world position XYZ, then pitch/yaw/roll.
- `object`: world position XYZ, then pitch/yaw/roll.
- `view`: focal length in pixels, then near-plane distance.
- `vertex`: one XYZ point relative to the object's origin.
- `edge`: start XYZ, end XYZ, number of evenly spaced points (at least two).

The supplied example uses 12 edges with 129 points each, so the cube is easy to
see. Edge sampling happens on the CPU; the FPGA plots **individual red points**.
It does not yet draw filled triangles, perform hidden-surface removal, or have
a depth buffer. If you use just three vertices, the output has just three dots.
The scene limit is 16,384 points; the VGA resolution is fixed at 640x480.

The C program is also usable separately:

```powershell
.\gpu_matrices.exe --scene .\demo_scene.txt .\verilator\gpu_demo\scene.hex
```

The script builds its own Linux C executable, so changing the scene requires no
manual compilation. The Windows executable was also rebuilt for this change.
For a different scene path, use `-Scene .\my_scene.txt -View` with the script.

## RAM and control interface

The top accepts a row-major 16-word Q16.16 matrix, then Q16.16 XYZ vertices with
valid/ready handshakes. Camera/object rotation is encoded by the CPU matrix;
there are no separate angle ports or redundant trigonometry blocks in the top.

| Local `cmd` | Action on a valid/ready transfer |
| --- | --- |
| 0 | CLEAR the selected buffer to black. |
| 1 | DRAW exactly `vertex_count` vertices using the loaded matrix and `near_q16`. |
| 2 | PRESENT the selected buffer at the start of vertical blank. |
| 3 | Unsupported; complete with `error=1`. |

These are simple top-level control pins, not new machine-code packet encodings.
A later CPU command decoder can map the command document's clear/draw/present
packets onto them. The generated `scene.hex` is a simulation input file, not an
AMD command stream: magic `47505531`, width, height, near, count, 16 matrix words,
then XYZ words for each vertex.

Basic host sequence:

1. Reset. Output stays black; neither buffer is considered initialized.
2. Load all 16 matrix words, observing `matrix_ready`.
3. CLEAR buffer B; wait for `done`.
4. DRAW B with a vertex count; stream those vertices, observing `vertex_ready`.
5. Wait for `done`: all vertices have either written RAM or been rejected.
6. PRESENT B; wait for `done` at vblank. The image is now scanned from B.
7. For the next frame, clear/draw A while B remains displayed, then present A.

`buffer_select=0` means A; 1 means B. Draw parameters are captured when DRAW is
accepted and stay fixed until completion. Matrix updates and other commands
wait while busy. `done` is a one-clock pulse. `error` persists until the next
accepted command or reset. Writing/clearing the displayed buffer, using an
uncleared buffer for DRAW/PRESENT, or drawing with a nonpositive near plane is
rejected. A zero-vertex draw completes normally. Sending fewer vertices than
promised leaves the draw waiting; reset cancels it.

Because the only colors are black and red, the local RAM stores **one bit per
pixel**, totaling 76,800 bytes for both buffers. The writer still generates
32-bit red pixel requests using logical byte offsets A=0 and B=1,228,800. The
top converts each word address into a compact bit-RAM index. This is a local
FPGA RAM demo; it does not pretend to be a working Kria DDR/AXI controller.

VGA readout, RAM and rendering all use the same input clock. A four-clock pixel
enable reproduces the existing demo's nominal 25 MHz pixel rate from a 100 MHz
input. Sync/blanking are aligned to the synchronous RAM output. `scan_valid`
and `scan_addr` are optional debug outputs used for frame capture.

`GPU_Pipeline` is available as a design source in Vivado; choose **Set as Top**
to inspect it. The existing font design remains the saved project's default
top. Wiring the new host-control inputs to the Kria CPU still needs the eventual
PS/PL interface. No bitstream or timing-closure result is claimed.

## Results and checks

The default cube exports 1,548 vertices and displays 1,076 red pixels. Each of
the 307,200 displayed pixels was checked for both framebuffer A and framebuffer B.
The test also checks clear, empty draws, captured settings, invalid commands,
uninitialized/front-buffer protection, and presentation at vertical blank.

Files produced under `verilator/gpu_demo/`:

- `scene.hex`: generated input matrix and vertices.
- `gpu_frame.hex`: actual VGA pixels in the existing viewer's 12-bit RGB format.
- `gpu_frame.bmp`: the same VGA image as a standard bitmap.

The C generator compiles with warnings treated as errors on GCC and MSVC; its
matrix self-tests still pass. All HDL checks are behavioral simulation and lint.
There is no synthesis, implementation, or clock-speed test in this workflow.
