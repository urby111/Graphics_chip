# Standalone line and triangle designs

`Line_Draw.v` and `Triangle_Fill.v` are independent RTL modules. Neither calls
the other, and neither has been connected to GPU_Pipeline, the KV260 controller,
Framebuffer_Write, RAM, or HDMI. They have been added as unused design sources
in the existing Vivado project so they can be inspected there.

## Common interface

Both use the same clock and active-high synchronous `rst`. Defaults are
`SCREEN_WIDTH=640`, `SCREEN_HEIGHT=480`; each dimension may be 1..32768.

| Signal | Meaning |
|---|---|
| `in_valid`, `in_ready` | Accept one whole drawing request when both are high at a rising edge |
| `x0,y0`, `x1,y1` | First and second screen-space points |
| `x2,y2` | Third point, present only on Triangle_Fill |
| `in_color[31:0]` | One flat color, captured with the points |
| `out_valid`, `out_ready` | Accept one generated pixel when both are high at a rising edge |
| `pixel_x`, `pixel_y` | Signed 32-bit integer pixel coordinates |
| `pixel_color[31:0]` | The captured color, passed through exactly |
| `busy` | A request is being processed |
| `done` | One-clock completion pulse, after the final pixel transfer or an empty/error request |
| `error` | Sticky invalid-input flag; cleared/replaced on the next accepted request or reset |

Inputs are **signed integer 2D coordinates**, not Q16.16 and not unprojected XYZ.
The ports are 32 bits to match the existing screen-coordinate interfaces, but
the supported coordinate range is **-32768..32767**. A coordinate outside that
range is rejected with `error=1` and `done=1`, and produces no pixels. This bounds
line processing time and keeps triangle arithmetic exact. Invalid viewport
parameters also cause requests to be rejected.

For the project's usual color convention, `32'h00FF0000` means red,
`32'h0000FF00` green, and `32'h000000FF` blue. These modules do not convert color
formats or alpha values. Their output contains coordinates and color, not a RAM
address or a write transaction.

## Sending work and handling timing

1. Supply the points and color, and assert `in_valid`.
2. Hold those inputs until a rising edge with `in_ready=1` accepts the request.
3. Deassert `in_valid`, or hold the next request until the module becomes ready.
4. Consume pixels using `out_valid/out_ready`. A stalled valid pixel keeps its
   coordinates and color unchanged. Input changes while busy cannot change the
   active shape.
5. Wait for `done`. Only one request is active at a time. A following request
   can be accepted on the next clock after completion.

Reset suppresses both handshakes, cancels the current shape, clears status, and
returns to idle. Already accepted pixels belong to the receiver and are not
erased by reset. No completion pulse is emitted for a cancelled request.

## Line_Draw

Uses an integer Bresenham accumulator for all eight directions, including steep,
shallow, horizontal, vertical, reversed and zero-length lines. Both endpoints
are included. A zero-length visible line emits exactly one pixel.

It visits one line position per unstalled clock. Only positions inside the
viewport are emitted; offscreen positions advance even when `out_ready=0`.
Clipping is performed by discarding outside pixels from the original line,
which preserves the original line's rounding. The module does not first snap
endpoints to the screen edge. A line crossing the whole supported coordinate
range may visit up to **65,536 positions**, even if few are visible.

Example request: `(20,30)` to `(200,100)`, color `00FF0000`.

## Triangle_Fill

Captures three vertices, sets up edge equations, clips the bounding box to the
viewport, and visits candidate pixels in row-major order. It tests pixel centers
at `(x+0.5,y+0.5)`. Each accepted interior pixel carries the same input color.

It accepts either winding. A **top-left** edge convention includes top/left
edges and excludes the opposite shared edge, so adjacent triangles cover a
rectangle without holes or writing shared-edge pixels twice. Degenerate
triangles (zero area, including repeated/collinear vertices) complete normally
with no pixels and `error=0`. Fully offscreen triangles also complete normally.

After two setup edges following command acceptance, it scans one bounding-box
position per unstalled clock. Uncovered positions advance without waiting for
the receiver; covered positions wait for `out_ready`. The worst candidate count
is `SCREEN_WIDTH * SCREEN_HEIGHT` (307,200 at the default size). Emitted pixels
can have gaps in `out_valid`. No division is used in the scan loop.

Example request: `(80,400)`, `(320,60)`, `(560,400)`, color `0030A0FF`.

## Tests and previews

From PowerShell in the project folder:

```powershell
.\verilator\test_rasterizers.ps1
```

Verilator `-Wall` checks are enabled without suppressing RTL warnings. Tests use
an independent rational DDA line reference and direct triangle edge evaluations,
checking exact pixel sequences and colors. They exercise all line octants,
negative/large coordinates, viewport edges, both triangle windings, empty shapes,
shared-edge ownership, random output stalls, changing busy inputs, reset during
a stalled pixel, and completion/error behavior.

Verified simulation results:

- Line_Draw: **1,589 requests**, **27,808 visible pixels checked**.
- Triangle_Fill: **334 requests**, **1,206,812 visible pixels checked**.

The tests generate `verilator/rasterizers/line_demo.bmp` and `triangle_demo.bmp`
from the actual RTL pixel outputs.

Both modules also passed standalone Vivado 2023.1 synthesis for the K26 with
zero errors and zero critical warnings. To repeat the synthesis check:

```powershell
& 'C:/Xilinx/Vivado/2023.1/bin/vivado.bat' -mode batch -nojournal `
  -log verilator/rasterizers/synthesis.log -source verilator/synth_rasterizers.tcl
```

This produces independent synthesis checkpoints and resource reports for the
K26. It does not place/route the modules, establish a clock-speed limit, modify
the KV260 bitstream, or exercise these new modules on hardware.
