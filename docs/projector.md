# Projector

`Projector.v` implements the supplied equations with registered arithmetic:

```text
x = vertex_x - camera_x
y = vertex_y - camera_y
z = vertex_z - camera_z

x1 = x
y1 = y*cos(pitch) - z*sin(pitch)
z1 = y*sin(pitch) + z*cos(pitch)

x2 = x1*cos(yaw) - z1*sin(yaw)
y2 = y1
z2 = x1*sin(yaw) + z1*cos(yaw)

x_2d = x2 / z2
y_2d = y2 / z2
```

All logic is inside `Projector` except two instances of the existing
`sin_cos_lut`: one for pitch, one for yaw. The signs and rotation order match
the supplied equations. The module is standalone; it is not wired into VGA.

## Inputs and outputs

| Port | Format | Meaning |
| --- | --- | --- |
| `clk` | 1 bit | Pipeline clock; 100 MHz is the design target. |
| `rst` | 1 bit | Synchronous active-high reset. Flushes all pending vertices. |
| `in_valid` | 1 bit | Accept the inputs on this rising edge when reset is low. |
| `vertex_x`, `vertex_y`, `vertex_z` | Signed 16 bits, 8 fractional bits | World-space vertex. |
| `camera_x`, `camera_y`, `camera_z` | Signed 16 bits, 8 fractional bits | World-space camera position. |
| `pitch_deg`, `yaw_deg` | Unsigned 9-bit integer degrees | 0..359 normally; 360..511 wrap as in the LUT. |
| `out_valid` | 1 bit | This edge produced a result for an accepted vertex. |
| `x_2d`, `y_2d` | Signed 32 bits, 16 fractional bits | Normalized projected coordinates. |
| `depth` | Signed 19 bits, 8 fractional bits | Rotated camera-space `z2`. |
| `clipped` | 1 bit | `z2 <= 0`, including zero depth; projected outputs are zero. |
| `overflow` | 1 bit | A positive-depth projected coordinate exceeded the output range and saturated. |

Set vertex, camera, and angles before the same rising edge. Each accepted
vertex carries its own angles and camera position through the pipeline. Inputs
may change every cycle. There is no `busy` or `ready` signal and no output
backpressure: the receiver must consume each result when `out_valid` is high.
Use the result only when `out_valid && !clipped && !overflow`.
Output data and flags are otherwise unspecified when `out_valid` is low.

Assert `rst` for at least one rising edge before use. Vertices already in flight
are discarded by reset; `out_valid` stays low until a new vertex completes.

## Fixed point examples

Input coordinates are scaled by 256: `1.0 = 256`, `2.0 = 512`, `-0.5 = -128`.
Their range is -128 through 127.99609375. Internal coordinates are widened
before subtraction and multiplication, so subtracting opposite-sign input
endpoints does not overflow a 16-bit intermediate.

The LUT uses Q1.15, with `1.0` approximated by `32767/32768`. Rotation products
are kept at full width before addition/subtraction, then shifted right by 15
bits. Each rotation truncates toward negative infinity to retain eight
fractional coordinate bits. Even a zero-degree rotation can therefore change
a coordinate slightly; this is the existing LUT precision, not a latency bug.

Projection divides `(abs(coordinate) << 16)` by positive `z2`, then restores
the sign. This preserves the output's fractional bits and truncates toward
zero. Do not divide two integers first and shift afterward: that loses the
fractional result. Output `65536` means 1.0 and `32768` means 0.5.

Positive overflow saturates to `32'h7FFFFFFF`; negative overflow saturates to
`32'h80000000`. For nonpositive depth both projected coordinates are zero,
`clipped=1`, and `overflow=0`. There is no configurable near plane yet.
Coordinates outside the visible viewing region are not automatically rejected.

Example: vertex `(2,1,4)`, camera `(0,0,0)`, pitch=0, yaw=0.
Send input integers `(512,256,1024)`. The exact fixed-point output is
`x_2d=32768`, `y_2d=16351`, and `depth=1022`: approximately `(0.5,0.2495)`.
The small difference from `(0.5,0.25)` comes from LUT and rotation truncation.

These outputs are ratios, not screen pixel addresses. Focal-length scaling,
screen-center offsets, screen-Y orientation, and triangle rasterization belong
after this module and are not implemented here.

## One clock per arithmetic step

The four conceptual operations are split into smaller register-to-register
steps to target a 10 ns clock period. A full wide division is not placed in
one clock cycle.

| Edge relative to input capture | Registered operation |
| --- | --- |
| N | Subtract camera; both LUTs look up the angles. |
| N+1 | Four pitch multiplications. |
| N+2 | Pitch add/subtract and fixed-point truncation. |
| N+3 | Four yaw multiplications. |
| N+4 | Yaw add/subtract and fixed-point truncation. |
| N+5 | Prepare both unsigned divisions, signs, and depth flag. |
| N+6 through N+40 | 35 divider steps, one quotient bit per registered step for both coordinates. |
| N+41 | Restore signs, saturate, and output the result and flags. |

**Latency is 41 clock periods after input capture.** This is 42 registered
stages when counting the input-capture stage itself. The pipeline can accept
one vertex every cycle and, after filling, output one result every cycle.
At a 100 MHz clock the intended latency is 410 ns. Bubbles in `in_valid` appear
as matching bubbles in `out_valid`, 41 cycles later.

The dividers are unrolled into separate registered stages, not a single reused
divider that blocks later vertices. This trades registers and logic for
throughput. No claim of 100 MHz timing closure is made: only behavioral tests
were requested and completed. Vivado implementation timing remains necessary
before relying on that frequency on hardware.

## Connecting it later

```verilog
wire signed [31:0] projected_x, projected_y;
wire signed [18:0] projected_depth;
wire projected_valid, projected_clipped, projected_overflow;

Projector projector (
    .clk(clk), .rst(rst), .in_valid(vertex_valid),
    .vertex_x(vertex_x), .vertex_y(vertex_y), .vertex_z(vertex_z),
    .camera_x(camera_x), .camera_y(camera_y), .camera_z(camera_z),
    .pitch_deg(pitch_deg), .yaw_deg(yaw_deg),
    .out_valid(projected_valid),
    .x_2d(projected_x), .y_2d(projected_y), .depth(projected_depth),
    .clipped(projected_clipped), .overflow(projected_overflow)
);
```

## Behavioral test

From the project root:

```powershell
.\verilator\test_projector.ps1
```

The Verilator test uses independent wide software arithmetic for the equations
and ordinary software division as its reference. It checks exact fixed-point
results and depth, the 41-cycle valid delay, consecutive vertices, input gaps,
changing per-vertex angles, all 512 angle encodings, extreme coordinates,
zero/negative depth, saturation, and reset while vertices are in flight.

Latest run: **7325 completed vertices passed**, including 3654 clipped results
and 3 saturated results. This is functional verification, not a timing test.
