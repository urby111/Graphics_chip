$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$linuxProject = (& wsl.exe --exec wslpath -a $projectRoot)
if ($LASTEXITCODE -ne 0) { throw 'WSL path conversion failed.' }
$linuxProject = $linuxProject.Trim()
$command = @"
set -e
cd '$linuxProject'
verilator --cc --exe --build -Wall --top-module sin_cos_lut \
  --Mdir '$linuxProject/verilator/obj_sin_cos' \
  '$linuxProject/VGA_PROJ.srcs/sources_1/new/sin_cos_lut.v' \
  '$linuxProject/verilator/test_sin_cos.cpp'
'$linuxProject/verilator/obj_sin_cos/Vsin_cos_lut'
"@
& wsl.exe --exec bash -lc $command
if ($LASTEXITCODE -ne 0) { throw 'Sine/cosine Verilator test failed.' }

