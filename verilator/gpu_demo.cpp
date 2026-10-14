#include "VGPU_Pipeline.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

constexpr size_t PIXELS=640*480;
using Point=std::array<int32_t,3>;
static void require(bool ok,const std::string& why) { if(!ok)throw std::runtime_error(why); }
static int32_t signed32(uint32_t n) {
    return int32_t((n&0x80000000u)?int64_t(n)-4294967296LL:n);
}
static int64_t floor_div(int64_t n,int64_t d) { return n/d-(n%d<0?1:0); }

struct Scene {
    int32_t near_value;
    std::array<int32_t,16> matrix;
    std::vector<Point> points;
};
static Scene read_scene(const char* path) {
    std::ifstream file(path); require(bool(file),"Cannot open generated scene");
    std::vector<uint32_t> words;uint32_t n;
    while(file>>std::hex>>n)words.push_back(n);
    require(file.eof() && words.size()>=21,"Incomplete/invalid scene data");
    require(words[0]==0x47505531 && words[1]==640 && words[2]==480,"Scene format/resolution mismatch");
    require(words[4]<=16384 && words.size()==21+3*size_t(words[4]),"Bad vertex count");
    Scene s;s.near_value=signed32(words[3]);require(s.near_value>0,"Near plane must be positive");
    for(size_t i=0;i<16;++i)s.matrix[i]=signed32(words[5+i]);
    for(size_t i=21;i<words.size();i+=3)
        s.points.push_back({signed32(words[i]),signed32(words[i+1]),signed32(words[i+2])});
    return s;
}

// Exact software reference for the fixed-point datapath, not for VGA output.
static std::vector<uint16_t> expected_frame(const Scene& scene) {
    std::vector<uint16_t> frame(PIXELS,0);
    for(const auto& v:scene.points) {
        int64_t h[4];bool overflow=false;
        for(int r=0;r<4;++r) {
            __int128 total=static_cast<__int128>(scene.matrix[4*r+3])*65536;
            for(int c=0;c<3;++c)total+=static_cast<__int128>(scene.matrix[4*r+c])*v[c];
            __int128 value=total>=0?total/65536:-((-total+65535)/65536);
            if(value<INT32_MIN || value>INT32_MAX)overflow=true;
            h[r]=value<INT32_MIN?INT32_MIN:value>INT32_MAX?INT32_MAX:int64_t(value);
        }
        if(overflow || h[3]<=0 || h[2]<scene.near_value)continue;
        int64_t x=floor_div(640*h[3]+2*h[0],2*h[3]);
        int64_t y=floor_div(480*h[3]-2*h[1],2*h[3]);
        if(x>=0 && x<640 && y>=0 && y<480)frame[size_t(y*640+x)]=0xf00;
    }
    return frame;
}

class Demo {
public:
    VGPU_Pipeline d;
    uint64_t clocks=0;
    Demo() {
        d.clk=0;d.rst=1;d.matrix_valid=0;d.matrix_data=0;d.cmd_valid=0;
        d.cmd=0;d.buffer_select=0;d.vertex_count=0;d.near_q16=65536;
        d.vertex_valid=0;d.vertex_x=0;d.vertex_y=0;d.vertex_z=0;
        tick();tick();d.rst=0;
    }
    void settle() {d.clk=0;d.eval();}
    void tick() {
        settle();d.clk=1;d.eval();++clocks;
        if(!d.display_enabled)require(d.vga_r==0 && d.vga_g==0 && d.vga_b==0,"Uninitialized frame displayed");
    }
    void wait_done(bool error=false) {
        for(unsigned i=0;!d.done;++i) {
            require(i<1800000,"Command completion timeout");tick();
        }
        require(bool(d.error)==error,"Unexpected command error status");
        require(!d.busy,"Done asserted while busy");
    }
    void command(unsigned cmd,unsigned buffer,uint32_t count,int32_t near_value) {
        d.cmd=cmd;d.buffer_select=buffer;d.vertex_count=count;d.near_q16=uint32_t(near_value);
        d.cmd_valid=1;settle();
        require(d.cmd_ready,"Command not ready");tick();d.cmd_valid=0;
    }
    void load(const Scene& s) {
        d.matrix_valid=1;
        for(auto word:s.matrix) {
            d.matrix_data=uint32_t(word);settle();require(d.matrix_ready,"Matrix word blocked");tick();
        }
        d.matrix_valid=0;require(d.matrix_loaded,"Matrix did not load");
    }
    void draw(const Scene& s,unsigned buffer) {
        command(0,buffer,0,s.near_value);wait_done();
        command(1,buffer,0,s.near_value);wait_done(); // empty batch must finish
        command(1,buffer,uint32_t(s.points.size()),s.near_value);
        // The top must use its captured draw settings, not changing external inputs.
        d.buffer_select=!buffer;d.near_q16=0;d.vertex_count=0;
        size_t index=0;
        for(const auto& p:s.points) {
            if(index++%17==0) {d.vertex_valid=0;tick();}
            d.vertex_x=uint32_t(p[0]);d.vertex_y=uint32_t(p[1]);d.vertex_z=uint32_t(p[2]);
            d.vertex_valid=1;
            for(unsigned timeout=0;;++timeout) {
                require(timeout<1000,"Vertex input stalled indefinitely");settle();
                bool take=d.vertex_ready;tick();if(take)break;
            }
        }
        settle();require(!d.vertex_ready,"Accepted more than requested vertex_count");
        d.vertex_valid=0;wait_done();
        command(2,buffer,0,s.near_value);wait_done();
        require(d.front_buffer==buffer && d.display_enabled,"Present did not select correct buffer");
    }
    std::vector<uint16_t> capture() {
        std::vector<uint16_t> frame;frame.reserve(PIXELS);
        bool started=false;
        for(unsigned timeout=0;frame.size()<PIXELS;++timeout) {
            require(timeout<3400000,"VGA capture timeout");tick();
            if(!d.scan_valid)continue;
            if(!started) {if(d.scan_addr!=0)continue;started=true;}
            require(d.scan_addr==frame.size(),"VGA scanout skipped/repeated a pixel");
            require(d.hsync && d.vsync,"Sync asserted inside visible area");
            frame.push_back(uint16_t((d.vga_r<<8)|(d.vga_g<<4)|d.vga_b));
        }
        return frame;
    }
};

