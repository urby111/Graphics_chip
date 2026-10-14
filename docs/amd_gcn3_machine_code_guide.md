# AMD GCN3 machine code: a beginner's field guide

This is a compact guide to the **real AMD Graphics Core Next, generation 3 (GCN3)** instruction encoding. It is modeled on the format-and-examples style of the RISC-V sheet, but GCN3 is **not RISC-V** and does not have one universal instruction layout. The examples below are encoded from AMD's documented bit fields and opcodes, not invented opcodes. They are **not instructions that the current FPGA project can run**; doing that would require a compatible instruction decoder and execution hardware.

Source: [AMD, *Graphics Core Next Architecture, Generation 3*, revision 1.1 (August 2016)](https://docs.amd.com/v/u/en-US/gcn3-instruction-set-architecture), especially chapters 3, 5, 6, 12, and 13. Chapter 13 is the authoritative bit-field reference.

## 1. The idea behind a GCN instruction

An instruction is a **32-bit word** (sometimes followed by another 32-bit word) or an inherently **64-bit instruction**. Its high bits identify a *format family*. The remaining fields select an operation, source registers/constants, and sometimes a destination. A program is a sequence of these words in memory. GCN uses **little-endian** byte ordering: for example, the word `0x80020100` appears as bytes `00 01 02 80` at increasing byte addresses. [AMD ch. 13, pp. 13-1 to 13-2](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=285)

GCN executes **wavefronts of 64 lanes**. An `s_` (scalar) instruction works on one value shared by the wavefront in an **SGPR**. A `v_` (vector) instruction works on each active lane's own value in a **VGPR**. The 64-bit `EXEC` mask selects which lanes write vector results. So `v_add_f32 v0, v1, v2` means up to 64 separate additions, not one 64-bit addition. [AMD ch. 3 and ch. 6](https://docs.amd.com/v/u/en-US/gcn3-instruction-set-architecture)

## 2. Core 32-bit instruction layouts

Read each row **left to right from bit 31 down to bit 0**. The fixed prefix identifies the family. `OP` means the opcode **within that family**; opcode `1` can mean different things in different families. The brackets show exact bit positions. [AMD ch. 5, sec. 5.1; ch. 6, sec. 6.1; ch. 13](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=43)

| Family | Bits 31 down to 0 | Purpose |
| --- | --- | --- |
| **SOP2** | `[31:30] 10; [29:23] OP; [22:16] SDST; [15:8] SSRC1; [7:0] SSRC0` | Scalar operation with two sources and one destination. |
| **SOPK** | `[31:28] 1011; [27:23] OP; [22:16] SDST; [15:0] SIMM16` | Scalar operation with a 16-bit immediate. |
| **SOP1** | `[31:23] 101111101; [22:16] SDST; [15:8] OP; [7:0] SSRC0` | Scalar operation with one source. |
| **SOPC** | `[31:23] 101111110; [22:16] OP; [15:8] SSRC1; [7:0] SSRC0` | Scalar comparison; writes the scalar condition code `SCC`. |
| **SOPP** | `[31:23] 101111111; [22:16] OP; [15:0] SIMM16` | Control flow, waits, and program end. |
| **VOP2** | `[31] 0; [30:25] OP; [24:17] VDST; [16:9] VSRC1; [8:0] SRC0` | Vector operation with two sources. |
| **VOP1** | `[31:25] 0111111; [24:17] VDST; [16:9] OP; [8:0] SRC0` | Vector operation with one source. |
| **VOPC** | `[31:25] 0111110; [24:17] OP; [16:9] VSRC1; [8:0] SRC0` | Vector comparison; normally writes the `VCC` lane mask. |

The `SRC0` field in these short vector formats is **9 bits** because it can choose an SGPR, a small inline constant, a literal, or a VGPR. `VSRC1` is only **8 bits** and selects a VGPR number directly. `VDST` also selects a VGPR number directly. [AMD ch. 13, VOP2/VOP1/VOPC](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=302)

## 3. How source numbers work

For scalar `SSRC` and vector `SRC0`, the number in the source field is **not always a register number**:

| Encoded source number | Meaning |
| --- | --- |
| `0` through `101` | `s0` through `s101` (subject to the particular field/instruction). |
| `128` | Integer zero. |
| `129` through `192` | Inline integers `1` through `64`; for example, `130` means integer `2`. |
| `193` through `208` | Inline integers `-1` through `-16`. |
| `240`, `242`, `244` | Floating-point `0.5`, `1.0`, `2.0`, respectively. These are **different** from inline integer values. |
| `255` | The **next 32-bit word** supplies a literal constant. |
| `256` through `511` | `v0` through `v255` **only in a 9-bit vector source field**; for example, `257` means `v1`. |

This is a selection of the source codes, not the whole register/special-value table. A short instruction using source code `255` consumes an extra word; do not mistake that second word for another instruction. [AMD ch. 5, table 5.1; ch. 6, table 6.1](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=56)

## 4. Small opcode reference

These are **opcode-field values**, not whole instruction words. The instruction's family determines where the opcode bits go. [AMD ch. 12; ch. 13](https://docs.amd.com/v/u/en-US/gcn3-instruction-set-architecture)

| Family | Instruction | OP decimal | Meaning |
| --- | --- | ---: | --- |
| SOP2 | `s_add_u32` | 0 | Add two scalar unsigned 32-bit values; `SCC` receives carry-out. |
| SOP2 | `s_sub_u32` | 1 | Subtract scalar 32-bit values. |
| SOP2 | `s_add_i32` | 2 | Signed add; `SCC` indicates signed overflow. |
| SOP1 | `s_mov_b32` | 0 | Copy one 32-bit scalar value. |
| SOPK | `s_movk_i32` | 0 | Sign-extend `SIMM16` into a scalar register. |
| SOPP | `s_nop` | 0 | No operation. |
| SOPP | `s_endpgm` | 1 | End the wavefront program. |
| SOPP | `s_branch` | 2 | Branch by a signed number of 32-bit words relative to the **next** instruction. |
| SOPP | `s_waitcnt` | 12 | Wait for outstanding memory/export operations. |
| VOP1 | `v_mov_b32` | 1 | Copy one 32-bit vector value per active lane. |
| VOP2 | `v_add_f32` | 1 | Add two 32-bit floating-point values per active lane. |
| VOP2 | `v_mul_f32` | 5 | Multiply two 32-bit floating-point values per active lane. |
| VOP2 | `v_add_u32` | 25 | Add two 32-bit integers per active lane; carry goes to `VCC`. |

## 5. Worked machine-code examples

All hex values below are **full 32-bit instruction words**. In the breakdown, `<<` means “place this field at that bit position.”

### Example A: scalar immediate

```text
s_movk_i32 s4, 42
SOPK: 1011 | OP=0 | SDST=4 | SIMM16=0x002A
       0xB0000000 | (4 << 16) | 0x002A = 0xB004002A
```

Result: the wavefront's shared register `s4` becomes `42`. The immediate lives **inside** the 32-bit instruction; there is no extra word. [AMD ch. 12, SOPK](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=123)

### Example B: scalar register add

```text
s_add_u32 s2, s0, s1
SOP2: 10 | OP=0 | SDST=2 | SSRC1=1 | SSRC0=0
       0x80000000 | (2 << 16) | (1 << 8) | 0 = 0x80020100
```

Result: `s2 = s0 + s1` (low 32 bits). If `s0=2` and `s1=3`, then `s2=5`. The same operation is shared by the whole wavefront. [AMD ch. 12, SOP2](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=108)

### Example C: vector floating-point add

```text
v_add_f32 v0, v1, v2
VOP2: 0 | OP=1 | VDST=0 | VSRC1=2 | SRC0=257 (v1)
       (1 << 25) | (0 << 17) | (2 << 9) | 257 = 0x02000501
```

For each lane enabled by `EXEC`, that lane's `v0 = v1 + v2`. Notice the asymmetry: `v1` is encoded as `256+1` in the 9-bit `SRC0` field; `v2` is encoded simply as `2` in the 8-bit `VSRC1` field. [AMD ch. 13, VOP2](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=302)

### Example D: a literal makes a two-word instruction

```text
s_mov_b32 s5, 0x12345678
SOP1 word: 101111101 | SDST=5 | OP=0 | SSRC0=255
            0xBE800000 | (5 << 16) | 255 = 0xBE8500FF
Next word:  0x12345678
```

The instruction stream contains `BE8500FF` then `12345678`. The `255` source code tells the GPU to consume the next word as data, so the next instruction starts **8 bytes** after this one. [AMD ch. 13, SOP1](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=292)

### Example E: branch and end

```text
s_branch +2   -> 0xBF820002
s_endpgm      -> 0xBF810000
```

For `s_branch +2`, the new byte address is `old PC + 4 + (2 × 4)`: it skips **two 32-bit words** after the branch. A branch offset is not a pixel address or a byte count. `s_endpgm` terminates the wavefront. [AMD ch. 12, SOPP](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=144)

## 6. A tiny complete scalar example

This is a sequence of real GCN3 instruction words. It sets `s0=2`, sets `s1=3`, adds them to get `s2=5`, then ends the program. It does **not** draw a pixel; it only shows fetch/decode/execute clearly.

| Word address | Machine-code word | Assembly | Effect |
| ---: | --- | --- | --- |
| 0 | `B0000002` | `s_movk_i32 s0, 2` | `s0 = 2` |
| 1 | `B0010003` | `s_movk_i32 s1, 3` | `s1 = 3` |
| 2 | `80020100` | `s_add_u32 s2, s0, s1` | `s2 = 5` |
| 3 | `BF810000` | `s_endpgm` | Stop |

If kept in a word-wide `.hex` file, those are four consecutive lines in that order. A raw byte stream would use little-endian bytes for each word. Actual execution on AMD hardware also requires a valid shader/wavefront setup; these words alone are not a complete host-side GPU command.

## 7. The larger instruction families

The simple ALU formats above are only part of the ISA. AMD's format summary includes these **64-bit** families, each with its own bit diagram and operand rules in chapter 13. They are listed here so the 32-bit examples are not mistaken for the whole GPU. [AMD ch. 13, table 13.1](https://docs.amd.com/api/khub/documents/BOZRy1GZ1qQslfQPnq~96Q/content#page=285)

| Family | Main job |
| --- | --- |
| `SMEM` | Load/store shared scalar data through the scalar memory path. |
| `VOP3` | More capable vector ALU form: up to three sources and input/output modifiers. |
| `DS` | Local Data Share / Global Data Share operations. |
| `MUBUF` / `MTBUF` | Vector buffer memory access, including formatted buffer access. |
| `MIMG` | Image/texture memory access. |
| `FLAT` | Per-lane memory access using a flat address. |
| `EXP` | Export vertex position/parameters or pixel color/depth from shader registers. |

The manual also defines specialized 32-bit `VOP_SDWA`, `VOP_DPP`, and `VINTRP` formats. Their fields are omitted from this beginner sheet; use chapter 13 before encoding them.

For your FPGA GPU, the useful *idea* is to start with a small, documented subset (for example, move, add, load, branch, draw/export) and grow it. **Using AMD's exact binary encoding would require implementing its register model, lane behavior, masks, formats, and memory semantics**, not just copying an opcode table.
