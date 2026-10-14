# Project context

- The user's hardware target is the AMD Kria KV260 (K26). Use the KV260
  implementation for current hardware work.
- The active hardware project is created by `kv260/create_project.tcl` and
  built with `kv260/run.ps1 hardware`. Its full system top is `system_wrapper`;
  the custom graphics RTL top inside it is `KV260_GPU`.
- CPU/display sources are under `kv260/software/`; the compact runtime and
  build helpers are under `kv260/small/`. Generated files under `small/build/`
  are not the source of truth.
- The root `VGA_PROJ.xpr` is a clean RTL source view of the current custom KV260
  graphics design, with `KV260_GPU` as top. It references the real sources,
  has no board preset or pin constraints, and is not the board build project.
  Refresh/check it using `scripts/update_design_view.tcl` in Vivado.
- `kv260/graphics_sources.tcl` defines the same seven custom RTL sources for
  both the root design view and the full hardware build. Keep these aligned.
- The Basys 3 constraints and original VGA top remain legacy material on disk.
  Do not apply Basys 3 device or pin settings to KV260 hardware work.
- Shared graphics RTL lives under `VGA_PROJ.srcs/sources_1/new/` and is reused
  by the KV260 design and simulation tests.
- Run `kv260/test.ps1` for the controller simulation. Use the relevant scripts
  under `verilator/` when changing shared graphics modules.
- Keep generated Vivado output, executables and the downloaded ARM toolchain
  out of version control. See `README.md`, `kv260/README.md` and `kv260/STATUS.md`
  for build instructions, current scope and recorded bring-up results.
