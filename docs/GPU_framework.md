# GPU interface and command framework

Proposal for the VGA college project

This document proposes a small GPU that accepts drawing commands while the host continues doing other work. Start with the existing 640×480 black-and-white framebuffer and VGA output. Add a queue and a drawing engine before adding color or 3D features.

**Nothing in this document is implemented yet.** The current RTL loads a framebuffer from a hex file and scans it out. It has no command input, command decoder, or runtime drawing interface. The wire names, reset behavior, and execution rules below are proposed requirements.

The command numbers and basic packet shapes borrow from the original **Sony PlayStation GPU**. The simplified memory, timing, and error rules are specific to this project. This would be a PlayStation-inspired subset, not a PlayStation-compatible GPU.

## 1 What asynchronous means here

The host could be a CPU, another FPGA module, or your Verilator C++ testbench. It submits work to a queue. The GPU takes commands from that queue, changes RAM, and signals when the requested work is complete. The host can do other work in between.

For the first version, use the same 100 MHz clock for the host interface and drawing engine. They can work independently while sharing a clock. “Asynchronous to the CPU” does not require clockless logic or different clocks.

If you later connect a host running on another clock, add a proper asynchronous FIFO between the two clock domains. That is an additional implementation step, described in section 8.

## 2 Proposed blocks and data flow

```text
Host or C++ testbench
       |
       | command words and ready/valid handshake
       v
Command FIFO -> Packet decoder -> Drawing engine -> Framebuffer RAM
                                                        |
                                                        v
                                                  VGA scanout
                                                        |
                                                        v
                                                      Monitor

GPU -> host: ready, busy, irq, fault
```

A FIFO is a queue that returns words in the order they arrived. A packet is one command word plus any coordinate, size, or pixel words that follow it. The drawing engine turns those requests into RAM writes. VGA scanout keeps reading the image on its fixed schedule.

Suggested initial FIFO capacity: 64 entries, each holding one 32-bit word plus a one-bit port selector. This capacity is a project choice. It does not limit the length of a command: a large upload streams through the FIFO over time.

## 3 Proposed input and output wires

Directions are relative to the GPU. These are **logical module connections**, not a proposal to connect a 32-bit bus directly to the board's external pins. A physical UART, SPI, or CPU bus adapter could feed this interface later.

| Signal | Direction | Bits | Proposed meaning |
| --- | --- | --- | --- |
| `clk` | Input | 1 | Existing 100 MHz board clock; also clocks command acceptance. |
| `rst_n` | Input | 1 | Active-low reset, sampled on the rising edge of `clk`. |
| `cmd_data` | Input | 32 | One command, parameter, or upload word. |
| `cmd_port` | Input | 1 | `0` selects GP0 drawing/data; `1` selects GP1 control. |
| `cmd_valid` | Input | 1 | Host says the word and port are valid. |
| `cmd_ready` | Output | 1 | GPU can accept a word on this clock edge. |
| `busy` | Output | 1 | A queued word, incomplete packet, or unfinished operation remains. |
| `irq` | Output | 1 | Completion marker has executed; stays high until acknowledged. |
| `fault` | Output | 1 | Unsupported command or invalid packet; stays high until reset. |
| `hsync` | Output | 1 | Existing horizontal VGA synchronization. |
| `vsync` | Output | 1 | Existing vertical VGA synchronization. |
| `vga_r` | Output | 4 | Existing red output; initially only `0` or `F`. |
| `vga_g` | Output | 4 | Existing green output; initially only `0` or `F`. |
| `vga_b` | Output | 4 | Existing blue output; initially only `0` or `F`. |

### Sending a word

1. Put a word on `cmd_data`, choose `cmd_port`, and assert `cmd_valid`.
2. A transfer occurs only on a rising `clk` edge where **both `cmd_valid` and `cmd_ready` are 1**.
3. If `cmd_ready` is 0, keep the word, port, and valid signal unchanged until accepted.
4. After acceptance, send the next word or deassert `cmd_valid`.

