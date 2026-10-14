$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$linuxProject = (& wsl.exe --exec wslpath -a $projectRoot)
if ($LASTEXITCODE -ne 0) { throw 'WSL path conversion failed.' }
$linuxProject = $linuxProject.Trim()
$command = @"
set -e
cd '$linuxProject'
verilator --cc --exe --build -Wall -CFLAGS '-std=c++17' --top-module Matrix_Vertex \
  --Mdir '$linuxProject/verilator/obj_matrix_vertex' \
  '$linuxProject/VGA_PROJ.srcs/sources_1/new/Matrix_Vertex.v' \
  '$linuxProject/verilator/test_matrix_vertex.cpp'
'$linuxProject/verilator/obj_matrix_vertex/VMatrix_Vertex'
"@
& wsl.exe --exec bash -lc $command
if ($LASTEXITCODE -ne 0) { throw 'Matrix_Vertex behavioral test failed.' }
