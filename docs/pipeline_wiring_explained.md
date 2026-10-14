# GPU pipeline wiring, explained

This document explains every port connection in the three processing blocks
inside `VGA_PROJ.srcs/sources_1/new/GPU_Pipeline.v`:

```text
3D vertex (x, y, z)
    -> Matrix_Vertex (X, Y, Z, W)
    -> Screen_Position (pixel x, pixel y)
    -> Framebuffer_Write (address, red color)
    -> System_Memory (framebuffer)
    -> VGA output
```

In Verilog, `.result_x(mx)` means "connect the module port named `result_x`
to the wire named `mx` in `GPU_Pipeline`." The names on either side do not
need to match. A wire often connects the output of one block to the input of
the next; for example, `mx` connects `Matrix_Vertex.result_x` to
`Screen_Position.in_x`.

## How `valid` and `ready` work

A block sends a value when it asserts `valid`. The next block asserts `ready`
when it can accept that value. The transfer occurs on a rising clock edge if
**both are 1**. If `ready` is 0, the sender holds its output until the receiver
can take it. The same handshake is used for matrix words, vertices, projected
points, and memory writes.

Matrix words, vertices, matrix results, and the near distance use signed
**Q16.16** values: a 32-bit integer with 16 fractional bits. For example,
`32'd65536` represents `1.0`. Pixel coordinates and screen dimensions are
ordinary integer pixel counts.

## 1. `Matrix_Vertex transform`

This block first stores 16 matrix numbers, in row-major order, to form a 4x4
matrix. It then multiplies each input `(vertex_x, vertex_y, vertex_z, 1)` by
that matrix. The fourth input, W=1, is implicit; there is no `vertex_w` port.
The matrix already includes the camera, object, and projection settings made
by the C program.

| Port connection | Meaning |
| --- | --- |
| `.clk(clk)` | Clock for the matrix unit. |
| `.rst(rst)` | Resets its control state; the matrix must be loaded again afterward. |
| `.matrix_valid(matrix_valid && state == IDLE)` | A matrix word is offered only while the GPU is idle. |
| `.matrix_ready(m_load_ready)` | The matrix unit can accept a matrix word. A word transfers when this and `matrix_valid` are both 1. |
| `.matrix_data(matrix_data)` | The current signed 32-bit Q16.16 matrix number. Send all 16 numbers in row-major order. |
| `.matrix_loaded(matrix_loaded)` | Becomes 1 after the sixteenth matrix word is accepted. |
| `.vertex_valid(vertex_valid && state == DRAW && remaining != 0)` | An input vertex is offered during DRAW while the requested count has not been exhausted. |
| `.vertex_ready(m_vertex_ready)` | The matrix unit can accept a vertex. The top-level `vertex_ready` also checks that DRAW is active and `remaining != 0`. |
| `.vertex_x(vertex_x)` | Vertex X, signed Q16.16. |
| `.vertex_y(vertex_y)` | Vertex Y, signed Q16.16. |
| `.vertex_z(vertex_z)` | Vertex Z, signed Q16.16. |
| `.out_valid(m_valid)` | The transformed X, Y, Z, and W belong to a valid result. |
| `.out_ready(m_ready)` | `Screen_Position` can accept that result. This is the same wire as its `in_ready` output. |
| `.result_x(mx)` | Transformed X, signed Q16.16. |
| `.result_y(my)` | Transformed Y, signed Q16.16. |
| `.result_z(mz)` | Transformed Z, signed Q16.16; used for the near-plane test. |
| `.result_w(mw)` | Transformed W, signed Q16.16; used for the perspective divide. |
| `.out_overflow(m_overflow)` | Four bits saying whether the X, Y, Z, or W result overflowed. Bits 0, 1, 2, and 3 correspond to X, Y, Z, and W. |

The matrix unit performs the four row calculations in parallel. Its arithmetic
is registered in stages so it can accept a new vertex each clock when the
following blocks are ready. A full or stalled following block pauses the
pipeline through `m_ready`.

## 2. `Screen_Position projection`

This block divides by W and moves the origin from the screen center to pixel
coordinates. For the fixed 640x480 screen, its intended calculation is:

```text
pixel X = floor(320 + X / W)
pixel Y = floor(240 - Y / W)
```

