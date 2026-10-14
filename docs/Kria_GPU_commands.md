# Kria GPU: simple graphics command set

**Project context to retain:** You use a "Krai" FPGA board, understood here as the **AMD Kria** family; the exact SOM/carrier model has not been specified. Its onboard CPU and DDR provide the computer side. Your custom FPGA logic provides the GPU: projection, drawing, framebuffer access, and video output. The rendering clock target is 100 MHz. Coordinate math uses 32-bit fixed point.

This is a proposed interface, version 1. It is the current direction for the project, replacing the earlier generic-processor suggestion and the older monochrome command proposal. It does not describe completed hardware.

## What the CPU asks the GPU to do

The CPU supplies requests such as **"use this camera," "draw these triangles," and "show this frame."** The FPGA runs the arithmetic internally through dedicated graphics stages. A command can start thousands of cycles of work.

| Part | Responsibility |
| --- | --- |
| Onboard CPU | Run the application; prepare world-space vertices and drawing requests; submit each frame. |
| Shared DDR | Hold command lists, vertices, and two rendered images called framebuffers. |
| FPGA GPU | Read the requests and vertices; transform, project, and fill triangles; write pixels; continuously output video. |

The flow is **CPU requests in DDR -> GPU command reader -> camera transform -> clipping -> projection -> screen coordinates -> triangle filling -> framebuffer -> video output**. Triangle filling is also called rasterization.

AMD's relevant example here is its **PM4 command stream**, which includes state-setting and draw packets. This proposal borrows that organization and defines much smaller, project-specific packets. The command numbers below are ours; they are not AMD binary encodings. [AMD-authored command definitions in the Linux driver](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/amdgpu/sid.h)

## Seven commands

The GPU executes commands in order. Camera and view settings remain in effect until changed. Reset selects a camera at the origin, zero pitch/yaw, focal length 320.0, and near distance 1.0. All drawing targets the **back buffer**, while video output reads the **front buffer**.

| Command | Header word | Following 32-bit words, in order | What it does |
| --- | --- | --- | --- |
| `NOP` | `00000000` | None | Does nothing; useful for padding. |
| `SET_FRAMEBUFFERS` | `01050000` | Buffer A offset; buffer B offset; width; height; row stride in bytes | Chooses two DDR image buffers. Initially A is front and B is back. |
| `SET_VIEW` | `02020000` | Focal length in pixels; near-plane distance | Sets projection size and the closest visible distance. Both values use the fixed-point format below. |
| `SET_CAMERA` | `03050000` | Camera X; Y; Z; pitch; yaw | Sets where the camera is and its rotation. |
| `CLEAR` | `04010000` | Color | Fills the back buffer with one color. |
| `DRAW_TRIANGLES` | `05030000` | Vertex-data offset; vertex count; color | Reads vertices from DDR and draws solid triangles using the current camera and view. |
| `PRESENT` | `06010000` | Frame ID | Finishes rendering, switches front/back at vertical blank, and reports that frame ID to the CPU. |

For `DRAW_TRIANGLES`, every three vertices form one triangle: vertices 0-2, then 3-5, and so on. The count is a **vertex count**, must be divisible by three, and may be zero for no drawing. All triangles in that command use its color. Send another draw command to use a different color.

`SET_FRAMEBUFFERS` is allowed once after reset, as the first non-NOP command. Start with 640 x 480; the supplied dimensions must match the supported video mode. Other modes can be added later. The buffers must be distinct, non-overlapping, and large enough for their stride times height. Stride must be a multiple of four and at least width times four. Output stays black until the first successful `PRESENT`. Each frame starts with `CLEAR` before any draw or present, so the whole image has a defined background.

## How a command is stored

Each command starts with one 32-bit header. Parameters follow as complete 32-bit words.

| Header bits | Meaning |
| --- | --- |
| 31-24 | Command number: `00` through `06` above. |
| 23-16 | Number of parameter words following this header. This excludes the header itself. |
| 15-0 | Reserved; send zero in version 1. |

For example, **`05030000`** means **command 5, followed by 3 parameter words**. The next three words are the vertex-data offset, vertex count, and color. The decoder treats those three words as data, regardless of their contents.

All words use little-endian byte storage in DDR. Commands and vertex records begin on four-byte boundaries. A CPU app normally builds these words for you; you would not hand-enter hex for every frame.

## Numbers and DDR data

**Proposed coordinate format: signed Q16.16.** This selects 16 fractional bits within your chosen 32-bit width. Stored value = real value times 65,536. The integer part includes the sign bit. Internal multiplication/division can use wider temporary results to preserve accuracy.

| Value | Stored 32-bit hex |
| --- | --- |
| -1.0 | `FFFF0000` |
| 0.5 | `00008000` |
| 1.0 | `00010000` |
| 4.0 | `00040000` |
| 320.0 | `01400000` |

Each vertex occupies **12 bytes: X, then Y, then Z**, all Q16.16 world coordinates. Camera X/Y/Z use that same format. Pitch and yaw are unsigned whole degrees from 0 to 359, stored in 32-bit words to suit the existing degree-indexed LUT. Dimensions, counts, IDs, and memory offsets are ordinary unsigned integers.

Use positive X for right, positive Y for up, and positive camera-space Z for forward. Pitch/yaw specify the view rotations applied to camera-relative vertices, using the current `Projector` signs and order: subtract camera position, then pitch, then yaw. With the other angle zero, a small positive pitch moves a forward point downward on screen; a small positive yaw moves it leftward. Screen coordinates have their origin at the top-left. After rotation, the projection is:

- Screen X = width / 2 + focal length times X / Z.
- Screen Y = height / 2 - focal length times Y / Z.

