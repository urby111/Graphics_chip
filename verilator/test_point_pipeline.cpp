#include "VPoint_Pipeline_Test.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <deque>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

constexpr int32_t Q = 65536;
constexpr uint32_t RED = 0x00ff0000;
constexpr uint32_t REGION = 8*1024*1024;
using Matrix = std::array<int32_t,16>;
using Point = std::array<int32_t,4>;

static void check(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}
static int32_t sign32(uint32_t x) {
    return static_cast<int32_t>((x & 0x80000000u) ? int64_t(x)-4294967296LL : x);
}
static int64_t floor_div(int64_t n, int64_t d) {
    return n/d - ((n%d < 0) ? 1 : 0);
}

struct Pixel {
    int32_t x=0, y=0, depth=0;
    uint16_t width=0, height=0;
    bool inside=false, rejected=false, buffer=false;
};
struct Transaction { bool write=false, buffer=false; uint32_t addr=0; };

class Test {
public:
    VPoint_Pipeline_Test d;
    Matrix matrix{};
    unsigned matrix_index=0;
    std::deque<Pixel> pixels;
    std::deque<Transaction> transactions;
    std::vector<uint32_t> ram, expected_ram;
    uint64_t cycles=0, accepted=0, projected=0, writes=0, drops=0, cancelled=0;
    Pixel last_pixel;

