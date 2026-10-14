#include "VKV260_GPU.h"
#include "verilated.h"
#include <array>
#include <vector>
#include <random>
#include <stdexcept>
#include <iostream>
#include <cstdint>
#include <algorithm>
#include <fstream>

static constexpr uint32_t BASE=0x10000000, A=0x100000, B=0x300000;
struct Sim {
 VKV260_GPU d;
 std::mt19937 rng{20261013};
 std::vector<uint32_t> ram=std::vector<uint32_t>(0x800000/4,0xff000000);
 bool reading=false, got_aw=false, got_w=false, responding=false;
 uint32_t ra=0,wa=0,wd=0; int rd_delay=0,b_delay=0;
 uint32_t fail_read=0; bool fail_write=false;
 unsigned cycles=0,reads=0,writes=0;
 std::vector<uint32_t> read_addresses;
 bool chance(){return rng()%4!=0;}
 void require(bool ok,const char* msg){if(!ok)throw std::runtime_error(msg);}
 size_t index(uint32_t addr) {
  require(addr>=BASE && addr<BASE+0x800000 && !(addr&3),"out-of-region AXI address");
  return (addr-BASE)/4;
 }
 void tick(){
  d.clk=0;
  d.m_axi_arready=!reading && chance();
  d.m_axi_awready=!got_aw && !responding && chance();
  d.m_axi_wready=!got_w && !responding && chance();
  d.m_axi_rvalid=reading && rd_delay==0;
  d.m_axi_rdata=reading?ram[index(ra)]:0;
  d.m_axi_rresp=ra==fail_read?2:0;d.m_axi_rlast=1;
  d.m_axi_bvalid=responding && b_delay==0;d.m_axi_bresp=fail_write?2:0;
  d.eval();
  bool ar=d.m_axi_arvalid && d.m_axi_arready;
  bool r=d.m_axi_rvalid && d.m_axi_rready;
  bool aw=d.m_axi_awvalid && d.m_axi_awready;
  bool w=d.m_axi_wvalid && d.m_axi_wready;
  bool b=d.m_axi_bvalid && d.m_axi_bready;
  uint32_t new_ra=d.m_axi_araddr,new_wa=d.m_axi_awaddr,new_wd=d.m_axi_wdata;
  if(ar)require(d.m_axi_arlen==0 && d.m_axi_arsize==2,"bad AXI read shape");
  if(aw)require(d.m_axi_awlen==0 && d.m_axi_awsize==2,"bad AXI write shape");
  if(w)require(d.m_axi_wlast && d.m_axi_wstrb==15,"bad AXI write strobes");
  d.clk=1;d.eval();++cycles;
  if(rd_delay>0)--rd_delay;
  if(b_delay>0)--b_delay;
  if(r)reading=false;
  if(b){responding=false;got_aw=false;got_w=false;}
  if(ar){reading=true;ra=new_ra;rd_delay=rng()%12;++reads;read_addresses.push_back(ra);}
  if(aw){got_aw=true;wa=new_wa;}
  if(w){got_w=true;wd=new_wd;}
  if(got_aw && got_w && !responding){
   if(!fail_write)ram[index(wa)]=wd;
   responding=true;b_delay=10+rng()%25;++writes;
  }
 }
 void reset(){
  d.resetn=0;d.s_axi_awvalid=0;d.s_axi_wvalid=0;d.s_axi_arvalid=0;
  d.s_axi_bready=0;d.s_axi_rready=0;d.s_axi_awprot=0;d.s_axi_arprot=0;
  for(int i=0;i<4;++i)tick();d.resetn=1;tick();
 }
 uint32_t read(uint32_t addr){
  d.s_axi_araddr=addr;d.s_axi_arvalid=1;d.s_axi_rready=0;
  for(unsigned i=0;i<1000;++i){
   d.clk=0;d.eval();bool handshake=d.s_axi_arready;tick();
   if(handshake){d.s_axi_arvalid=0;break;}
   require(i<999,"AXI-Lite read address timeout");
  }
  for(unsigned i=0;!d.s_axi_rvalid;++i){require(i<1000,"AXI-Lite read response timeout");tick();}
  uint32_t value=d.s_axi_rdata;
  require(d.s_axi_rresp==0,"AXI-Lite read error");
  // Hold RREADY low for several cycles; response must remain stable.
  for(int i=0;i<3;++i){tick();require(d.s_axi_rvalid && d.s_axi_rdata==value,"unstable R response");}
  d.s_axi_rready=1;tick();d.s_axi_rready=0;return value;
 }
 unsigned write(uint32_t addr,uint32_t value,int gap=0,uint8_t strobe=15){
  d.s_axi_awaddr=addr;d.s_axi_wdata=value;d.s_axi_wstrb=strobe;
  d.s_axi_awvalid=gap>=0;d.s_axi_wvalid=gap<=0;d.s_axi_bready=0;
  bool aw=false,w=false;
  for(int i=0;i<1000 && (!aw||!w);++i){
   if(i==std::abs(gap)){if(!aw)d.s_axi_awvalid=1;if(!w)d.s_axi_wvalid=1;}
   d.clk=0;d.eval();bool ah=d.s_axi_awvalid&&d.s_axi_awready,wh=d.s_axi_wvalid&&d.s_axi_wready;
   tick();if(ah){aw=true;d.s_axi_awvalid=0;}if(wh){w=true;d.s_axi_wvalid=0;}
  }
  require(aw&&w,"AXI-Lite write timeout");
  for(int i=0;!d.s_axi_bvalid;++i){require(i<1000,"AXI-Lite B timeout");tick();}
  unsigned resp=d.s_axi_bresp;
  for(int i=0;i<3;++i){tick();require(d.s_axi_bvalid && d.s_axi_bresp==resp,"unstable B response");}
  d.s_axi_bready=1;tick();d.s_axi_bready=0;return resp;
 }
 uint32_t wait(){
  for(int i=0;i<20000;++i){uint32_t s=read(4);if(s&2){
    require(!(s&1),"DONE while busy");require(!reading&&!responding,"DONE before AXI transactions drained");return s;}
   tick();}
  throw std::runtime_error("GPU timeout");
 }
 void setup(unsigned n,unsigned buf=1){
  require(write(0x10,BASE,5)==0,"base write");require(write(0x14,0,-4)==0,"matrix write");
  require(write(0x18,64,7)==0,"vertex address write");require(write(0x1c,n,-3)==0,"count write");
  require(write(0x20,65536)==0,"near write");require(write(0x24,buf)==0,"buffer write");
 }
 void matrix(const std::array<int32_t,16>& m){for(unsigned i=0;i<16;++i)ram[i]=m[i];}
 void vertices(const std::vector<std::array<int32_t,3>>& v){
  for(unsigned i=0;i<v.size();++i)for(int k=0;k<3;++k)ram[16+i*3+k]=v[i][k];
 }
};

