/* KV260 standalone Cortex-A53 bring-up. Loaded via JTAG; no SD or Ethernet.
 * Reuse the project's actual CPU matrix calculator, not a precomputed matrix.
 * Vitis staging copies gpu_matrices.c into this application's source folder.
 */
#define main gpu_matrices_cli_main
#include "gpu_matrices.c"
#undef main
#include "xparameters.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "sleep.h"
#include "display.h"

#define GPU_BASE 0xA0000000U
#define RAM_BASE 0x10000000U
#define FRAME_BYTES (640U*480U*4U)
#define BUFFER_A (RAM_BASE+0x00100000U)
#define BUFFER_B (RAM_BASE+0x00300000U)
#define MAX_VERTICES 16384U

static void reg_write(unsigned offset, uint32_t value)
{ Xil_Out32(GPU_BASE+offset,value); }
static uint32_t reg_read(unsigned offset)
{ return Xil_In32(GPU_BASE+offset); }

static unsigned make_cube(int32_t *vertices)
{
 const Vec3 corners[8]={{-1,-1,-1},{1,-1,-1},{1,1,-1},{-1,1,-1},
                      {-1,-1,1},{1,-1,1},{1,1,1},{-1,1,1}};
 const unsigned edges[12][2]={{0,1},{1,2},{2,3},{3,0},{4,5},{5,6},
                             {6,7},{7,4},{0,4},{1,5},{2,6},{3,7}};
 unsigned count=0;
 for(unsigned e=0;e<12;++e) for(unsigned s=0;s<129;++s) {
  const Vec3 a=corners[edges[e][0]], b=corners[edges[e][1]];
  double t=(double)s/128.0;
  if(!to_q16(a.x+(b.x-a.x)*t,&vertices[count*3]) ||
     !to_q16(a.y+(b.y-a.y)*t,&vertices[count*3+1]) ||
     !to_q16(a.z+(b.z-a.z)*t,&vertices[count*3+2])) return 0;
  ++count;
 }
 return count;
}

int main(void)
{
 GpuMatrices matrix;
 // Change these settings to move/rotate the cube or camera.
 const Scene scene={{0,0,6},{30,20,0},{0,0,0},{0,0,0},640,480,320,1};
 uint32_t *words=(uint32_t *)(UINTPTR)RAM_BASE;
 int32_t *vertices=(int32_t *)(UINTPTR)(RAM_BASE+64U);
 unsigned count;
 uint32_t status;
 // This first standalone test is deliberately uncached. No Linux is running.
 Xil_DCacheDisable();
 xil_printf("\r\nKV260 GPU: CPU matrix -> DDR -> FPGA -> HDMI\r\n");
 if(reg_read(0x08)!=0x4b563031U) {
  xil_printf("ERROR: GPU signature missing. Load matching bitstream first.\r\n");
  return 1;
 }
 if(!build_matrices(&scene,&matrix)) {
  xil_printf("ERROR: invalid matrix\r\n");return 1;
 }
 for(unsigned i=0;i<16;++i) words[i]=(uint32_t)matrix.final_q16[i];
 count=make_cube(vertices);
 if(!count || count>MAX_VERTICES) return 1;
 // Both buffers are black; only B will be rendered. Neither is displayed yet.
 for(unsigned i=0;i<FRAME_BYTES/4U;++i) {
  ((volatile uint32_t *)(UINTPTR)BUFFER_A)[i]=0xff000000U;
  ((volatile uint32_t *)(UINTPTR)BUFFER_B)[i]=0xff000000U;
 }
 // Publish all DDR writes before ringing the START register.
 __asm__ volatile("dsb sy" ::: "memory");
 reg_write(0x10,RAM_BASE);reg_write(0x14,0);reg_write(0x18,64);
 reg_write(0x1c,count);reg_write(0x20,(uint32_t)matrix.near_q16);reg_write(0x24,1);
 __asm__ volatile("dsb sy" ::: "memory");
 xil_printf("CPU submitted 16 matrix words and %u vertices\r\n",count);
 reg_write(0x00,1);
 for(unsigned wait_ms=0;;++wait_ms) {
  status=reg_read(0x04);
  if(status&2U) break;
  if(wait_ms>=10000U) {
   xil_printf("ERROR: GPU timeout; status %08x. Reload design to recover.\r\n",status);
   return 1;
  }
  usleep(1000);
 }
 if(status&8U) {xil_printf("ERROR: GPU error code %u\r\n",(status>>4)&15U);return 1;}
 xil_printf("GPU complete: accepted=%u written=%u skipped=%u\r\n",
            reg_read(0x28),reg_read(0x2c),reg_read(0x30));
 if(reg_read(0x28)!=count || reg_read(0x2c)+reg_read(0x30)!=count) return 1;
 // Readback proves the hardware wrote RAM. CPU does not draw the image.
 unsigned red_pixels=0;
 for(unsigned i=0;i<FRAME_BYTES/4U;++i) {
  uint32_t p=((volatile uint32_t *)(UINTPTR)BUFFER_B)[i];
  if(p==0xff0000ffU) ++red_pixels;
  else if(p!=0xff000000U) {xil_printf("ERROR: unexpected pixel\r\n");return 1;}
 }
 xil_printf("DDR readback: %u red pixels\r\n",red_pixels);
 if(!red_pixels) return 1;
 if(kv260_display_start((UINTPTR)BUFFER_B)!=XST_SUCCESS) {
  xil_printf("ERROR: display link failed. Check HDMI monitor/cable.\r\n");return 1;
 }
 xil_printf("HDMI configured. Static frame displayed; reset/reload to change scene.\r\n");
 for(;;) { usleep(100000); }
}
