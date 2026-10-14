# Sine and cosine table

Standalone module: `sin_cos_lut`. It contains 360 signed 16-bit sine entries,
one per degree. Cosine uses a second read at angle + 90 degrees.

| Port | Meaning |
| --- | --- |
| `clk` | Input clock |
| `angle_deg[8:0]` | Unsigned integer angle in degrees, normally 0 through 359 |
| `sin_value[15:0]` | Signed sine result |
| `cos_value[15:0]` | Signed cosine result |

Set the angle before a rising edge. Both results update just after that edge.
There is no reset or enable; outputs are not valid until the first rising edge.
Values 360 through 511 wrap to 0 through 151. Negative angles are not accepted;
normalize them to 0 through 359 before assigning the unsigned input.

Results use signed Q1.15 fixed point: divide the integer by 32768 to obtain
the real value. +1 is approximated as 32767/32768; -1 is exactly -32768/32768.

| Angle | Sine integer | Cosine integer |
| --- | --- | --- |
| 0 | 0 | 32767 |
| 30 | 16384 | 28378 |
| 90 | 32767 | 0 |
| 180 | 0 | -32768 |
| 270 | -32768 | 0 |

Example connection for later use:

```verilog
wire signed [15:0] sin_theta;
wire signed [15:0] cos_theta;

sin_cos_lut trig (
    .clk(clk),
    .angle_deg(angle_deg),
    .sin_value(sin_theta),
    .cos_value(cos_theta)
);
```

For coordinate multiplication, use signed operands and a wide product, then
arithmetic-shift the product right by 15 to remove the sine/cosine scale.
Do not truncate the product to 16 bits before shifting.

The constants are initialized inside the Verilog file, so there is no hex
file path to configure. Storage is 360 × 16 = 5760 logical bits with two
read ports; the physical BRAM/LUT mapping depends on synthesis. The module
is registered as a source in the Vivado project. `Projector` now instantiates
it twice for pitch and yaw; neither module is connected to the VGA top yet.

Run its standalone test from the project root:

```powershell
.\verilator\test_sin_cos.ps1
```