static int32_t q(int v){return int32_t(int64_t(v)*65536);}
// Independent wide arithmetic reference with the RTL's saturation/floor rules.
static std::vector<uint32_t> reference(const std::array<int32_t,16>&m,
 const std::vector<std::array<int32_t,3>>&vertices,unsigned buf){
 std::vector<uint32_t> memory(0x800000/4,0xff000000);
 for(const auto&v:vertices){
  int32_t h[4];bool overflow=false;
  for(int row=0;row<4;++row){
   __int128 sum=__int128(m[row*4+3])*65536;
   for(int col=0;col<3;++col)sum+=__int128(m[row*4+col])*v[col];
   __int128 shifted=sum>>16;
   overflow|=shifted<INT32_MIN||shifted>INT32_MAX;
   h[row]=int32_t(std::clamp(shifted,__int128(INT32_MIN),__int128(INT32_MAX)));
  }
  if(overflow||h[3]<=0||h[2]<65536)continue;
  auto floor_div=[](int64_t a,int64_t b){return a/b-((a<0&&a%b)?1:0);};
  int64_t x=floor_div(floor_div(2LL*h[0],h[3])+640,2);
  int64_t y=floor_div(floor_div(-2LL*h[1],h[3])+480,2);
  if(x>=0&&x<640&&y>=0&&y<480)memory[((buf?B:A)+uint32_t(y)*2560+uint32_t(x)*4)/4]=0xff0000ff;
 }
 return memory;
}

