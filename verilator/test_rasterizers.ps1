$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$linuxProject=(& wsl.exe --exec wslpath -a $projectRoot).Trim()
if($LASTEXITCODE -ne 0){throw 'WSL path conversion failed'}
$command=@"
set -e
cd '$linuxProject'
mkdir -p verilator/rasterizers
verilator --cc --exe --build -j 2 -Wall --top-module Line_Draw \
 --Mdir verilator/obj_line_draw -CFLAGS '-std=c++17 -DLINE_TEST' \
 VGA_PROJ.srcs/sources_1/new/Line_Draw.v '$linuxProject/verilator/test_rasterizers.cpp'
verilator/obj_line_draw/VLine_Draw verilator/rasterizers/line_demo.bmp
verilator --cc --exe --build -j 2 -Wall --top-module Triangle_Fill \
 --Mdir verilator/obj_triangle_fill -CFLAGS '-std=c++17' \
 VGA_PROJ.srcs/sources_1/new/Triangle_Fill.v '$linuxProject/verilator/test_rasterizers.cpp'
verilator/obj_triangle_fill/VTriangle_Fill verilator/rasterizers/triangle_demo.bmp
"@
& wsl.exe --exec bash -lc $command
if($LASTEXITCODE -ne 0){throw 'Standalone rasterizer tests failed'}
