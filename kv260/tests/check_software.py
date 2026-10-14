"""Host syntax/API check against installed AMD headers; NOT an ARM/BSP build."""
import subprocess
import os
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sdk=Path(('C:/' if os.name=='nt' else '/mnt/c/')+'Xilinx/Vivado/2023.1/data/embeddedsw-sdt')
headers=root/'tests/api_headers'
headers.mkdir(exist_ok=True)
(headers/'bspconfig.h').write_text('/* API-only host check; no generated BSP. */\n')
(headers/'xparameters.h').write_text('''
#define XPAR_PSU_DP_DEVICE_ID 0
#define XPAR_XDPDMA_0_DEVICE_ID 0
#define XPAR_XDPDMA_NUM_INSTANCES 1
#define XPAR_SCUGIC_0_DEVICE_ID 0
#define XPAR_CPU_ID 0
#define XPAR_CPU_CORTEXA53_0_CPU_CLK_FREQ_HZ 1200000000
''')
dirs=[headers,root.parent,sdk/'lib/bsp/standalone/src/common',
      sdk/'lib/bsp/standalone/src/arm/common',
      sdk/'lib/bsp/standalone/src/arm/common/gcc',
      sdk/'lib/bsp/standalone/src/arm/ARMv8',
      sdk/'lib/bsp/standalone/src/arm/ARMv8/64bit']
for driver in ['common','dppsu','dpdma','avbuf','scugic','video_common']:
    dirs.append(sdk/f'XilinxProcessorIPLib/drivers/{driver}/src')
compiler='C:/Xilinx/Vivado/2023.1/tps/mingw/9.3.0/win64.o/nt/bin/gcc.exe' if os.name=='nt' else 'gcc'
command=[compiler,'-std=gnu11','-fsyntax-only','-Wall','-Wextra','-Werror','-D__aarch64__']
for directory in dirs:command+=['-I',str(directory)]
command+=[str(root/'software/main.c'),str(root/'software/display.c')]
subprocess.run(command,check=True)
print('PASS: C syntax and installed AMD driver API declarations (not BSP linking).')