`cmd_ready` means there is room for a word. It does not mean that drawing is complete. It is normal for `busy=1` and `cmd_ready=1` at the same time. A valid word held through three ready clock edges is accepted three times.

### Reset and completion

Reset flushes the queue and partial packet, stops drawing, clears `irq` and `fault`, and disables visible RGB output. Preserve RAM contents; reset is not a framebuffer clear. VGA timing continues. During reset, command acceptance is disabled. After reset, send an explicit clear if you need a blank image.

To wait for a batch, acknowledge an old IRQ, send the drawing commands, and finish with GP0 `1F000000`. Wait for `irq=1`, then acknowledge it with GP1 `02000000`. Allow only one outstanding completion marker in this first version. A completion marker means earlier RAM writes are committed; it does not mean the monitor has already scanned those pixels.

## 4 Borrowed command encodings

PlayStation uses separate GP0 and GP1 command destinations. Here `cmd_port` supplies that distinction. The following are selected command encodings, not general CPU instructions. See the original hardware reference [1] and the PSn00bSDK packet definitions [2].

| Port | First word | Total words | Proposed action |
| --- | --- | --- | --- |
| GP0 | `00000000` | 1 | NOP; consume without drawing. |
| GP0 | `60BBGGRR` | 3 | Opaque filled rectangle: color, position, size. |
| GP0 | `68BBGGRR` | 2 | Opaque single pixel: color, position. |
| GP0 | `A0000000` | `3 + ceil(width × height / 2)` | Upload a rectangle: header, position, size, pixel payload. |
| GP0 | `1F000000` | 1 | Completion marker; set IRQ after preceding work finishes. |
| GP1 | `02000000` | 1 | Acknowledge IRQ; clear `irq`. |
| GP1 | `03000000` | 1 | Enable visible output. |
| GP1 | `03000001` | 1 | Disable visible output; keep sync running. |

The two `03` words are two settings of the same command. These seven command types are enough to clear the screen, draw blocks and pixels, upload font images, and wait for completion. No custom command numbers are necessary for that starting point.

**Compatibility boundary:** reuse these numeric encodings and packet shapes only. This proposal changes color storage, coordinate limits, queuing, and reset/error behavior. It does not include PlayStation GPU status registers, DMA, textures, clipping registers, polygons, display modes, mask bits, or software compatibility. GP1 reset `00` is intentionally outside this subset; use `rst_n`.

### Word layout

For rectangle and pixel commands, the first word is arranged as follows [2]:

```text
31          24 23          16 15           8 7            0
+-------------+-------------+-------------+-------------+
|   opcode    |    blue     |    green    |     red     |
+-------------+-------------+-------------+-------------+

60FFFFFF = rectangle with white color
60000000 = rectangle with black color
```

The next word places Y in the upper 16 bits and X in the lower 16 bits. A size word similarly places height above width. For this project, send unsigned coordinates within `x=0..639`, `y=0..479`; do not send negative coordinates. This is a restricted project input convention.

```text
position = (y << 16) | x
size     = (height << 16) | width

00280020 means x=32, y=40
00100040 means width=64, height=16
```

The decoder reads an opcode only when expecting a new command. Coordinates and upload words are data, even when their upper byte happens to equal an opcode. Packet length comes from the command type and upload dimensions, not from a special end word.

Each example hex value below represents one entire 32-bit transfer. A future byte transport must specify its own byte order; choose least-significant byte first. For example, `60FFFFFF` would travel as bytes `FF FF FF 60`. The parallel `cmd_data[31:0]` interface has no serial byte order.

## 5 Example command stream

This is a proposed host sequence. It cannot run on the current RTL until the interface and decoder are implemented. Send each word using the handshake; keep the listed port for that word.

