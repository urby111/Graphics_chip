#include <algorithm>
#include <cmath>
#include <iostream>
#include "verilated.h"
#include "Vsin_cos_lut.h"

static int q15(double value) {
    return std::max(-32768, std::min(32767, static_cast<int>(std::lround(value * 32768.0))));
}

static int signed_value(unsigned bits) {
    return (bits & 0x8000U) ? static_cast<int>(bits) - 65536 : static_cast<int>(bits);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vsin_cos_lut dut;
    dut.clk = 0;
    dut.angle_deg = 0;
    dut.eval();
    int checks = 0;
    const double pi = std::acos(-1.0);
    // Sweep both directions, including every possible out-of-range input.
    for (int pass = 0; pass < 2; ++pass) {
        for (int i = 0; i < 512; ++i) {
            const int angle = pass ? 511 - i : i;
            dut.clk = 0;
            dut.eval();
            const auto previous_sin = dut.sin_value;
            const auto previous_cos = dut.cos_value;
            dut.angle_deg = angle;
            dut.eval();
            if (dut.sin_value != previous_sin || dut.cos_value != previous_cos) {
                std::cerr << "Output changed without a rising clock edge\n";
                return 1;
            }
            dut.clk = 1;
            dut.eval();
            const double radians = (angle % 360) * pi / 180.0;
            if (signed_value(dut.sin_value) != q15(std::sin(radians)) ||
                signed_value(dut.cos_value) != q15(std::cos(radians))) {
                std::cerr << "Mismatch at angle " << angle << ": sin="
                          << signed_value(dut.sin_value) << ", cos="
                          << signed_value(dut.cos_value) << "\n";
                return 1;
            }
            ++checks;
        }
    }
    dut.final();
    std::cout << "PASS: " << checks
              << " sine/cosine pairs; all 512 inputs, wraparound and clocked outputs checked.\n";
}