The matrix has already applied the focal length. The minus sign on Y is needed
because increasing screen Y goes downward. The hardware uses staged division
so one point can enter each clock when the pipeline is not stalled.

| Port connection | Meaning |
| --- | --- |
| `.clk(clk)` | Clock for projection. |
| `.rst(rst)` | Resets its pipeline control. |
| `.in_valid(m_valid)` | A transformed point is available from `Matrix_Vertex`. |
| `.in_ready(m_ready)` | Projection can accept the transformed point. It drives the matrix unit's `out_ready`. |
| `.in_x(mx)` | Transformed X. |
| `.in_y(my)` | Transformed Y. |
| `.in_z(mz)` | Transformed Z/depth. |
| `.in_w(mw)` | Transformed W, the divisor for perspective. |
| `.in_overflow(m_overflow)` | Rejects a point if any matrix result overflowed. |
| `.screen_width(16'd640)` | Image width in pixels. |
| `.screen_height(16'd480)` | Image height in pixels. |
| `.near_q16(active_near)` | Minimum permitted Z/depth, signed Q16.16. `active_near` is latched when DRAW starts. |
| `.buffer_select(target_buffer)` | Tags the point with its target framebuffer: 0=A, 1=B. `target_buffer` is latched when the command starts. |
| `.out_valid(p_valid)` | The projected result and its status flags are valid. |
| `.out_ready(p_ready)` | `Framebuffer_Write` can accept the result. This is the writer's `in_ready` output. |
| `.x2d(px)` | Final signed integer pixel X. |
| `.y2d(py)` | Final signed integer pixel Y. |
| `.out_depth(unused_depth)` | The point's Z value. This demo has no depth buffer, so the top does not use it. |
| `.out_in_frame(p_inside)` | 1 if the projected pixel is within the image bounds. |
| `.out_rejected(p_rejected)` | 1 if the point cannot be projected or displayed because of overflow, invalid W, a nonpositive near setting, or Z before the near plane. |
| `.out_buffer_select(p_buffer)` | Carries the chosen A/B buffer with this specific point to the writer. |
| `.out_width(p_width)` | Carries the screen width with this specific point. |
| `.out_height(p_height)` | Carries the screen height with this specific point. |
| `.busy(unused_projection_busy)` | Reports that projection has points in flight; this top-level design does not use the output. |

Being **off-screen** is different from being **rejected**. For example, a
mathematically valid projected coordinate `(700, 200)` is outside a 640x480
image, so `p_inside=0`. The writer skips it. A point behind the near plane is
rejected, so `p_rejected=1`. Rejected points also get skipped.

## 3. `Framebuffer_Write writer`

This block checks the pixel and calculates a logical byte address:

```text
address = selected buffer offset + pixel Y * stride_bytes + pixel X * 4
```

The `* 4` represents one logical 32-bit color word per pixel. Each buffer has
`640 * 480 * 4 = 1,228,800` logical bytes, and each row has `640 * 4 = 2560`
logical bytes.

| Port connection | Meaning |
| --- | --- |
| `.clk(clk)` | Clock for the address writer. |
| `.rst(rst)` | Resets its pipeline control. |
| `.in_valid(p_valid)` | A projected point is available. |
| `.in_ready(p_ready)` | The writer can accept that point. It drives projection's `out_ready`. |
| `.x2d(px)` | Integer pixel X from projection. |
| `.y2d(py)` | Integer pixel Y from projection. |
| `.in_frame(p_inside)` | Only write if the pixel is within the frame. |
| `.in_rejected(p_rejected)` | Do not write a rejected point. |
| `.buffer_select(p_buffer)` | Target A or B for this point. |
| `.screen_width(p_width)` | Width used for bounds and layout checks. |
| `.screen_height(p_height)` | Height used for bounds and layout checks. |
| `.buffer_a_offset(32'd0)` | Logical byte offset where buffer A starts. |
| `.buffer_b_offset(32'd1228800)` | Logical byte offset where buffer B starts. |
| `.stride_bytes(32'd2560)` | Logical bytes per image row. |
| `.region_bytes(32'd2457600)` | Total logical byte region available for both buffers. The writer checks that both allocations fit and do not overlap. |
| `.wr_valid(wr_valid)` | A valid memory write request is available. |
| `.wr_ready(1'b1)` | The present local RAM path always accepts writes. A future DDR interface might need to lower `wr_ready` while busy. |
| `.wr_addr(wr_addr)` | Logical 32-bit byte address of this pixel. |
| `.wr_data(wr_data)` | `32'h00ff0000`, a red color word (`00 R=FF G=00 B=00`). |
| `.wr_strb(wr_strb)` | `4'b1111`: all four byte lanes of the logical word are enabled. |
| `.wr_buffer_select(unused_write_buffer)` | Also reports A/B. The top does not use it because the address already includes the buffer offset. |
| `.dropped(dropped)` | A processed point that produced no write, such as an off-screen point. It still counts as finished. |
| `.busy(unused_writer_busy)` | Reports points in the writer's pipeline; the top does not use this output. |

