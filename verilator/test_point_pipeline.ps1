$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$linuxProject = (& wsl.exe --exec wslpath -a $projectRoot)
if ($LASTEXITCODE -ne 0) { throw 'WSL path conversion failed.' }
$linuxProject = $linuxProject.Trim()
$command = @"
set -e
cd '$linuxProject'
verilator --cc --exe --build -Wall -CFLAGS '-std=c++17' --top-module Point_Pipeline_Test \
  --Mdir '$linuxProject/verilator/obj_point_pipeline' \
  '$linuxProject/VGA_PROJ.srcs/sources_1/new/Matrix_Vertex.v' \
  '$linuxProject/VGA_PROJ.srcs/sources_1/new/Screen_Position.v' \
  '$linuxProject/VGA_PROJ.srcs/sources_1/new/Framebuffer_Write.v' \
  '$linuxProject/VGA_PROJ.srcs/sim_1/new/Point_Pipeline_Test.v' \
  '$linuxProject/verilator/test_point_pipeline.cpp'
'$linuxProject/verilator/obj_point_pipeline/VPoint_Pipeline_Test'
"@
& wsl.exe --exec bash -lc $command
if ($LASTEXITCODE -ne 0) { throw 'Point pipeline behavioral test failed.' }