    Test() : ram(REGION/4,0), expected_ram(REGION/4,0) {
        d.clk=0; d.rst=0; d.matrix_valid=0; d.matrix_data=0; d.point_valid=0;
        defaults(); point({0,0,0,0}); reset();
    }
    void defaults() {
        d.mode=0; d.width=640; d.height=480; d.near_q16=Q;
        d.a_offset=0x00100000; d.b_offset=0x00300000;
        d.stride=2560; d.region_bytes=REGION; d.wr_ready=1;
        d.point_overflow=0; d.point_in_frame=1; d.buffer_select=0;
    }
    void point(Point p) {
        d.point_x=uint32_t(p[0]); d.point_y=uint32_t(p[1]);
        d.point_z=uint32_t(p[2]); d.point_w=uint32_t(p[3]);
    }
    Pixel reference_pixel() {
        Point p={sign32(d.point_x),sign32(d.point_y),sign32(d.point_z),sign32(d.point_w)};
        unsigned overflow=d.point_overflow;
        if (d.mode==1) {
            overflow=0;
            Point transformed;
            for (int r=0;r<4;++r) {
                __int128 total=static_cast<__int128>(matrix[4*r+3])*Q;
                for(int c=0;c<3;++c) total+=static_cast<__int128>(matrix[4*r+c])*p[c];
                __int128 q=total>=0 ? total/Q : -((-total+Q-1)/Q);
                if(q>INT32_MAX) {transformed[r]=INT32_MAX; overflow|=1u<<r;}
                else if(q<INT32_MIN) {transformed[r]=INT32_MIN; overflow|=1u<<r;}
                else transformed[r]=int32_t(q);
            }
            p=transformed;
        }
        Pixel result;
        result.width=d.width; result.height=d.height; result.buffer=d.buffer_select;
        result.depth=p[2];
        if(d.mode==2) {
            result.x=p[0]; result.y=p[1]; result.inside=d.point_in_frame;
            result.rejected=overflow!=0; return result;
        }
        result.rejected=overflow || p[3]<=0 || sign32(d.near_q16)<=0 ||
            p[2]<sign32(d.near_q16) || !d.width || !d.height;
        if(result.rejected) return result;
        // Direct rational reference; independent of the divider's half-pixel algorithm.
        int64_t x=floor_div(int64_t(d.width)*p[3]+2LL*p[0],2LL*p[3]);
        int64_t y=floor_div(int64_t(d.height)*p[3]-2LL*p[1],2LL*p[3]);
        if(x<INT32_MIN || x>INT32_MAX || y<INT32_MIN || y>INT32_MAX) {
            result.rejected=true; return result;
        }
        result.x=int32_t(x); result.y=int32_t(y);
        result.inside=x>=0 && y>=0 && x<d.width && y<d.height;
        return result;
    }
    Transaction reference_write(const Pixel& p) {
        uint64_t span=uint64_t(p.height)*d.stride;
        uint64_t end_a=uint64_t(d.a_offset)+span, end_b=uint64_t(d.b_offset)+span;
        Transaction t; t.buffer=p.buffer;
        t.write=p.inside && !p.rejected && p.x>=0 && p.y>=0 && p.x<p.width &&
            p.y<p.height && p.width && p.height && d.stride>=uint32_t(p.width)*4 &&
            !(d.stride%4) && !(d.a_offset%4) && !(d.b_offset%4) &&
            end_a<=d.region_bytes && end_b<=d.region_bytes &&
            (end_a<=d.b_offset || end_b<=d.a_offset);
        if(t.write) {
            uint64_t address=(p.buffer ? d.b_offset : d.a_offset)+
                uint64_t(p.y)*d.stride+uint64_t(p.x)*4;
            check(address+4<=d.region_bytes && address<=UINT32_MAX,"reference address invalid");
            t.addr=uint32_t(address);
        }
        return t;
    }
    void check_outputs() {
        if(d.screen_valid) {
            check(!pixels.empty(),"unexpected screen output");
            const Pixel& p=pixels.front();
            check(sign32(d.screen_x)==p.x && sign32(d.screen_y)==p.y,
                "screen coordinate mismatch at cycle "+std::to_string(cycles)+
                ": got ("+std::to_string(sign32(d.screen_x))+","+
                std::to_string(sign32(d.screen_y))+"), expected ("+
                std::to_string(p.x)+","+std::to_string(p.y)+")");
            check(sign32(d.screen_depth)==p.depth && d.screen_in_frame==p.inside &&
                d.screen_rejected==p.rejected && d.screen_buffer==p.buffer &&
                d.result_width==p.width && d.result_height==p.height,"screen metadata mismatch");
        }
        check(!(d.wr_valid && d.dropped),"write and drop asserted together");
        if(d.wr_valid || d.dropped) {
            check(!transactions.empty(),"unexpected writer output");
            const Transaction& t=transactions.front();
            check(bool(d.wr_valid)==t.write,"writer write/drop mismatch");
            if(t.write) check(d.wr_addr==t.addr && d.wr_data==RED && d.wr_strb==15 &&
                             d.wr_buffer==t.buffer,"RAM write transaction mismatch");
        }
    }
    bool tick() {
        d.clk=0; d.eval();
        bool took=!d.rst && d.point_valid && d.point_ready;
        if(d.rst) {
            cancelled+=transactions.size(); transactions.clear(); pixels.clear(); matrix_index=0;
        } else {
            check_outputs();
            if(d.screen_valid && d.screen_ready) {
                last_pixel=pixels.front(); pixels.pop_front(); ++projected;
            }
            if(d.wr_valid && d.wr_ready) {
                const Transaction t=transactions.front(); transactions.pop_front();
                check(d.wr_addr%4==0 && d.wr_addr<REGION,"write escaped simulated RAM");
                ram[d.wr_addr/4]=d.wr_data; expected_ram[t.addr/4]=RED; ++writes;
            }
            if(d.dropped) {transactions.pop_front(); ++drops;}
            if(took) {
                Pixel p=reference_pixel();
                if(d.mode!=2) pixels.push_back(p);
                transactions.push_back(reference_write(p)); ++accepted;
            }
            if(d.matrix_valid && d.matrix_ready) {
                matrix[matrix_index]=sign32(d.matrix_data); matrix_index=(matrix_index+1)%16;
            }
        }
        d.clk=1; d.eval(); ++cycles;
        check_outputs();
        return took;
    }
    void reset() {
        d.rst=1; tick(); d.rst=0; d.point_valid=0; d.matrix_valid=0; d.wr_ready=1;
        check(!d.screen_busy && !d.writer_busy,"reset failed to flush pipeline");
    }
    void drain() {
        d.point_valid=0; d.matrix_valid=0; d.wr_ready=1;
        for(int n=0;!transactions.empty() || !pixels.empty();++n) {
            check(n<1000,"pipeline drain timeout"); tick();
        }
        check(!d.screen_busy && !d.writer_busy,"unexpected residual valid stages");
    }
    void send(Point p) {
        point(p); d.point_valid=1;
        for(int n=0;;++n) {check(n<1000,"input timeout"); if(tick()) break;}
        d.point_valid=0;
    }
    void known(Point p,int x,int y,bool inside=true,bool rejected=false) {
        send(p); drain();
        check(last_pixel.x==x && last_pixel.y==y && last_pixel.inside==inside &&
              last_pixel.rejected==rejected,"hand-calculated screen result mismatch");
    }
    void load(const Matrix& m) {
        drain(); d.point_valid=0; d.matrix_valid=1;
        for(int i=0;i<16;++i) {
            d.matrix_data=uint32_t(m[i]);
            d.clk=0;d.eval();check(d.matrix_ready,"matrix input unexpectedly blocked");tick();
        }
        d.matrix_valid=0; check(d.matrix_loaded,"matrix not loaded");
    }
};

