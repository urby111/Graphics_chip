#include "verilated.h"
#ifdef LINE_TEST
#include "VLine_Draw.h"
using Model = VLine_Draw;
#else
#include "VTriangle_Fill.h"
using Model = VTriangle_Fill;
#endif
#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <random>
#include <set>
#include <stdexcept>
#include <utility>
#include <vector>

using Point = std::pair<int,int>;
using Shape = std::array<Point,3>;
constexpr int W=640,H=480;
void check(bool condition,const char *message){if(!condition)throw std::runtime_error(message);}
bool visible(Point p){return p.first>=0&&p.first<W&&p.second>=0&&p.second<H;}
bool supported(const Shape&s){
#ifdef LINE_TEST
 const int count=2;
#else
 const int count=3;
#endif
 for(int i=0;i<count;++i)if(s[i].first< -32768||s[i].first>32767||s[i].second< -32768||s[i].second>32767)return false;
 return true;
}
std::vector<Point> reference(const Shape&s){
 std::vector<Point> pixels;if(!supported(s))return pixels;
#ifdef LINE_TEST
 // Independent rational DDA reference (no Bresenham accumulator).
 int64_t dx=std::abs(s[1].first-s[0].first),dy=std::abs(s[1].second-s[0].second);
 int64_t length=std::max(dx,dy);
 int signx=s[1].first>=s[0].first?1:-1,signy=s[1].second>=s[0].second?1:-1;
 for(int64_t k=0;k<=length;++k){
  Point p=s[0];
  if(length){p.first+=signx*int((k*dx+length/2)/length);p.second+=signy*int((k*dy+length/2)/length);}
  if(visible(p))pixels.push_back(p);
 }
#else
 // Direct per-sample edge equations; the HDL instead increments three edges.
 auto edge=[](Point a,Point b,int64_t x,int64_t y){
  return int64_t(b.first-a.first)*(y-2LL*a.second)-int64_t(b.second-a.second)*(x-2LL*a.first);
 };
 int64_t area=edge(s[0],s[1],2LL*s[2].first,2LL*s[2].second);
 if(!area)return pixels;
 int lx=std::max(0,std::min({s[0].first,s[1].first,s[2].first}));
 int hx=std::min(W-1,std::max({s[0].first,s[1].first,s[2].first}));
 int ly=std::max(0,std::min({s[0].second,s[1].second,s[2].second}));
 int hy=std::min(H-1,std::max({s[0].second,s[1].second,s[2].second}));
 for(int y=ly;y<=hy;++y)for(int x=lx;x<=hx;++x){
  bool covered=true;
  for(int i=0;i<3;++i){
   Point a=s[i],b=s[(i+1)%3];if(area<0)std::swap(a,b);
   int64_t e=edge(a,b,2LL*x+1,2LL*y+1);
   bool top_left=b.second<a.second||(b.second==a.second&&b.first>a.first);
   covered&=e>0||(e==0&&top_left);
  }
  if(covered)pixels.emplace_back(x,y);
 }
#endif
 return pixels;
}

struct Sim{
 Model d;std::mt19937 rng{0x525354};std::vector<Point> pixels;
 uint32_t expected_color=0;bool stalled=false;Point held;uint32_t held_color=0;
 uint64_t clocks=0,checked_pixels=0;unsigned jobs=0;
 void tick(bool ready){
  d.clk=0;d.out_ready=ready;d.eval();
  Point p{int32_t(d.pixel_x),int32_t(d.pixel_y)};
  if(stalled&&!d.rst)check(d.out_valid&&p==held&&d.pixel_color==held_color,"pixel changed during a stall");
  stalled=d.out_valid&&!ready;held=p;held_color=d.pixel_color;
  if(d.rst)check(!d.in_ready&&!d.out_valid,"transfer allowed during reset");
  if(d.out_valid&&ready){
   check(visible(p),"out-of-viewport pixel emitted");
   check(d.pixel_color==expected_color,"command color changed");pixels.push_back(p);++checked_pixels;
  }
  d.clk=1;d.eval();++clocks;
  if(stalled)check(d.busy&&!d.done,"completed before stalled pixel was accepted");
 }
 void inputs(const Shape&s,uint32_t color){
  d.x0=s[0].first;d.y0=s[0].second;d.x1=s[1].first;d.y1=s[1].second;
#ifndef LINE_TEST
  d.x2=s[2].first;d.y2=s[2].second;
#endif
  d.in_color=color;
 }
 void reset(){d.in_valid=0;d.rst=1;tick(false);tick(false);d.rst=0;stalled=false;tick(true);check(d.in_ready&&!d.busy&&!d.done&&!d.error,"bad reset state");pixels.clear();}
 std::vector<Point> run(const Shape&s,uint32_t color){
  check(d.in_ready&&!d.busy,"command not ready");pixels.clear();expected_color=color;
  auto want=reference(s);inputs(s,color);d.in_valid=1;tick(true);d.in_valid=0;
  for(unsigned guard=0;!d.done;++guard){
   check(guard<1000000,"command did not finish");check(d.busy&&!d.in_ready,"busy command accepted another input");
   // An unaccepted command deliberately changes every clock: saved vertices/color must survive.
   Shape noise{{{int(rng()%100),int(rng()%100)},{-12,25},{70,90}}};
   inputs(noise,rng());d.in_valid=1;
   tick(guard>=12&&rng()%4!=0);
  }
  d.in_valid=0;check(bool(d.error)==!supported(s),"incorrect error result");
  check(!d.busy&&!d.out_valid&&d.in_ready,"bad completion state");
  check(pixels==want,"pixel list differs from independent reference");
  tick(true);check(!d.done,"DONE must be a one-clock pulse");++jobs;return pixels;
 }
 void reset_while_stalled(){
  Shape s{{{10,10},{40,10},{10,40}}};inputs(s,0x12345678);expected_color=0x12345678;d.in_valid=1;tick(false);d.in_valid=0;
  for(int i=0;!d.out_valid;++i){check(i<100,"reset test has no pixel");tick(false);}
  for(int i=0;i<8;++i)tick(false);
  reset();run(Shape{{{20,20},{20,20},{25,30}}},0xabcdef01);
 }
};