int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{
  Sim s;s.reset();s.require(s.read(8)==0x4b563031,"signature");
  std::array<int32_t,16> m{};m[0]=q(320);m[5]=q(320);m[10]=q(1);m[14]=q(1);
  std::vector<std::array<int32_t,3>> v={{{q(-1),q(-1),q(4)}},{{q(1),q(-1),q(4)}},
    {{0,q(1),q(4)}},{{0,0,0}},{{q(100),0,q(1)}},{{INT32_MAX,0,q(1)}}};
  std::mt19937 rng(42);
  for(int i=0;i<300;++i)v.push_back({{int32_t(rng()%q(8))-q(4),int32_t(rng()%q(8))-q(4),int32_t(rng()%q(8))}});
  for(unsigned buf=0;buf<2;++buf){
   std::fill(s.ram.begin(),s.ram.end(),0xff000000);s.matrix(m);s.vertices(v);s.setup(v.size(),buf);
   size_t old_reads=s.read_addresses.size();s.require(s.write(0,1)==0,"START");
   s.require(s.write(0x1c,1)==2,"busy config must be rejected");
   s.require(s.write(0,1,-4)==2,"busy START must be rejected");
   s.require((s.wait()&8)==0,"valid frame failed");
   s.require(s.read(0x28)==v.size(),"accepted vertex count");
   s.require(s.read(0x2c)+s.read(0x30)==v.size(),"completed point count");
   for(unsigned i=0;i<16;++i)s.require(s.read_addresses[old_reads+i]==BASE+i*4,"matrix must be fetched first");
   s.require(s.read_addresses.size()-old_reads==16+3*v.size(),"DDR word count");
   auto expected=reference(m,v,buf);
   for(size_t i=A/4;i<s.ram.size();++i)s.require(s.ram[i]==expected[i],"framebuffer/reference mismatch");
   std::cout<<"PASS buffer "<<buf<<": all 307200 pixels and surrounding memory checked\n";
  }
  s.setup(0);s.require(s.write(0,1)==0,"empty start");s.require(!(s.wait()&8),"empty draw");
  unsigned before=s.reads;s.setup(1);s.write(0x18,0);s.write(0,1);
  s.require(((s.wait()>>4)&15)==1&&s.reads==before,"overlapping input must fail without AXI accesses");
  s.setup(1);s.write(0x10,0x7f800004);s.write(0,1);s.require(((s.wait()>>4)&15)==1,"DDR wrap validation");
  s.setup(1);s.fail_read=BASE+8;s.write(0,1);s.require(((s.wait()>>4)&15)==2,"read error");
  s.fail_read=0;s.fail_write=true;s.setup(v.size());s.write(0,1);
  s.require(((s.wait()>>4)&15)==3,"write error must drain outstanding read");s.fail_write=false;
  s.matrix(m);s.vertices(v);s.setup(v.size());s.write(0,1);s.require(!(s.wait()&8),"recovery after bus fault");
  s.require(s.write(0x20,0xabcdef01,6,1)==0 && s.read(0x20)==0x10001,"WSTRB merge");
  if(argc>1){
   std::ifstream input(argv[1]);uint32_t magic,width,height,near,count;
   input>>std::hex>>magic>>width>>height>>near>>count;
   s.require(bool(input)&&magic==0x47505531&&width==640&&height==480,"scene header");
   for(auto &word:m){uint32_t raw;input>>raw;word=int32_t(raw);}
   v.resize(count);for(auto &point:v)for(auto &word:point){uint32_t raw;input>>raw;word=int32_t(raw);}
   s.require(bool(input)&&near==65536,"scene input");
   std::fill(s.ram.begin(),s.ram.end(),0xff000000);s.matrix(m);s.vertices(v);s.setup(count);
   s.write(0,1);s.require(!(s.wait()&8),"CPU-generated cube");
   auto expected=reference(m,v,1);
   for(size_t i=A/4;i<s.ram.size();++i)s.require(s.ram[i]==expected[i],"CPU cube reference mismatch");
   std::cout<<"PASS CPU-generated cube: "<<count<<" vertices, "
    <<std::count(expected.begin()+B/4,expected.begin()+(B+640*480*4)/4,0xff0000ffU)<<" red pixels\n";
  }
  std::cout<<"PASS: delayed DDR, independent AW/W, response stalls, matrix-first ordering, clipping,\n"
             "empty draws, both buffers, busy rejection, address validation, read/write faults and recovery\n";
 }catch(const std::exception&e){std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}
 return 0;
}