| Step | Port | Words in transmission order | Result |
| --- | --- | --- | --- |
| 1 | GP1 | `02000000` | Clear an old completion flag. |
| 2 | GP1 | `03000001` | Hide the image while preparing it. |
| 3 | GP0 | `60000000` `00000000` `01E00280` | Clear all 640×480 pixels to black. |
| 4 | GP0 | `60FFFFFF` `00280020` `00100040` | Draw a white 64×16 block at (32,40). |
| 5 | GP0 | `68FFFFFF` `00640064` | Draw a white pixel at (100,100). |
| 6 | GP0 | `1F000000` | Signal completion after those writes. |
| 7 | Host action | Wait for `irq=1` | Drawing has finished. |
| 8 | GP1 | `02000000` | Acknowledge completion. |
| 9 | GP1 | `03000000` | Show the finished image. |

The black clear uses the ordinary rectangle command. There is no separate clear-screen opcode in this proposal. Display enabling does not wait for vertical blank; the next complete VGA frame shows the finished result.

## 6 Drawing an eight by eight character

The GPU does not automatically know what the letter A means. Initially, the host looks up its eight row bytes, expands them into pixels, and sends an upload. The existing source contains A as:

```text
38 6C C6 C6 FE C6 C6 00
```

For A0 uploads, use two 16-bit pixel values in each 32-bit payload word, the earlier pixel in the lower half. Scan across a row before advancing to the next. Supply `ceil(width × height / 2)` payload words; ignore the unused upper half of the last word when the pixel count is odd. This packet shape follows the PlayStation transfer format [1].

For this monochrome proposal, send `0000` for a black pixel and `7FFF` for a white pixel. The GPU turns the low 15 bits of each 16-bit value into one stored bit: zero means black, anything else means white. Ignore bit 15. These are opaque writes, so black pixels erase existing content.

Here is a complete upload for A at (16,16). The first three words are the header, destination, and size. The remaining 32 words encode the 64 pixels. Every value is sent to GP0; spaces and newlines below only group words for readability.

```text
A0000000
00100010
00080008
00000000 7FFF7FFF 00007FFF 00000000
7FFF0000 00007FFF 7FFF7FFF 00000000
7FFF7FFF 00000000 7FFF0000 00007FFF
7FFF7FFF 00000000 7FFF0000 00007FFF
7FFF7FFF 7FFF7FFF 7FFF7FFF 00007FFF
7FFF7FFF 00000000 7FFF0000 00007FFF
7FFF7FFF 00000000 7FFF0000 00007FFF
00000000 00000000 00000000 00000000
```

One source byte represents eight horizontal pixels. A0 expands that byte into four transmitted words. Uploading A therefore takes 35 words, including its three-word header. Later, a dedicated font ROM and text command could reduce this traffic, but that would be a project-specific extension with a separately defined encoding.

## 7 Framebuffer and execution rules

### Stored image format

Keep the current RAM layout: 38,400 bytes, 80 bytes per scanline, most-significant bit first. The current memory file supplies the initial image. The new drawing engine would add a write path; it would not change the VGA image format.

```text
pixel index = y × 640 + x
byte index  = floor(pixel index / 8)
bit index   = 7 - (pixel index modulo 8)
```

For rectangle and dot colors, store black when the 24-bit RGB field is zero, otherwise white. This is a deliberate monochrome conversion, not PlayStation color rendering. The 32-bit command bus does not imply a 32-bit framebuffer.

Changing one pixel must preserve the other seven bits in its byte. A simple starting writer reads the byte, changes one bit, and writes it back. Finish that operation before starting another update to the same byte. Rectangle and upload completion includes these final writes.

### Command ordering and boundaries

Process accepted words in order through one queue carrying both port and data. In this proposal GP1 control also waits in that queue; this differs from the original GPU's separate control path [1]. Never interleave a GP1 word into an unfinished GP0 packet. Send all its parameters and upload data first.

Rectangles accept widths 0..640 and heights 0..480. A zero dimension makes the rectangle a no-op. Draw the half-open region from (x,y) through (x+width-1,y+height-1), clipped to the screen. Do not wrap to the opposite edge.

Uploads require nonzero dimensions and must fit entirely on screen. Reject an invalid upload header before accepting its payload for execution. These constraints deliberately avoid the original GPU's wrapping behavior.