// A file for viewing successful standalone output; never connected to the GPU.
void save_bmp(const char*path,const std::vector<std::pair<Point,uint32_t>>&samples){
 std::vector<unsigned char> image(W*H*3,0);
 for(auto item:samples){auto[x,y]=item.first;uint32_t c=item.second;size_t i=((H-1-y)*W+x)*3;image[i]=c&255;image[i+1]=(c>>8)&255;image[i+2]=(c>>16)&255;}
 std::ofstream out(path,std::ios::binary);check(bool(out),"preview file could not be opened");
 auto u16=[&](unsigned n){out.put(char(n));out.put(char(n>>8));};
 auto u32=[&](uint32_t n){u16(n&65535);u16(n>>16);};
 out.write("BM",2);u32(54+image.size());u32(0);u32(54);u32(40);u32(W);u32(H);u16(1);u16(24);u32(0);u32(image.size());u32(0);u32(0);u32(0);u32(0);
 out.write(reinterpret_cast<const char*>(image.data()),image.size());check(bool(out),"preview write failed");
}

int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{
  Sim s;s.reset();
  std::vector<Shape> cases={
   {{{10,10},{10,10},{10,10}}},{{{0,0},{20,0},{0,20}}},{{{10,10},{10,40},{40,10}}},
   {{{0,0},{639,479},{639,0}}},{{{-20,-20},{20,20},{20,-20}}},
   {{{-100,-100},{-50,-50},{-10,-60}}},{{{630,470},{660,500},{630,500}}},
   {{{10,10},{20,20},{30,30}}},{{{1000,0},{1200,0},{1100,50}}},
   {{{-32768,-32768},{32767,0},{0,32767}}},{{{-32768,-32768},{32767,-32768},{-32768,32767}}},
   {{{-32768,240},{32767,240},{10,250}}},{{{0,-32768},{0,32767},{10,250}}},
   {{{40000,0},{10,10},{30,20}}},{{{0,0},{INT32_MIN,INT32_MAX},{10,20}}}
  };
#ifdef LINE_TEST
  for(int dx=-12;dx<=12;++dx)for(int dy=-12;dy<=12;++dy)cases.push_back(Shape{{{50,50},{50+dx,50+dy},{0,0}}});
#endif
  for(int i=0;i<150;++i){Shape c;for(auto&p:c)p={int(s.rng()%100)-20,int(s.rng()%100)-20};cases.push_back(c);}
  for(const auto&c:cases){
   s.run(c,s.rng());
#ifdef LINE_TEST
   auto reversed=c;std::swap(reversed[0],reversed[1]);s.run(reversed,s.rng());
#else
   Shape perm=c;std::swap(perm[1],perm[2]);s.run(perm,s.rng());
#endif
  }
#ifndef LINE_TEST
  auto a=s.run(Shape{{{10,10},{18,10},{10,18}}},0x112233);
  auto b=s.run(Shape{{{18,10},{18,18},{10,18}}},0x445566);
  std::set<Point> all(a.begin(),a.end());for(auto p:b)check(all.insert(p).second,"shared edge drew a pixel twice");
  check(all.size()==64,"adjacent triangles left a crack");
  for(int y=10;y<18;++y)for(int x=10;x<18;++x)check(all.count({x,y}),"rectangle coverage missing");
#endif
  s.reset_while_stalled();
  std::vector<std::pair<Point,uint32_t>> preview;
#ifdef LINE_TEST
  for(Point end:std::vector<Point>{{540,240},{520,390},{320,440},{120,390},{100,240},{120,90},{320,40},{520,90}})
   for(auto p:s.run(Shape{{{320,240},end,{0,0}}},0x00ff8040))preview.push_back({p,0x00ff8040});
#else
  for(auto p:s.run(Shape{{{80,400},{320,60},{560,400}}},0x0030a0ff))preview.push_back({p,0x0030a0ff});
#endif
  if(argc>1)save_bmp(argv[1],preview);
  std::cout<<"PASS "
#ifdef LINE_TEST
   <<"Line_Draw"
#else
   <<"Triangle_Fill"
#endif
   <<": "<<s.jobs<<" commands, "<<s.checked_pixels<<" pixels checked; clipping, colors, input capture, stalls, reset and completion\n";
 }catch(const std::exception&e){std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}
 return 0;
}