At 640 x 480, focal length **320.0** gives a 90-degree horizontal field of view. Use near distance **1.0** initially. Both parameters must be positive. Triangles crossing that plane need clipping before division; triangles crossing screen edges need their visible portions retained. Only pixels inside the framebuffer may be written.

**Proposed color format: `00RRGGBB`, one 32-bit word per pixel.** `00FF0000` is red; `00000000` is black. The upper byte is zero. There is no transparency in version 1. One 640 x 480 buffer uses 1,228,800 bytes; two use 2,457,600 bytes.

The CPU reserves one DDR region for GPU use. Every offset in this protocol is a **byte offset from the start of that region**, not a CPU virtual pointer. Its physical base address and size are configured during setup, outside the command stream. A 64-bit base lets the region live above the 4 GB physical-address boundary while packets keep simple 32-bit offsets. The driver must supply the address visible to the FPGA. Every entire access must fit within the region; offsets must never wrap. Commands, vertex data, and framebuffers occupy non-overlapping allocations.

## Example: show one red triangle

Assume the CPU reserved an 8 MiB GPU DDR region. Put these vertices at region offset `00001000`:

| Vertex | Position (X, Y, Z) | Three stored words | Ideal screen position |
| --- | --- | --- | --- |
| A | (-1, -1, 4) | `FFFF0000 FFFF0000 00040000` | (240, 320) |
| B | (1, -1, 4) | `00010000 FFFF0000 00040000` | (400, 320) |
| C | (0, 1, 4) | `00000000 00010000 00040000` | (320, 160) |

Put the following command list at offset `00002000`. Read each row from left to right, then continue to the next row. These are packet values, not a shader program.

| Request | Header followed by its parameter words |
| --- | --- |
| Choose two buffers, 640 x 480, 2,560 bytes per row | `01050000 00100000 00300000 00000280 000001E0 00000A00` |
| Focal length 320.0; near distance 1.0 | `02020000 01400000 00010000` |
| Camera at origin; zero pitch and yaw | `03050000 00000000 00000000 00000000 00000000 00000000` |
| Clear the back buffer to black | `04010000 00000000` |
| Draw three vertices from offset 0x1000 in red | `05030000 00001000 00000003 00FF0000` |
| Present frame ID 1 | `06010000 00000001` |

That list contains **23 words / 92 bytes**. The GPU draws a centered red triangle on black into buffer B, then switches video output to B. A becomes the back buffer for the next frame. For later frames, omit the initial buffer configuration and submit whichever camera/view changes are needed, a clear, drawing commands, and a final present.

## CPU submission and completion

For the first version, allow **one submitted frame list at a time**:

1. The CPU writes the vertices and command list into the reserved DDR region.
2. It makes those writes visible to the FPGA, using the cache/coherency procedure appropriate to the eventual Kria system.
3. Through a small memory-mapped control interface, it supplies the list offset and word count, then requests START. The control interface sets CPU-visible BUSY before acknowledging that START, even if the rendering clock is separate. The CPU can continue its application work.
4. The GPU reads and executes the list. Require exactly one `PRESENT`, as its final command. Video output continues reading the front buffer throughout rendering.
5. `PRESENT` waits for all earlier geometry reads and pixel writes to finish, then swaps the buffers at the next safe vertical blank. It publishes PRESENTED_ID and clears BUSY. The CPU may now reuse the list and vertex allocations.

The CPU leaves submitted data untouched from issuing START until completion, including while awaiting START acceptance. After acceptance, BUSY clearing means the submission has finished; check ERROR and PRESENTED_ID to distinguish failure from success. Do not start another list until completion. Frame IDs identify successful presentations; they do not indicate completion of every physical screen scan. Framebuffer ownership belongs to the GPU while active. The control interface also exposes protocol VERSION; its register addresses and the exact PS-to-PL connection are implementation details to choose with the confirmed board.

Reject unknown commands, incorrect parameter counts, nonzero reserved bits, invalid parameters, and out-of-range addresses. On error, stop new work, finish outstanding DDR accesses, report ERROR, and clear BUSY without presenting the unfinished frame. Keep the previous image displayed. Reset/reinitialize before accepting another list. Reaching the supplied word count without a final complete `PRESENT` is an error.

## Growing the GPU

Version 1 draws opaque, flat-colored triangles in submission order, without backface culling or a depth buffer. Later triangles overwrite earlier pixels. The CPU can send distant objects first for simple scenes; this cannot correctly resolve every intersecting 3D scene.

Reserve new command numbers for depth testing, indexed meshes, textures, model transforms, and image copies. Keep the existing packet meanings and XYZ vertex layout unchanged; add a new draw command when a richer vertex layout is needed. A future command ring can allow several queued frames using the same packet format. Unsupported commands must report an error until implemented.

**Current implementation gap:** the repository's point projector still accepts 16-bit coordinates with 8 fractional bits, and its framebuffer is monochrome/read-only. This document defines the proposed 32-bit GPU interface. Integration will need the matching coordinate datapath, triangle clipping/rasterization, DDR writes, command handling, and buffer presentation. No hardware implementation is included here.

## References and board context

- [AMD-authored PM4 definitions, Linux amdgpu driver](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/amdgpu/sid.h): reference for the idea of command packets, graphics state, and draw requests. This document defines its own encodings and behavior.
- [AMD Kria SOM overview](https://docs.amd.com/v/u/en-US/xd043-kria-som): reference for the Kria processing-system and programmable-logic development model. The exact user's board, DDR mapping, and video connector remain unspecified.

Project decision recorded on 25 September 2026: **onboard CPU + DDR for the computer; custom FPGA GPU for rendering and video; 32-bit fixed-point coordinates.**
