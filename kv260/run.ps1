param(
 [ValidateSet('hardware','software','load','test')][string]$Step='hardware',
 [string]$Vivado='C:/Xilinx/Vivado/2023.1/bin/vivado.bat',
 [string]$Xsct='C:/Xilinx/Vitis/2023.1/bin/xsct.bat',
 [string]$Xsdb='C:/Xilinx/Vivado/2023.1/bin/xsdb.bat',
 [ValidateSet('small','vitis')][string]$SoftwareMode='small'
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
 switch($Step){
  'hardware' {
   if(!(Test-Path -LiteralPath $Vivado)){throw "Vivado not found: $Vivado"}
   & $Vivado -mode batch -nojournal -log kv260/build.log -source kv260/create_project.tcl
  }
  'software' {
   if($SoftwareMode -eq 'vitis') {
    if(!(Test-Path -LiteralPath $Xsct)){throw "Vitis XSCT not found: $Xsct. Omit -SoftwareMode to use the compact build."}
    & $Xsct kv260/build_software.tcl
   } else {
    $linuxProject=(& wsl.exe --exec wslpath -a $projectRoot).Trim()
    if($LASTEXITCODE -ne 0){throw 'WSL path conversion failed'}
    $smallCommand=@"
set -e
cd '$linuxProject'
bash kv260/small/setup_toolchain.sh
python3 kv260/small/test_math.py
python3 kv260/small/build.py
"@
    & wsl.exe --exec bash -lc $smallCommand
   }
  }
  'load' {
   foreach($artifact in @('kv260_gpu.bit','kv260_test.elf')){
    if(!(Test-Path -LiteralPath (Join-Path $PSScriptRoot $artifact))){throw "Missing $artifact; complete hardware and software builds first."}
   }
   if($SoftwareMode -eq 'vitis') {
    & $Xsdb kv260/load_jtag.tcl
   } else {
    & $Xsdb kv260/small/load.tcl
   }
  }
  'test' { & ./kv260/test.ps1 }
 }
 if($LASTEXITCODE -ne 0){throw "KV260 $Step step failed. Review its output/log."}
} finally {Pop-Location}
