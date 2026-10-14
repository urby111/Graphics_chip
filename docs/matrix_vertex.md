# Matrix_Vertex

`VGA_PROJ.srcs/sources_1/new/Matrix_Vertex.v` stores a 4x4 matrix and computes
`matrix * (vertex_x, vertex_y, vertex_z, 1)` for each accepted vertex. The four
outputs are X, Y, Z, W **before perspective division**. The matrix may be general;
the fourth row is evaluated independently, even though the current C generator
produces equal third and fourth rows. The old Projector is preserved for reference.

## Loading and using the matrix

All transfers take place on rising clock edges with both valid and ready high.
Hold valid and its data steady until accepted. Reset is synchronous, active high;
it discards partial matrix loads and all pending vertices. Reload all 16 words
after reset. Data outputs are meaningful only when `out_valid` is high.

1. Assert `matrix_valid` and send 16 signed 32-bit words on `matrix_data`.
   Order: m00, m01, m02, m03, m10, ... m33, exactly as printed by
   `gpu_matrices.c`. Gaps between words are allowed. There is no per-word index.
2. The module sets `matrix_loaded` after accepting word 16. Before that it will
   not accept vertices. A partial load must be completed or cancelled by reset.
3. Send X, Y, Z together with `vertex_valid`; acceptance requires `vertex_ready`.
   Coordinates are local to the object when using the C-generated matrix.
4. Read all four results and `out_overflow` when `out_valid && out_ready`.
   Set `out_ready=1` if the receiver can always accept results.
5. To change the matrix, begin another 16-word transfer. A pending matrix request
   stops new vertex acceptance. `matrix_ready` stays low until the entire old
   pipeline has drained, including consumption of any stalled result. The first
   matrix word clears `matrix_loaded`, and word 16 sets it again. Old/new matrix
   words can never be mixed for an accepted vertex.

The first matrix word wins if matrix and vertex requests arrive together while
the pipeline is empty. A continuously asserted valid represents a transfer on
**every** ready edge; remove it or advance data after acceptance.

The command decoder can feed the 16 payload words of a future `SET_MATRIX`
packet directly into this port, then stream a draw's vertex records. This module
does not decode headers, read DDR, or assign a new opcode to the existing command
set. Those interfaces are separate implementation work.

## Numbers and pipeline

Inputs and outputs are signed 32-bit Q16.16: 1.0 = `00010000`. Input W is fixed
at 1.0, so each row needs three multiplications and an added translation term.
There are 12 parallel 32x32 multipliers, not necessarily 12 physical DSP slices.

Products retain 64 bits and 32 fractional bits; adders widen to 65 then 66 bits.
Only the final stage discards 16 fractional bits, rounding toward negative
infinity. Values outside signed Q16.16 saturate, rather than wrap. Overflow bits
0,1,2,3 correspond to X,Y,Z,W. A flagged coordinate needs handling downstream;
it is not a valid unsaturated result. Large focal-scaled coordinates can overflow
even when their later ratio would fit, so this 32-bit output range is a real
limit. It is not a clip or near-plane indication.

| Edge without stalls | Operation |
| --- | --- |
| N | Capture vertex |
| N+1 | Multiply and align the fourth coefficient |
| N+2 | Add pairs |
| N+3 | Add the two partial sums |
| N+4 | Truncate, saturate, publish X/Y/Z/W and flags |

Latency is four clock periods after acceptance (five registered stages counting
capture). With a constant matrix and a ready receiver, the pipeline accepts one
vertex each clock and produces one result each clock after filling. If a valid
output is blocked, all arithmetic and valid registers hold together. Latency
then increases by the number of stalled clocks. Results remain stable until
accepted. `out_valid` is cleared on the reset edge; ready signals are low while
reset is asserted.

The 100 MHz goal informed the registered multipliers and balanced adder tree,
but only behavioral simulation is used here. No synthesis, implementation,
frequency estimate, or timing-closure claim is made. The project's existing
Artix-7 device selection is unchanged.

## Behavioral test

From PowerShell in the project folder:

```powershell
.\verilator\test_matrix_vertex.ps1
```

The Verilator C++ test uses independent signed 128-bit arithmetic. It checks
matrix order, all four outputs, fractional truncation, saturation, full-range
inputs, streaming latency, bubbles, output stalls, matrix replacement, partial
loads, reset, and the matrix words printed by the C program. This is functional
simulation, not a clock-speed measurement.

Verified run: **4,365 results checked**, four pending vertices deliberately
discarded by reset, 2,049 saturated results, and 663 accepted matrix words.
All checks passed with Verilator 5.020, including its `-Wall` RTL checks.

With the C generator's matrix, X/Y already include focal length. Later stages
must divide by W, add the screen centre and invert Y; they must not multiply by
focal length again. Triangle clipping still belongs before perspective division.
