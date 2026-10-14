$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$linuxProject = (& wsl.exe --exec wslpath -a $projectRoot)
if ($LASTEXITCODE -ne 0) { throw 'WSL path conversion failed.' }
$linuxProject = $linuxProject.Trim()
$command = @"
set -e
cd '$linuxProject'
verilator --cc --exe --build -Wall -CFLAGS '-std=c++17' --top-module Projector \
  --Mdir '$linuxProject/verilator/obj_projector' \
  '$linuxProject/VGA_PROJ.srcs/sources_1/new/sin_cos_lut.v' \
  '$linuxProject/VGA_PROJ.srcs/sources_1/new/Projector.v' \
  '$linuxProject/verilator/test_projector.cpp'
'$linuxProject/verilator/obj_projector/VProjector'
"@
& wsl.exe --exec bash -lc $command
if ($LASTEXITCODE -ne 0) { throw 'Projector Verilator test failed.' }