The output write transfers on a rising edge when `wr_valid && wr_ready` is 1.
Because `wr_ready` is permanently 1 in this demo, the local RAM never applies
write backpressure. `GPU_Pipeline` counts both a write and a drop as a finished
vertex; DRAW completes only after every accepted vertex has finished.

For example, pixel `(320, 240)` has logical address
`240 * 2560 + 320 * 4 = 615680` in buffer A. Its address in buffer B is
`1228800 + 615680 = 1844480`.

## Logical addresses versus the current RAM

The writer's interface describes 32-bit red pixel writes. The current demo
stores only **one bit per pixel** in `System_Memory`: 0=black, 1=red. The top
converts the writer's logical byte address into a compact one-bit pixel index
using `wr_addr[21:2]`, and it checks `wr_data` for the red value. Both buffers
together therefore occupy 614,400 bits, or 76,800 bytes, in the local demo.

The display scans the selected front buffer and turns each stored red bit into
VGA red output. This RAM is inside the FPGA simulation/design. The future Kria
CPU/DDR connection is not implemented by these three blocks.

## 4. Framebuffer RAM, VGA output, and command control

After the three processing blocks, `GPU_Pipeline.v` writes the chosen
framebuffer and repeatedly reads the front framebuffer for VGA. The rest of
the code also decides when to clear, draw, and present a frame.

### VGA pixel position and timing

| Signal or expression | Meaning |
| --- | --- |
| `pixel_div` | Two-bit counter that cycles through 0, 1, 2, 3. |
| `pixel_enable = pixel_div == 2'd3` | Advances the VGA position once every four input clocks. With a 100 MHz input clock, this gives a 25 MHz pixel rate. This is the intended rate, not a timing-closure measurement. |
| `h`, `v` | Current horizontal and vertical scan positions. They include the visible image and the invisible VGA timing intervals. |
| `visible` | 1 only when `h` is 0–639 and `v` is 0–479. Those are the 640x480 displayed pixels. |
| `row = {9'b0, v}` | Expands the vertical position to 19 bits so it can take part in the address calculation. It does not change the value of `v`. |
| `read_addr` | The pixel number to read within the chosen framebuffer: `v*640 + h`. The shifts calculate `v*512 + v*128`, which equals `v*640`. Outside the visible area, the read address is 0; the output is blanked there. |
| `vblank_start` | A pulse at the beginning of vertical blank: the pixel tick where `h=0` and `v=480`. PRESENT waits for this pulse to switch the displayed buffer. |
| `visible_delay` | Delays the visible-area flag to match the framebuffer's registered RAM read, so a pixel is blanked or shown at the correct time. |
| `red_pixel` | The one-bit value read from the current front buffer: 1=red, 0=black. |

When `pixel_enable` is 1, `h` advances. At `h=799`, `h` returns to 0 and
`v` advances. At the end of row `v=524`, `v` returns to 0. Thus the VGA timing
area is 800 pixel positions wide by 525 rows, while only its upper-left
640x480 area is visible. `hsync` is active low for `h=656` through `751`;
`vsync` is active low for `v=490` and `491`.

`scan_valid` and `scan_addr` are optional simulation/debug outputs. They tell
the Verilator testbench when a visible VGA pixel is available and which pixel
number it is. They are not extra pixels or a second framebuffer.

### Reading and writing the local framebuffer