static void save_frame(const std::string& prefix,const std::vector<uint16_t>& frame) {
    std::ofstream hex(prefix+".hex");require(bool(hex),"Cannot write frame hex");
    for(auto rgb:frame)hex<<std::uppercase<<std::hex<<std::setfill('0')<<std::setw(3)<<rgb<<'\n';
    hex.close();require(bool(hex),"Frame hex write failed");
    // Uncompressed BMP, for viewing the exact VGA frame without the Windows viewer.
    std::ofstream bmp(prefix+".bmp",std::ios::binary);require(bool(bmp),"Cannot write BMP");
    std::array<unsigned char,54> header{};
    auto put32=[&](int offset,uint32_t v) {for(int i=0;i<4;++i)header[offset+i]=uint8_t(v>>(8*i));};
    header[0]='B';header[1]='M';put32(2,54+640*480*3);put32(10,54);put32(14,40);
    put32(18,640);put32(22,480);header[26]=1;header[28]=24;put32(34,640*480*3);
    bmp.write(reinterpret_cast<const char*>(header.data()),header.size());
    for(int y=479;y>=0;--y)for(int x=0;x<640;++x) {
        unsigned rgb=frame[size_t(y*640+x)];
        const char bgr[3]={char((rgb&15)*17),char(((rgb>>4)&15)*17),char(((rgb>>8)&15)*17)};
        bmp.write(bgr,3);
    }
    bmp.close();require(bool(bmp),"BMP write failed");
}

int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try {
        require(argc==3,"Usage: VGPU_Pipeline scene.hex output_prefix");
        Scene scene=read_scene(argv[1]);auto expected=expected_frame(scene);
        Demo demo;
        demo.command(2,1,0,scene.near_value);demo.wait_done(true); // uninitialized buffer
        demo.command(3,0,0,scene.near_value);demo.wait_done(true); // unsupported control
        demo.load(scene);
        std::vector<uint16_t> frame;
        for(unsigned buffer:{1u,0u}) {
            demo.draw(scene,buffer);frame=demo.capture();
            for(size_t i=0;i<PIXELS;++i)
                require(frame[i]==expected[i],"Framebuffer/VGA mismatch at pixel "+std::to_string(i));
            // Writing the visible front buffer must be rejected without changing it.
            demo.command(0,buffer,0,scene.near_value);demo.wait_done(true);
            std::cout<<"PASS buffer "<<(buffer?'B':'A')<<": "<<scene.points.size()
                     <<" vertices -> RAM -> VGA; all 307200 pixels match\n";
        }
        // Verify a rejected front-buffer clear did not erase or alter the image.
        require(demo.capture()==expected,"Rejected clear modified the front buffer");
        save_frame(argv[2],frame);
        size_t red=0;for(auto rgb:frame)if(rgb==0xf00)++red;
        std::cout<<"PASS clear, empty draw, command errors, captured settings and vblank presentation\n"
                 <<"VISIBLE RESULT: "<<red<<" red pixels, "<<PIXELS-red<<" black pixels\n"
                 <<"Saved actual VGA output to "<<argv[2]<<".hex and .bmp\n";
        demo.d.final();return 0;
    } catch(const std::exception& e) {std::cerr<<"FAIL: "<<e.what()<<'\n';return 1;}
}
