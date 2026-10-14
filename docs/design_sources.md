# Design sources and pipeline status

The current display path is `font_aligned.hex → System_Memory → vga_3colors → VGA output`. It shows a stored, static image. The 3D projector exists as a separate module but is **not connected** to that display path yet.

| Design source | What it does |
| --- | --- |
| `vga_3colors.v` | Current top-level display module. Generates VGA timing, requests pixels from memory, and drives the VGA color and sync outputs. |
| `System_Memory.v` | Loads `font_aligned.hex` into a framebuffer and returns the pixel requested by the VGA module. Its current interface only reads pixels. |
| `Projector.v` | Takes one 3D vertex plus camera position and angles, then calculates a camera-relative, rotated, perspective-projected 2D point. Also reports clipped or overflow results. Not connected to the VGA top level. |
| `sin_cos_lut.v` | Supplies fixed-point sine and cosine values for an angle. `Projector` uses it for pitch and yaw. |
| `temp.v` | Older, unused memory/display experiment with a hard-coded font file path. It is not part of the current display path. |

The intended 3D path would feed vertices into `Projector`, turn projected geometry into pixels, write those pixels to a framebuffer, and then let the VGA module display that buffer. The geometry-to-pixels stage and framebuffer write connection have not been built yet.
