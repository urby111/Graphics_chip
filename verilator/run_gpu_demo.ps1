param(
    [string]$Scene = (Join-Path (Split-Path -Parent $PSScriptRoot) 'demo_scene.txt'),
    [switch]$View
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$scenePath = (Resolve-Path -LiteralPath $Scene).Path
$linuxProject = (& wsl.exe --exec wslpath -a $projectRoot)
if ($LASTEXITCODE -ne 0) { throw 'WSL path conversion failed.' }
$linuxScene = (& wsl.exe --exec wslpath -a $scenePath)
if ($LASTEXITCODE -ne 0) { throw 'WSL scene path conversion failed.' }
$linuxProject = $linuxProject.Trim()
$linuxScene = $linuxScene.Trim()
# Quote paths for Bash, including any embedded apostrophe.
$bashProject = "'" + $linuxProject.Replace("'", "'\''") + "'"
$bashScene = "'" + $linuxScene.Replace("'", "'\''") + "'"
$command = @"
set -e
cd $bashProject
mkdir -p verilator/gpu_demo
gcc -std=c11 -O2 -Wall -Wextra -Werror gpu_matrices.c -lm -o verilator/gpu_demo/gpu_matrices
verilator/gpu_demo/gpu_matrices --scene $bashScene verilator/gpu_demo/scene.hex
verilator --cc --exe --build -j 4 -Wall -CFLAGS '-std=c++17' --top-module GPU_Pipeline \
  --Mdir "`$PWD/verilator/obj_gpu_pipeline" -y "`$PWD/VGA_PROJ.srcs/sources_1/new" \
  "`$PWD/VGA_PROJ.srcs/sources_1/new/GPU_Pipeline.v" "`$PWD/verilator/gpu_demo.cpp"
verilator/obj_gpu_pipeline/VGPU_Pipeline verilator/gpu_demo/scene.hex verilator/gpu_demo/gpu_frame
"@
& wsl.exe --exec bash -lc $command
if ($LASTEXITCODE -ne 0) { throw 'Full GPU pipeline demo failed.' }
$frame = Join-Path $PSScriptRoot 'gpu_demo\gpu_frame.hex'
Write-Host "Frame ready: $frame"
if ($View) {
    $viewer = Join-Path $projectRoot 'screen\vga_screen.exe'
    if (!(Test-Path -LiteralPath $viewer)) { throw 'Build screen/vga_screen.exe first (see screen/README.md).' }
    Start-Process -FilePath $viewer -ArgumentList ('"' + $frame + '"')
}