int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try {
        Test t;
        t.known({-320*Q,-320*Q,4*Q,4*Q},240,320);
        check(t.ram[(0x100000+320*2560+240*4)/4]==RED,"buffer A pixel missing");
        t.d.buffer_select=1;
        t.known({320*Q,-320*Q,4*Q,4*Q},400,320);
        check(t.ram[(0x300000+320*2560+400*4)/4]==RED,"buffer B pixel missing");
        t.known({0,320*Q,4*Q,4*Q},320,160);
        t.known({320*Q,0,100*Q,4*Q},400,240); // use W, not Z, for division
        std::cout<<"PASS known screen positions, divide by W, red writes to both buffers\n";

        t.d.width=641;t.d.height=481;t.d.stride=2816;
        t.known({-Q/4,Q/4,Q,Q},320,240);
        t.known({-3*Q/4,3*Q/4,Q,Q},319,239);
        t.known({Q/2,-Q/2,Q,Q},321,241);
        t.known({-321*Q,241*Q,Q,Q},-1,-1,false);
        t.d.width=1;t.d.height=1;
        t.known({0,0,Q,Q},0,0);
        t.known({-Q/2,Q/2,Q,Q},0,0);
        t.known({Q/2,0,Q,Q},1,0,false);
        std::cout<<"PASS odd resolutions, half-pixels, signed floor and padded row stride\n";

        t.defaults();
        t.known({-320*Q,240*Q,Q,Q},0,0);
        t.known({319*Q,-239*Q,Q,Q},639,479);
        t.known({320*Q,0,Q,Q},640,240,false);
        t.known({0,-240*Q,Q,Q},320,480,false);
        t.known({0,0,0,0},0,0,false,true);
        t.known({0,0,-Q,-Q},0,0,false,true);
        t.known({0,0,Q-1,Q},0,0,false,true);
        t.d.near_q16=0;t.known({0,0,Q,Q},0,0,false,true);t.d.near_q16=Q;
        t.d.point_overflow=8;t.known({0,0,Q,Q},0,0,false,true);t.d.point_overflow=0;
        t.d.width=0;t.known({0,0,Q,Q},0,0,false,true);t.d.width=640;
        t.d.near_q16=1;
        t.known({INT32_MIN,INT32_MAX,1,1},INT32_MIN+320,240-INT32_MAX,false);
        t.known({INT32_MAX,0,1,1},0,0,false,true);
        std::cout<<"PASS near plane, zero/negative W, overflow flags, signed extremes and edges\n";

        t.defaults();t.d.mode=2;
        auto bad_pixel=[&](int32_t x,int32_t y) {
            auto before=t.writes;t.send({x,y,0,0});t.drain();
            check(t.writes==before,"invalid pixel/config wrote RAM");
        };
        bad_pixel(-1,0);bad_pixel(640,0);bad_pixel(0,480);
        t.d.point_in_frame=0;bad_pixel(1,1);t.d.point_in_frame=1;
        t.d.point_overflow=1;bad_pixel(1,1);t.d.point_overflow=0;
        t.d.stride=2556;bad_pixel(1,1);t.d.stride=2561;bad_pixel(1,1);t.d.stride=2560;
        t.d.a_offset=0x100001;bad_pixel(1,1);t.d.a_offset=0x100000;
        t.d.b_offset=0x100000;bad_pixel(1,1);t.d.b_offset=0x100004;bad_pixel(1,1);
        t.d.b_offset=0x300000;t.d.region_bytes=0x300004;bad_pixel(1,1);
        t.d.region_bytes=UINT32_MAX;t.d.a_offset=0xfffffffcu;bad_pixel(1,1);
        t.d.a_offset=0x100000;t.d.height=65535;t.d.stride=0xfffffffcu;bad_pixel(1,1);
        std::cout<<"PASS writer rejects bad bounds, alignment, overlapping buffers and address overflow\n";

        // Matrix_Vertex -> Screen_Position -> Framebuffer_Write, all connected.
        t.defaults();t.d.mode=1;
        Matrix m{};m[0]=m[5]=320*Q;m[10]=m[14]=Q;t.load(m);
        t.known({-Q,-Q,4*Q,Q},240,320);
        t.d.buffer_select=1;t.known({Q,-Q,4*Q,Q},400,320);
        t.known({0,Q,4*Q,Q},320,160);
        t.known({0,0,-Q,Q},0,0,false,true);
        std::cout<<"PASS complete matrix-to-pixel-to-RAM chain\n";

        t.defaults();
        uint64_t start=t.cycles;
        for(int i=0;i<128;++i) {
            t.point({i*Q,0,Q,Q});t.d.point_valid=1;t.d.buffer_select=i%2;
            check(t.tick(),"failed to accept consecutive vertex");
        }
        check(t.cycles-start==128,"stream inserted unexpected input bubbles");t.drain();
        std::cout<<"PASS one vertex per cycle with alternating framebuffer selection\n";

        std::mt19937 rng(0x50495845u);
        for(int batch=0;batch<6;++batch) {
            t.defaults();t.d.stride=batch%2 ? 4096:2560;
            unsigned sent=0;
            for(int watchdog=0;sent<512;++watchdog) {
                check(watchdog<20000,"random stream timeout");
                t.d.wr_ready=watchdog>=100 && rng()%4!=0;
                if(!t.d.point_valid && rng()%4!=0) {
                    // Vary the screen metadata per accepted point; layout stays fixed.
                    t.d.width=uint16_t(1+rng()%640);t.d.height=uint16_t(1+rng()%480);
                    t.d.buffer_select=rng()%2;
                    int32_t w=int32_t(1+rng()%(16*Q));
                    if(batch<3) {
                        t.d.near_q16=1;
                        t.point({int32_t(rng()%(512*Q))-256*Q,
                                 int32_t(rng()%(512*Q))-256*Q,w,w});
                    } else {
                        t.d.near_q16=1;
                        t.point({sign32(rng()),sign32(rng()),w,w});
                    }
                    t.d.point_overflow=(rng()%40==0)?1:0;t.d.point_valid=1;
                }
                if(t.tick()) {++sent;t.d.point_valid=0;}
            }
            t.drain();
        }
        std::cout<<"PASS 3072 randomized projections, per-vertex metadata and long/random RAM stalls\n";

        // Reset may discard requests not yet accepted by RAM, never undo writes.
        t.defaults();t.d.wr_ready=0;
        for(int i=0;i<10;++i)t.send({i*Q,0,Q,Q});
        for(int i=0;i<50;++i)t.tick();
        check(t.d.wr_valid,"reset scenario did not reach a stalled RAM write");
        auto written=t.writes;t.reset();
        for(int i=0;i<50;++i)t.tick();
        check(t.writes==written,"reset leaked a cancelled write");
        t.known({0,0,Q,Q},320,240);
        check(t.ram==t.expected_ram,"framebuffer contents differ (stray or missing write)");
        check(t.accepted==t.writes+t.drops+t.cancelled,"lost/duplicated pipeline transaction");
        std::cout<<"PASS reset cancellation and exact RAM contents (including untouched pixels)\n"
                 <<"ALL TESTS PASSED: "<<t.projected<<" screen results, "<<t.writes
                 <<" red RAM writes, "<<t.drops<<" rejected/off-screen writes skipped, "
                 <<t.cancelled<<" reset-cancelled points\n";
        t.d.final();return 0;
    } catch(const std::exception& e) {
        std::cerr<<"FAIL: "<<e.what()<<'\n';return 1;
    }
}