An incomplete packet waits for more words with `busy=1`. An unknown opcode, invalid coordinate, invalid size, nonzero reserved field, or wrong port inside a packet raises `fault`. Stop drawing and accepting commands until `rst_n` resets the parser and queue. Keep VGA sync running. The host must reset after a malformed stream; a later word must not be guessed to be a new command.

### Sharing RAM with scanout

VGA reads must keep meeting the pixel schedule even while drawing is busy. Use a scheduled memory controller or an appropriate dual-port RAM. If scanout and the writer access the same byte together, define the read/write behavior or stall the writer; do not rely on an unspecified collision result.

A single framebuffer can show tearing because scanout may see some old pixels and some new ones during an update. Start with the display-disabled sequence above for static tests. A later double-buffer scheme would need 76,800 bytes for two monochrome frames, plus other storage, and an explicit swap at vertical blank. That swap command is not defined in this first subset.

## 8 Separate host and GPU clocks later

If the host clock is different, add `host_clk`. The host-side `cmd_data`, `cmd_port`, `cmd_valid`, and `cmd_ready` then belong to that clock domain. Transfer each 33-bit port-plus-word entry through an asynchronous FIFO into the GPU domain. AMD provides an asynchronous FIFO primitive with separate read and write clocks [3].

Do not pass each command bit through an independent synchronizer. The receiving side must get one complete word coherently. Return persistent flags such as `irq` and `fault` through suitable single-bit synchronizers; use a deliberate status mechanism if you later need coherent multi-bit counters. Reset release and FIFO readiness must be coordinated across both clocks.

Keep the initial common-clock version until packet handling and drawing work. The interface behavior above remains the host contract; adding a clock crossing should not change the numeric command words.

## 9 Suggested learning and verification order

1. Add the ready/valid interface, queue, and NOP handling. Verify each accepted word is consumed once, including long stalls.
2. Add the dot command. Test (0,0), (639,479), and adjacent pixels sharing a byte. Check that neighbors remain unchanged.
3. Add rectangles and full-screen clear. Check zero size, clipping, and every screen edge.
4. Add A0 uploads. Send the A example, an odd pixel count, and a transfer larger than the FIFO. Verify payload words are never decoded as commands.
5. Add the completion marker, acknowledge, display enable, and fault behavior. Test reset during a partial packet and during drawing.
6. Test simultaneous drawing and VGA scanout. Keep sync timing fixed and define RAM collisions. Add a second host clock only after these tests pass.

For future Verilator testing, the C++ driver would toggle `clk`, obey `cmd_ready`, submit the example words, wait for IRQ with a timeout, and capture the next complete frame. Compare its pixels to an expected image. The current C++ simulation does not yet drive these proposed command signals.

## 10 Reference sources

[1] **PSX SPX original PlayStation GPU hardware reference.** Used for GP0/GP1 routing, image uploads, NOP, interrupt and display-control encodings. This is community hardware research, not an official Sony specification. Retrieved 18 September 2026.  
https://psx-spx.consoledev.net/graphicsprocessingunitgpu/

[2] **PSn00bSDK psxgpu.h.** Primary SDK source confirming `setTile` as `0x60`, `setTile1` as `0x68`, the IRQ encoding, and rectangle packet fields. Encodings are reused here; no SDK implementation is copied. Retrieved 18 September 2026.  
https://github.com/Lameguy64/PSn00bSDK/blob/master/libpsn00b/include/psxgpu.h

[3] **AMD XPM FIFO ASYNC reference.** Primary vendor documentation for an asynchronous FIFO with separate clocks. Consult the version matching your Vivado installation when implementing it. Retrieved 18 September 2026.  
https://docs.amd.com/r/en-US/ug953-vivado-7series-libraries/XPM_FIFO_ASYNC

Local project baseline: `vga_3colors.v`, `System_Memory.v`, `verilator/sim_main.cpp`, and the original A glyph in `font_glyphs.hex`. Hardware behavior in this document is proposed unless explicitly described as current.
