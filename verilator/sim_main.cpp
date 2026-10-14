#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <string>

#include <verilated.h>
#include "Vvga_3colors.h"

namespace {
constexpr int kVisibleWidth = 640;
constexpr int kVisibleHeight = 480;
constexpr int kHorizontalTotal = 800;
constexpr int kVerticalTotal = 525;

void tick_100_mhz(Vvga_3colors& top) {
    top.clk = 0;
    top.eval();
    top.clk = 1;
    top.eval();
}
}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const std::string output_path = argc >= 2 ? argv[1] : "first_frame.hex";
    std::ofstream frame(output_path, std::ios::trunc);
    if (!frame) {
        std::cerr << "Could not open '" << output_path << "' for writing.\n";
        return 1;
    }

    auto top = std::make_unique<Vvga_3colors>();
    top->clk = 0;
    top->eval();

    // Mirror the RTL's VGA counters. Waiting for their next wrap gives us a
    // clean, complete frame instead of the partial frame present at startup.
    int x = 0;
    int y = 0;
    bool frame_started = false;
    std::uint32_t pixels_written = 0;

    while (!Verilated::gotFinish() && pixels_written < kVisibleWidth * kVisibleHeight) {
        // clk_25M is clk_div[1], giving one pixel-clock rising edge per four
        // rising edges of the 100 MHz input clock.
        for (int system_clocks = 0; system_clocks < 4; ++system_clocks) {
            tick_100_mhz(*top);
        }

        if (++x == kHorizontalTotal) {
            x = 0;
            if (++y == kVerticalTotal) {
                y = 0;
                frame_started = true;
            }
        }

        if (frame_started && x < kVisibleWidth && y < kVisibleHeight) {
            const unsigned rgb =
                ((static_cast<unsigned>(top->vga_r) & 0x0fU) << 8U) |
                ((static_cast<unsigned>(top->vga_g) & 0x0fU) << 4U) |
                (static_cast<unsigned>(top->vga_b) & 0x0fU);

            frame << std::uppercase << std::hex << std::setw(3)
                  << std::setfill('0') << rgb << '\n';
            ++pixels_written;
        }
    }

    top->final();
    frame.close();

    if (pixels_written != kVisibleWidth * kVisibleHeight) {
        std::cerr << "Simulation ended after " << pixels_written
                  << " pixels; expected 307200.\n";
        return 1;
    }

    std::cout << "Captured 640x480 frame (" << pixels_written
              << " pixels) to " << output_path << "\n";
    return 0;
}
