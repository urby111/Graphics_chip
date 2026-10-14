#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <deque>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#include <string>
#include "verilated.h"
#include "VProjector.h"

struct Input {
    std::array<int, 3> vertex;
    std::array<int, 3> camera;
    int pitch;
    int yaw;
};
struct Result {
    std::int32_t x, y;
    int depth;
    bool clipped, overflow;
};

static int lut_value(double value) {
    return std::max(-32768, std::min(32767, static_cast<int>(std::lround(value * 32768.0))));
}
static std::int64_t floor_q15(std::int64_t value) {
    return value >= 0 ? value / 32768 : -((-value + 32767) / 32768);
}

// Direct equations using wide software arithmetic, NOT a model of the RTL
// divider or pipeline. Rotations truncate down; signed division truncates to 0.
static Result reference(const Input& in) {
    const double pi = std::acos(-1.0);
    const double phi = (in.pitch % 360) * pi / 180.0;
    const double theta = (in.yaw % 360) * pi / 180.0;
    const int sp = lut_value(std::sin(phi)), cp = lut_value(std::cos(phi));
    const int sy = lut_value(std::sin(theta)), cy = lut_value(std::cos(theta));
    const std::int64_t x = in.vertex[0] - in.camera[0];
    const std::int64_t y = in.vertex[1] - in.camera[1];
    const std::int64_t z = in.vertex[2] - in.camera[2];
    const std::int64_t y1 = floor_q15(y * cp - z * sp);
    const std::int64_t z1 = floor_q15(y * sp + z * cp);
    const std::int64_t x2 = floor_q15(x * cy - z1 * sy);
    const std::int64_t z2 = floor_q15(x * sy + z1 * cy);
    if (z2 <= 0) return {0, 0, static_cast<int>(z2), true, false};
    const std::int64_t px = (x2 * 65536) / z2;
    const std::int64_t py = (y1 * 65536) / z2;
    const std::int64_t low = std::numeric_limits<std::int32_t>::min();
    const std::int64_t high = std::numeric_limits<std::int32_t>::max();
    return {static_cast<std::int32_t>(std::clamp(px, low, high)),
            static_cast<std::int32_t>(std::clamp(py, low, high)),
            static_cast<int>(z2), false, px < low || px > high || py < low || py > high};
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    VProjector dut;
    dut.clk = 0;
    dut.rst = 1;
    dut.in_valid = 0;
    dut.vertex_x = dut.vertex_y = dut.vertex_z = 0;
    dut.camera_x = dut.camera_y = dut.camera_z = 0;
    dut.pitch_deg = dut.yaw_deg = 0;
    dut.eval();
    struct Pending { int due; Result value; };
    std::deque<Pending> pending;
    int cycle = 0, checked = 0, rejected = 0, saturated = 0;
    const Input zero{{0, 0, 0}, {0, 0, 0}, 0, 0};

    auto tick = [&](const Input& in, bool valid, bool reset = false) {
        ++cycle;
        dut.clk = 0;
        dut.eval();
        const std::array<std::uint32_t, 6> before{
            dut.x_2d, dut.y_2d, dut.depth, dut.out_valid, dut.clipped, dut.overflow};
        dut.rst = reset;
        dut.in_valid = valid;
        dut.vertex_x = static_cast<std::uint16_t>(in.vertex[0]);
        dut.vertex_y = static_cast<std::uint16_t>(in.vertex[1]);
        dut.vertex_z = static_cast<std::uint16_t>(in.vertex[2]);
        dut.camera_x = static_cast<std::uint16_t>(in.camera[0]);
        dut.camera_y = static_cast<std::uint16_t>(in.camera[1]);
        dut.camera_z = static_cast<std::uint16_t>(in.camera[2]);
        dut.pitch_deg = in.pitch;
        dut.yaw_deg = in.yaw;
        dut.eval();
        const std::array<std::uint32_t, 6> after{
            dut.x_2d, dut.y_2d, dut.depth, dut.out_valid, dut.clipped, dut.overflow};
        if (before != after) throw std::runtime_error("Output changed between clock edges");
        if (reset) pending.clear();
        else if (valid) pending.push_back({cycle + 41, reference(in)});
        dut.clk = 1;
        dut.eval();
        const bool expect_valid = !pending.empty() && pending.front().due == cycle;
        if (static_cast<bool>(dut.out_valid) != expect_valid)
            throw std::runtime_error("Valid/latency mismatch at cycle " + std::to_string(cycle));
        if (expect_valid) {
            const Result expected = pending.front().value;
            pending.pop_front();
            const int actual_depth = (dut.depth & 0x40000U) ?
                                     static_cast<int>(dut.depth) - 524288 : static_cast<int>(dut.depth);
            if (dut.x_2d != static_cast<std::uint32_t>(expected.x) ||
                dut.y_2d != static_cast<std::uint32_t>(expected.y) ||
                actual_depth != expected.depth || dut.clipped != expected.clipped ||
                dut.overflow != expected.overflow) {
                std::cerr << "Cycle " << cycle << ": expected (" << expected.x << ',' << expected.y
                          << ") z=" << expected.depth << " clipped=" << expected.clipped
                          << " overflow=" << expected.overflow << "; actual bits ("
                          << dut.x_2d << ',' << dut.y_2d << ") z=" << actual_depth
                          << " clipped=" << int(dut.clipped) << " overflow=" << int(dut.overflow) << '\n';
                throw std::runtime_error("Math mismatch");
            }
            ++checked;
            rejected += expected.clipped;
            saturated += expected.overflow;
        }
    };

    try {
        tick(zero, false, true);
        tick(zero, false, true);
        // Known projection: at zero angles x=2,z=4 gives x/z=0.5 exactly
        // for these quantized operations. The input values are scaled by 256.
        const Input basic{{512, 256, 1024}, {0, 0, 0}, 0, 0};
        if (reference(basic).x != 32768) throw std::runtime_error("Bad known reference");
        tick(basic, true);
        for (int angle : {0, 30, 45, 90, 180, 270, 359, 360, 450, 511}) {
            tick({{512, -768, 2048}, {-256, 128, -512}, angle, 0}, true);
            tick({{512, -768, 2048}, {-256, 128, -512}, 0, angle}, true);
        }
        tick(zero, true); // at camera: divide by zero must be rejected
        tick({{1, 2, -256}, {0, 0, 0}, 0, 0}, true); // behind camera
        tick({{32767, 32767, 3}, {-32768, -32768, 0}, 0, 0}, true); // positive overflow
        tick({{-32768, -32768, 3}, {32767, 32767, 0}, 0, 0}, true); // negative overflow
        tick({{32767, 32767, 32767}, {-32768, -32768, -32768}, 45, 315}, true);
        for (int angle = 0; angle < 512; ++angle)
            tick({{2560, -1792, 3328}, {-1280, 512, -768}, angle, (angle * 173) % 512}, true);
        for (int i = 0; i < 50; ++i) tick(zero, false);

        std::mt19937 random(0x50724A);
        std::uniform_int_distribution<int> coord(-32768, 32767), angle(0, 511);
        for (int i = 0; i < 8000; ++i) {
            Input in{{coord(random), coord(random), coord(random)},
                     {coord(random), coord(random), coord(random)}, angle(random), angle(random)};
            tick(in, (i % 7) != 0); // bubbles with changing angles test transaction alignment
            if (i == 1234 || i == 4000) tick(zero, false, true); // flush in-flight vertices
        }
        for (int i = 0; i < 50; ++i) tick(zero, false);
        if (!pending.empty() || rejected == 0 || saturated < 2)
            throw std::runtime_error("Incomplete directed coverage or pipeline not drained");
        dut.final();
        std::cout << "PASS: " << checked << " vertices, " << rejected << " clipped, "
                  << saturated << " saturated; exact fixed-point math, 41-cycle latency, "
                  << "consecutive inputs, bubbles, angle wrap and reset flushing verified.\n";
    } catch (const std::exception& e) {
        std::cerr << "FAIL: " << e.what() << '\n';
        return 1;
    }
}
