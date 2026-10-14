param(
    [string]$Output = (Join-Path $PSScriptRoot "first_frame.hex")
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputPath = [IO.Path]::GetFullPath($Output)

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "WSL is not available. This project uses the Verilator installed in WSL."
}

$linuxProject = (& wsl.exe --exec wslpath -a $projectRoot).Trim()
$linuxOutput = (& wsl.exe --exec wslpath -a $outputPath).Trim()
if ($LASTEXITCODE -ne 0 -or -not $linuxProject -or -not $linuxOutput) {
    throw "Could not translate the project or output path for WSL."
}

$command = @"
set -e
cd '$linuxProject'
verilator --cc --exe --build \
  --top-module vga_3colors \
  --Mdir '$linuxProject/verilator/obj_dir' \
  -Wall -Wno-fatal \
  '$linuxProject/VGA_PROJ.srcs/sources_1/new/vga_3colors.v' \
  '$linuxProject/VGA_PROJ.srcs/sources_1/new/System_Memory.v' \
  '$linuxProject/verilator/sim_main.cpp'
'$linuxProject/verilator/obj_dir/Vvga_3colors' '$linuxOutput'
"@

& wsl.exe --exec bash -lc $command
if ($LASTEXITCODE -ne 0) {
    throw "Verilator build or simulation failed with exit code $LASTEXITCODE."
}
