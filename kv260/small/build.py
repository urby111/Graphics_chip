"""Freestanding A53 build using project-local GNU tools and installed AMD sources."""
from pathlib import Path
import re,subprocess,os,hashlib
here=Path(__file__).resolve().parent
kv=here.parent
sdk=Path('/mnt/c/Xilinx/Vivado/2023.1/data/embeddedsw-sdt')
tool=kv/'toolchain/root/usr'
os.environ['LD_LIBRARY_PATH']=str(tool/'lib/x86_64-linux-gnu')+':'+os.environ.get('LD_LIBRARY_PATH','')
out=here/'build';out.mkdir(exist_ok=True)
def save(path,body):
 if not path.exists() or path.read_text()!=body:path.write_text(body)
inc=out/'include';inc.mkdir(exist_ok=True)
gcc=tool/'bin/aarch64-linux-gnu-gcc-13'
includes=[inc,here,out,sdk/'lib/bsp/standalone/src/common',sdk/'lib/bsp/standalone/src/arm/common',
 sdk/'lib/bsp/standalone/src/arm/common/gcc',sdk/'lib/bsp/standalone/src/arm/ARMv8/64bit']
drivers=['dppsu','dpdma','avbuf','video_common','common']
includes += [sdk/f'XilinxProcessorIPLib/drivers/{d}/src' for d in drivers]
headers={
 'bspconfig.h':'',
 'xparameters.h':'''#define XPAR_PSU_DP_DEVICE_ID 0
#define XPAR_XDPDMA_0_DEVICE_ID 0
#define XPAR_XDPDMA_NUM_INSTANCES 1
#define XPAR_XDPPSU_NUM_INSTANCES 1
#define XPAR_PSU_DP_LANE_COUNT 2
#define XPAR_CPU_ID 0
''',
 'string.h':'''#include <stddef.h>
void *memcpy(void*,const void*,size_t);void *memset(void*,int,size_t);
void *memmove(void*,const void*,size_t);int memcmp(const void*,const void*,size_t);size_t strlen(const char*);
''',
 'math.h':'''double sin(double);double cos(double);double round(double);double ceil(double);double floor(double);double fabs(double);double nearbyint(double);
#define isfinite(x) __builtin_isfinite(x)
''',
 'stdio.h':'int printf(const char*,...);',
 'ctype.h':'int isdigit(int);int isspace(int);',
}
for name,body in headers.items():save(inc/name,body)
source=(kv.parent/'gpu_matrices.c').read_text()
begin=source.index('typedef struct { double x, y, z; } Vec3;')
end=source.index('/* Decode the actual Q16.16')
save(out/'gpu_math.inc','#include <stdint.h>\n#include <math.h>\n#define Q16_SCALE 65536.0\n#define PI 3.14159265358979323846\n'+source[begin:end])
main=(kv/'software/main.c').read_text()
main=re.sub(r'#define main gpu_matrices_cli_main\s*#include "gpu_matrices.c"\s*#undef main','#include "gpu_math.inc"',main)
main=main.replace('int main(void)','void kv260_display_poll(void);\nextern volatile uint32_t *const report;\nint main(void)')
main=main.replace('GpuMatrices matrix;','GpuMatrices matrix;\n report[0]=0x4b56534d;report[1]=1;')
main=main.replace('count=make_cube(vertices);','count=make_cube(vertices);report[3]=count;report[1]=2;')
main=main.replace('reg_write(0x00,1);','reg_write(0x00,1);report[1]=3;')
main=main.replace('if(status&8U)','report[4]=status;report[5]=reg_read(0x28);report[6]=reg_read(0x2c);report[7]=reg_read(0x30);report[1]=4;\n if(status&8U)')
main=main.replace('if(!red_pixels)','report[8]=red_pixels;report[1]=5;\n if(!red_pixels)')
main=main.replace('xil_printf("HDMI configured.', 'report[1]=6;\n xil_printf("HDMI configured.')
main=main.replace('for(;;) { usleep(100000); }','for(;;) { kv260_display_poll(); usleep(1000); }')
save(out/'main.c',main)
display=(kv/'software/display.c').read_text()
display=display.replace('#include "xscugic.h"','').replace('#include "xil_exception.h"','').replace('static XScuGic gic;','')
i=display.index('static int setup_interrupts(void)');j=display.index('int kv260_display_start',i)
display=display[:i]+'''static int setup_interrupts(void){XDpDma_InterruptEnable(&dma,XDPDMA_IEN_VSYNC_INT_MASK);return XST_SUCCESS;}
void kv260_display_poll(void){XDpDma_InterruptHandler(&dma);}
'''+display[j:]
display=display.replace('XDpPsu_EnableMainLink(&dp,1);','XDpPsu_EnableMainLink(&dp,1);\n for(unsigned i=0;i<100;++i){kv260_display_poll();usleep(1000);}')
save(out/'display.c',display)
save(out/'display.h',(kv/'software/display.h').read_text())
save(out/'config.c','''#include "xdppsu.h"
#include "xdpdma.h"
XDpPsu_Config XDpPsu_ConfigTable[]={{.DeviceId=0,.BaseAddr=0xfd4a0000}};
XDpDma_Config XDpDma_ConfigTable[]={{.DeviceId=0,.BaseAddr=0xfd4c0000}};
''')
flags=[str(gcc),'-B'+str(tool/'libexec/gcc-cross/aarch64-linux-gnu/13')+'/',
 '-B'+str(tool/'bin')+'/', '-isystem',str(tool/'lib/gcc-cross/aarch64-linux-gnu/13/include'),
 '-std=gnu11','-O2','-ffreestanding','-fno-builtin','-fno-pie','-fno-stack-protector',
 '-ffunction-sections','-fdata-sections','-mcpu=cortex-a53','-mstrict-align','-D__aarch64__']
for directory in includes:flags+=['-I',str(directory)]
profile=hashlib.sha256((' '.join(flags)+str(headers)+(out/'gpu_math.inc').read_text()+(out/'display.h').read_text()).encode()).hexdigest()
cache=out/'profile.sha256'
changed=not cache.exists() or cache.read_text()!=profile
sources=[here/'start.S',here/'runtime.c',out/'main.c',out/'display.c',out/'config.c']
for driver,names in {
 'dppsu':['xdppsu.c','xdppsu_serdes.c','xdppsu_spm.c','xdppsu_sinit.c'],
 'dpdma':['xdpdma.c','xdpdma_intr.c','xdpdma_sinit.c'],
 'avbuf':['xavbuf.c','xavbuf_clk.c','xavbuf_videoformats.c'],
 'video_common':['xvidc.c','xvidc_timings_table.c']}.items():
 sources += [sdk/f'XilinxProcessorIPLib/drivers/{driver}/src/{name}' for name in names]
objects=[]
for s in sources:
 obj=out/(s.stem+'.o')
 if changed or not obj.exists() or s.stat().st_mtime>obj.stat().st_mtime:
  subprocess.run(flags+['-c',str(s),'-o',str(obj)],check=True)
 objects.append(obj)
elf=kv/'kv260_test.elf'
subprocess.run([str(tool/'bin/aarch64-linux-gnu-ld.bfd'),'-T',str(here/'link.ld'),'--gc-sections',
 '-Map',str(out/'kv260_test.map'),'-o',str(elf)]+[str(o) for o in objects],check=True)
print(f'Built freestanding CPU executable: {elf} ({elf.stat().st_size} bytes)')
cache.write_text(profile)
