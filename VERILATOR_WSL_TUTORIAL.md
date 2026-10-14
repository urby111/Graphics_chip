# How Verilator works on this Windows system

This machine does **not** expose Verilator as a native Windows executable in
PowerShell. Verilator is installed inside WSL (Ubuntu/Linux):

```text
/usr/bin/verilator
Verilator 5.020 2024-01-01 rev (Debian 5.020-1)
/usr/bin/g++
/usr/bin/make
```

That distinction is the key. `Get-Command verilator` in PowerShell can fail even
though Verilator is installed and working. Do not spend time adding
`/usr/bin/verilator` to the Windows `PATH`; Windows cannot directly run a Linux
ELF executable. Invoke it through `wsl.exe`.

## Quick verification from PowerShell

Run:

```powershell
wsl --exec bash -lc 'command -v verilator; verilator --version; command -v g++; command -v make'
```

Expected output includes:

```text
/usr/bin/verilator
Verilator 5.020 2024-01-01 rev (Debian 5.020-1)
/usr/bin/g++
/usr/bin/make
```

If Codex runs commands in a filesystem sandbox, the first `wsl` call may fail
with `Wsl/Service/CreateInstance/E_ACCESSDENIED`. That is a sandbox permission
failure, not a missing `PATH`. Codex should rerun the same command with elevated
sandbox permission and explain that it needs permission to invoke WSL. In this
session, approving a scoped prefix for the following command family worked:

```text
wsl --exec bash
```

## Project path behavior

The Windows project is:

```text
C:\Users\troyv\Desktop\projects\fpga\project_1
```

WSL mounts it as:

```text
/mnt/c/Users/troyv/Desktop/projects/fpga/project_1
```

When `wsl --exec bash ...` is launched while PowerShell is already in the project
directory, WSL on this machine starts in the corresponding `/mnt/c/...` directory.
Still, scripts should explicitly change to their own project directory so they do
not depend on the caller's current directory.

To run a one-off command with an explicit directory:

```powershell
wsl --exec bash -lc 'cd /mnt/c/Users/troyv/Desktop/projects/fpga/project_1 && verilator --version'
```

## Run the regression already created for this CPU

From PowerShell in the project directory:

```powershell
wsl --exec bash tests/run_verilator.sh
```

The script is [tests/run_verilator.sh](tests/run_verilator.sh). It checks the
tool version, lints, compiles the SystemVerilog testbench into a native Linux
binary, and runs it. Logs are written under `tests/build/`.

To generate a VCD waveform as well:

```powershell
wsl --exec bash tests/run_verilator.sh +trace
```

The waveform is written to `tests/build/cpu.vcd`.

The regression intentionally exits nonzero while known CPU checks fail. That
means a final Verilator assertion is a test result, not evidence that Verilator
was not found. Look for the summary immediately before the assertion, for
example:

```text
RESULT: 444 checks, 416 passed, 28 failed
```

## Exact compile strategy used

The CPU has an unused legacy file, `SL_Unit.v`, with a syntax error. Passing
every `*.v` file to Verilator therefore fails before simulation. For the actual
CPU regression, I asked Verilator to discover only modules reachable from the
testbench and `main`:

```bash
verilator --binary --timing --trace -Wno-fatal \
  --top-module cpu_regression \
  --Mdir tests/build/obj \
  -j 4 \
  -y project_1.srcs/sources_1/new \
  tests/cpu_regression.sv
```

Then the generated simulation is run with:

```bash
tests/build/obj/Vcpu_regression
```

The important option is:

```text
-y project_1.srcs/sources_1/new
```

It gives Verilator a module search directory. Starting from
`tests/cpu_regression.sv`, Verilator loads the active design modules it needs
instead of parsing unrelated broken legacy sources.

For lint of only the active `main` hierarchy, use:

```bash
verilator --lint-only --timing -Wall -Wno-fatal \
  --top-module main \
  -y project_1.srcs/sources_1/new \
  project_1.srcs/sources_1/new/main.v
```

For lint of every source file, this command is useful diagnostically, but it is
currently expected to fail at `SL_Unit.v`:

```bash
verilator --lint-only --timing -Wall -Wno-fatal \
  --top-module main \
  project_1.srcs/sources_1/new/*.v
```

## Troubleshooting checklist for another Codex agent

1. Run `Get-Command wsl` in PowerShell. The expected executable is
   `C:\Windows\System32\wsl.exe`.
2. Check Verilator *inside WSL* with `wsl --exec bash -lc 'command -v verilator'`.
3. If WSL returns `E_ACCESSDENIED` under Codex, request the sandbox escalation;
   do not diagnose it as a PATH problem.
4. Confirm the WSL project directory with
   `wsl --exec bash -lc 'pwd; test -d /mnt/c/Users/troyv/Desktop/projects/fpga/project_1 && echo found'`.
5. Run `wsl --exec bash tests/run_verilator.sh` from the Windows project root.
6. Distinguish build failure from CPU test failure by inspecting
   `tests/build/build.log` and `tests/build/results.log` separately.
7. Do not compile all `*.v` files for the simulation until `SL_Unit.v` is fixed;
   use the active-hierarchy `-y` command above.

No Windows PATH modification, native Windows Verilator installation, MSYS2, or
Visual Studio compiler setup was needed. The working toolchain is entirely the
Linux toolchain inside WSL, operating on the project through `/mnt/c`.
