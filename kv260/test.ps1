$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$linuxProject=(& wsl.exe --exec wslpath -a $projectRoot).Trim()
if($LASTEXITCODE -ne 0){throw 'WSL path conversion failed'}
$command=@"
set -e
cd '$linuxProject'
verilator --cc --exe --build -j 4 -Wall -Wno-UNUSEDSIGNAL \
 --top-module KV260_GPU --Mdir kv260/tests/obj -CFLAGS '-std=c++17' \
 kv260/rtl/*.v VGA_PROJ.srcs/sources_1/new/Matrix_Vertex.v \
 VGA_PROJ.srcs/sources_1/new/Screen_Position.v VGA_PROJ.srcs/sources_1/new/Framebuffer_Write.v \
 '$linuxProject/kv260/tests/test_gpu.cpp'
gcc -std=c11 -Wall -Wextra -Werror gpu_matrices.c -lm -o kv260/tests/gpu_matrices
kv260/tests/gpu_matrices --scene demo_scene.txt kv260/tests/scene.hex
kv260/tests/obj/VKV260_GPU kv260/tests/scene.hex
kv260/tests/gpu_matrices --self-test
"@
& wsl.exe --exec bash -lc $command
if($LASTEXITCODE -ne 0){throw 'KV260 tests failed'}
