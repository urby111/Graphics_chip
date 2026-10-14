"""Compare compact math with libm and the existing CPU matrix calculator."""
from pathlib import Path
import subprocess
p=Path(__file__).resolve().parent
out=p/'build';out.mkdir(exist_ok=True)
runtime=(p/'runtime.c').read_text();math_code=runtime[runtime.index('double round('):]
original=(p.parent.parent/'gpu_matrices.c').read_text()
functions=original[original.index('static Mat4 identity'):original.index('/* Decode the actual Q16.16')]
names=['round','sin','cos','ceil','floor','fabs','identity','multiply','translate','radians',
       'rotate_x','rotate_y','rotate_z','to_q16','build_matrices']
prefix='\n'.join('#define '+name+' small_'+name for name in names)
suffix='\n'.join('#undef '+name for name in names)
source='''#define main unused_cli_main
#include "gpu_matrices.c"
#undef main
'''+prefix+'\n'+math_code+'\n'+functions+'\n'+suffix+'''
int main(void){
 for(int i=-3600;i<=3600;++i){double x=i*PI/1800.0;
  if(fabs(sin(x)-small_sin(x))>1e-13 || fabs(cos(x)-small_cos(x))>1e-13)return 1;
 }
 for(int i=-360;i<=360;i+=5){
  Scene s={{0,0,6},{i,i/2.0,i/3.0},{0,0,0},{0,0,0},640,480,320,1};
  GpuMatrices a,b;
  if(!build_matrices(&s,&a)||!small_build_matrices(&s,&b))return 2;
  for(int k=0;k<16;++k)if(a.final_q16[k]!=b.final_q16[k])return 3;
 }
 puts("PASS compact math: 7201 angle checks and 145 exact Q16.16 matrix comparisons");return 0;
}
'''
(out/'test_math.c').write_text(source)
subprocess.run(['gcc','-std=c11','-O2','-fno-builtin','-I',str(p.parent.parent),
 str(out/'test_math.c'),'-lm','-o',str(out/'test_math')],check=True)
subprocess.run([str(out/'test_math')],check=True)