| Signal or expression | Meaning |
| --- | --- |
| `ram_write` | Enables a RAM write during CLEAR, or for an accepted writer request with all four logical byte lanes enabled and an address inside the logical region. Reset disables writes. |
| `ram_write_index` during CLEAR | Uses `clear_index` to visit every pixel of A, or adds 307,200 to visit every pixel of B. |
| `ram_write_index` during DRAW | Uses `wr_addr[21:2]`, equivalent to dividing the writer's aligned logical byte address by 4. Buffer B's byte offset of 1,228,800 becomes a pixel offset of 307,200. |
| `System_Memory #(.GPU_MODE(1)) framebuffer` | Instantiates `System_Memory` in its writable, two-buffer GPU mode. |
| `.clk(clk)` | Clock for RAM reads and writes. |
| `.addr(read_addr)` | Pixel number to read within the currently displayed buffer. |
| `.dout(red_pixel)` | Registered one-bit pixel read from RAM. |
| `.read_buffer(front_buffer)` | Chooses which buffer VGA reads: 0=A, 1=B. |
| `.wr_en(ram_write)` | Enables a write to the RAM. |
| `.wr_addr(ram_write_index)` | Compact one-bit-per-pixel RAM index for that write. |
| `.wr_data(state != CLEAR && wr_data == 32'h00ff0000)` | Writes 0 during CLEAR. During DRAW, writes 1 for the writer's red color. |

The 32-bit `wr_addr` and `wr_data` signals are the **logical writer
interface**. `System_Memory` in this demo stores only a red/black bit per
pixel. Buffer A occupies RAM indices 0–307,199, and buffer B occupies
307,200–614,399.

`vga_r` is `F` when the display is enabled, the delayed position is visible,
and `red_pixel=1`; otherwise it is 0. `vga_g` and `vga_b` are always 0. That
produces only black (`000`) and red (`F00`) VGA pixels. The testbench captures
these VGA color outputs to make `gpu_frame.hex`.

### Reset and the command state machine

`state` is one of `IDLE`, `CLEAR`, `DRAW`, and `PRESENT`. A command is accepted
on a rising edge when `cmd_valid && cmd_ready` is 1. `done` is a one-clock
pulse when a command finishes; `error` stays set until the next accepted
command or reset.

| State or signal | What happens |
| --- | --- |
| Reset | Returns to IDLE; sets `done`, `error`, `display_enabled`, and both `initialized` flags to 0. `front_buffer` and `target_buffer` become A. The RAM contents are **not** cleared by reset, so a buffer must receive CLEAR before use. |
| `IDLE` | Waits for a command. On acceptance, saves `buffer_select` in `target_buffer` and checks whether the command is allowed. |
| Invalid command checks | Rejects command 3; CLEAR/DRAW on the displayed front buffer; DRAW/PRESENT on a buffer not yet cleared; and DRAW with `near_q16 <= 0`. A rejected command sets `error=1` and pulses `done` without entering another state. |
| `CLEAR` (command 0) | Writes black to all 307,200 pixels of `target_buffer`, one pixel per clock. At the last pixel, marks that buffer initialized, returns to IDLE, and pulses `done`. |
| `DRAW` (command 1) | Saves `vertex_count` in `remaining` and the near distance in `active_near`. It sends the requested vertices through the three processing blocks. |
| `accept_vertex` | True when `vertex_valid && vertex_ready`. DRAW reduces `remaining` by one for each accepted vertex. |
| `finish_vertex` | True for either `wr_valid` or `dropped`. A vertex is finished when it writes its pixel or is skipped. The local RAM always accepts writes, so `wr_valid` finishes that vertex here. |
| `in_flight` | Counts accepted vertices still traveling through the pipeline. It rises on an acceptance without a completion and falls on a completion without an acceptance. If both happen on one clock, it stays the same. |
| DRAW completion | When `remaining` and `in_flight` are both zero, all requested vertices have finished. The design returns to IDLE and pulses `done`. |
| `PRESENT` (command 2) | Waits for `vblank_start`, then sets `front_buffer` to `target_buffer`, enables display, returns to IDLE, and pulses `done`. Switching at vertical blank avoids changing buffers partway through a visible frame. |

For a typical first frame: load the matrix, CLEAR B, DRAW B, PRESENT B. While
B is displayed, CLEAR and DRAW A. Then PRESENT A at the next vertical blank.

Related source files: `Matrix_Vertex.v`, `Screen_Position.v`,
`Framebuffer_Write.v`, `GPU_Pipeline.v`, and `System_Memory.v` in
`VGA_PROJ.srcs/sources_1/new/`. See `docs/gpu_pipeline.md` for the full demo
workflow and commands.
