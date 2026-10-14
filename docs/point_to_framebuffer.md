# Screen position and red framebuffer writes

Two design sources continue the matrix pipeline:

```text
Matrix_Vertex -> Screen_Position -> Framebuffer_Write -> RAM/DDR write adapter
                    X/Y/Z/W           integer X/Y          address + red data
```

They plot **one red pixel per accepted visible vertex**. They do not fill
triangles, clear buffers, depth-test, swap buffers, or generate video timing.
Both are listed in `VGA_PROJ.xpr`. The existing VGA top and monochrome font RAM
are preserved. The test harness in
`VGA_PROJ.srcs/sim_1/new/Point_Pipeline_Test.v` shows the complete connection,
including `Matrix_Vertex`; the C++ test supplies an 8 MiB simulated RAM.

## 1. Screen_Position

Input X/Y/Z/W and `near_q16` are signed Q16.16. Connect the corresponding
`Matrix_Vertex.result_*` and `out_overflow` signals. The C-generated matrix
already applies focal length. This module therefore calculates:

```text
x2d = floor(screen_width  / 2 + X / W)
y2d = floor(screen_height / 2 - Y / W)
```

The outputs are signed 32-bit **integer pixel coordinates**, with (0,0) at the
top-left. No extra multiply by focal length occurs here. Width and height are
unsigned 16-bit pixel counts, allowing 1..65535. When deriving them from the
32-bit command parameters, the command decoder must reject nonzero upper bits.
Changing dimensions changes the centre; changing zoom still requires a new
CPU-generated matrix.

`out_depth` preserves input Z. Division uses **W**, which equals Z for the
current C matrix. This is the project's pixel-scaled matrix convention, not a
generic OpenGL/Direct3D normalized-device-coordinate viewport operation.
The near-plane test uses input Z as camera depth, as produced by the current
C generator. A different projection convention needs a matching clipping rule.

The module produces one output token for every input token:

| Output | Meaning |
| --- | --- |
| `x2d`, `y2d` | Finished integer pixel location; zero when rejected. |
| `out_in_frame` | The point is valid and inside both screen bounds. |
| `out_rejected` | Matrix overflow, W <= 0, Z < near, nonpositive near, zero dimension, or integer-coordinate overflow. |
| `out_depth` | The original Q16.16 Z. |
| `out_buffer_select` | The input buffer selection captured with this point. |
| `out_width`, `out_height` | Screen dimensions captured with this point. |

Ordinary off-screen coordinates are preserved with `out_in_frame=0`; they do
not wrap or clamp onto an edge. Rejected/off-screen points cannot write RAM.
This is point rejection only. A future triangle renderer must clip triangles
crossing the near plane before division, instead of simply discarding one of
their vertices.

Two independent registered restoring dividers calculate X/W and Y/W. The
implementation preserves half-pixel centres for odd resolutions and uses floor
rounding, including negative fractions. It never instantiates a single-cycle
wide Verilog `/` expression. Without stalls, latency is **36 clock periods**
after input acceptance and throughput is **one point per clock** after filling.
The two 33-step divider pipelines trade registers/logic for that throughput.

## 2. Framebuffer_Write

Connect the screen output's valid/ready, coordinates, bounds/rejection flags,
buffer selector, and captured dimensions to the corresponding writer inputs.
The writer rechecks coordinate bounds rather than trusting `in_frame` alone.

Configuration inputs match the proposed DDR layout:

| Input | Example | Meaning |
| --- | --- | --- |
| `buffer_a_offset` | `00100000` | Buffer A's byte offset within the GPU DDR region. |
| `buffer_b_offset` | `00300000` | Buffer B's byte offset within that region. |
| `stride_bytes` | 2560 | Bytes reserved for each screen row, including any padding. |
| `region_bytes` | 8388608 | Total bytes reserved for GPU memory (8 MiB here). |
| `buffer_select` | 0 or 1 | 0 writes A; 1 writes B. |

Each pixel is one 32-bit word in `00RRGGBB` format. The writer always requests:

```text
wr_addr = selected_buffer_offset + y2d * stride_bytes + x2d * 4
wr_data = 00FF0000  (red)
wr_strb = 1111      (write all four bytes)
```

For (240,320), a 2560-byte stride, and buffer A at `00100000`, the byte
address is `001C83C0`. Buffer B at `00300000` gives `003C83C0` for that same pixel.

The RAM/DDR adapter accepts a transaction on a rising edge with both `wr_valid`
and `wr_ready` high. It must hold `wr_ready` low if it cannot accept a write.
Address, red data, byte enables, and buffer selection remain stable while
blocked. This is a simple write interface, **not AXI**. A word-addressed RAM
uses `wr_addr[31:2]`; a DDR adapter adds the GPU region's physical base to the
byte offset. A future adapter must also report/handle memory errors and wait
for actual DDR completion before presenting a frame; queue acceptance alone
does not prove the display can read the completed write.

The writer rejects unaligned buffer offsets/stride, stride below width*4,
overlapping buffers, either buffer extending outside the region, and illegal
pixel locations. Allocation and address calculations are widened to 64 bits
so they cannot silently wrap a 32-bit offset. Both complete buffer allocations
must be valid, even when drawing to only one of them.

`dropped` marks a skipped input at the output stage for one clock. A rejected
point produces no `wr_valid`. There is no separate ready for dropped tokens.
Without stalls, writer latency is **three clock periods** after acceptance,
and it can accept one pixel per clock. From Screen_Position input acceptance
to a visible `wr_valid`, the connected pair takes **40 clock periods**, absent
stalls; the RAM transfer then occurs at the next accepting rising edge.

## Handshake, configuration and reset

- All modules use the same clock and synchronous active-high reset. Each
  transfer needs both valid and ready on a rising edge. Hold valid and the
  entire associated input stable until acceptance.
- Connect `Screen_Position.out_valid` to `Framebuffer_Write.in_valid`, and
  the writer's `in_ready` back to the screen stage's `out_ready`.
- Connect the matrix multiplier's output ready to the screen stage's input
  ready. RAM stalls then propagate safely back through the whole chain.
- Screen dimensions, near distance, and buffer selector are sampled with
  each **screen-stage** input. If feeding from Matrix_Vertex, keep these draw
  settings unchanged while that draw is still passing through the matrix stage.
- Keep buffer offsets, region size, and stride fixed until the whole draw has
  drained. The writer samples its configuration with each accepted pixel.
- `busy` reports valid tokens still inside each new module. Reset cancels
  unaccepted writes and pending points, but does not erase already written RAM.
- Either framebuffer is writable. Software must choose the back buffer to
  avoid modifying the image currently being scanned out; this writer does not
  own front/back swapping or vblank synchronization.

## Run the behavioral test

From PowerShell in the project directory:

```powershell
.\verilator\test_point_pipeline.ps1
```

The test checks the complete matrix -> screen -> writer path, known positions,
W distinct from Z, odd dimensions, negative fractions, exact screen edges,
invalid depth, buffer layout errors, changing per-point buffer selection,
backpressure, and reset. It applies accepted writes to simulated RAM and checks
every word afterward, including memory that must remain untouched.

Verified with Verilator 5.020: **3,232 screen results**, **1,347 red RAM writes**,
1,894 skipped writes, and 10 points intentionally cancelled by reset. All checks
passed. RTL lint also passed with `-Wall`.

Only behavioral Verilator tests and RTL lint are performed. No FPGA frequency
simulation, synthesis, or implementation timing run is part of this work.
Actual display on the existing font VGA path still requires a color framebuffer
reader and memory-controller connection; these two modules do not supply those.
