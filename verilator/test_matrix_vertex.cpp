#include "VMatrix_Vertex.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <deque>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#include <string>

using Matrix = std::array<int32_t, 16>;
using Vertex = std::array<int32_t, 3>;
constexpr int32_t ONE = 65536;

struct Result {
    std::array<int32_t, 4> value{};
    uint8_t overflow = 0;
    uint64_t due = 0;
};

static void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

static int32_t signed_word(uint32_t bits) {
    return static_cast<int32_t>((bits & 0x80000000u)
        ? static_cast<int64_t>(bits) - 4294967296LL : bits);
}

// Independent wide integer dot product. Do not truncate individual products.
static Result reference(const Matrix& m, const Vertex& v) {
    Result r;
    for (int row = 0; row < 4; ++row) {
        __int128 sum = static_cast<__int128>(m[row*4+3]) * ONE;
        for (int col = 0; col < 3; ++col)
            sum += static_cast<__int128>(m[row*4+col]) * v[col];
        __int128 q = sum >= 0 ? sum / ONE : -((-sum + ONE - 1) / ONE);
        if (q > INT32_MAX) {
            r.value[row] = INT32_MAX;
            r.overflow |= 1u << row;
        } else if (q < INT32_MIN) {
            r.value[row] = INT32_MIN;
            r.overflow |= 1u << row;
        } else r.value[row] = static_cast<int32_t>(q);
    }
    return r;
}

struct Transfers { bool matrix, vertex; };

class Test {
public:
    VMatrix_Vertex dut;
    Matrix active{};
    std::deque<Result> pending;
    unsigned index = 0;
    bool loaded = false;
    uint64_t advances = 0, cycles = 0, accepted = 0, completed = 0;
    uint64_t discarded = 0, saturated = 0, matrix_words = 0;

    Test() {
        dut.clk = 0; dut.rst = 0; dut.matrix_valid = 0;
        dut.vertex_valid = 0; dut.out_ready = 1;
        dut.matrix_data = 0; vertex({0,0,0});
        reset();
    }

    void vertex(Vertex v) {
        dut.vertex_x = static_cast<uint32_t>(v[0]);
        dut.vertex_y = static_cast<uint32_t>(v[1]);
        dut.vertex_z = static_cast<uint32_t>(v[2]);
    }

    void check_output() {
        const bool expected_valid = !pending.empty() && pending.front().due <= advances;
        require(bool(dut.out_valid) == expected_valid,
                "valid/latency mismatch at cycle " + std::to_string(cycles));
        if (!expected_valid) return;
        const Result& expected = pending.front();
        std::array<int32_t,4> actual = {signed_word(dut.result_x),
            signed_word(dut.result_y), signed_word(dut.result_z), signed_word(dut.result_w)};
        for (int row = 0; row < 4; ++row)
            require(actual[row] == expected.value[row],
                "coordinate " + std::to_string(row) + " mismatch at cycle " +
                std::to_string(cycles) + ": got " + std::to_string(actual[row]) +
                ", expected " + std::to_string(expected.value[row]));
        require(dut.out_overflow == expected.overflow, "overflow mask mismatch");
    }

    Transfers tick() {
        dut.clk = 0; dut.eval();
        if (!dut.rst) check_output();
        const bool expected_matrix_ready = !dut.rst && pending.empty();
        const bool step = !dut.out_valid || dut.out_ready;
        const bool expected_vertex_ready = !dut.rst && loaded && !dut.matrix_valid && step;
        require(bool(dut.matrix_ready) == expected_matrix_ready, "matrix_ready mismatch");
        require(bool(dut.vertex_ready) == expected_vertex_ready, "vertex_ready mismatch");
        Transfers t{bool(dut.matrix_valid && dut.matrix_ready),
                    bool(dut.vertex_valid && dut.vertex_ready)};
        if (dut.rst) {
            discarded += pending.size(); pending.clear();
            index = 0; loaded = false; advances = 0;
        } else {
            if (dut.out_valid && dut.out_ready) {
                if (pending.front().overflow) ++saturated;
                pending.pop_front(); ++completed;
            }
            if (step) ++advances;
            if (t.vertex) {
                Result r = reference(active, {signed_word(dut.vertex_x),
                    signed_word(dut.vertex_y), signed_word(dut.vertex_z)});
                r.due = advances + 4;
                pending.push_back(r); ++accepted;
            }
            if (t.matrix) {
                active[index] = signed_word(dut.matrix_data);
                loaded = index == 15;
                index = (index + 1) % 16; ++matrix_words;
            }
        }
        dut.clk = 1; dut.eval(); ++cycles;
        require(bool(dut.matrix_loaded) == loaded, "matrix_loaded mismatch");
        check_output();
        return t;
    }

    void reset() {
        dut.rst = 1; tick(); dut.rst = 0;
        dut.matrix_valid = 0; dut.vertex_valid = 0; dut.out_ready = 1;
    }

    void drain() {
        dut.matrix_valid = 0; dut.vertex_valid = 0; dut.out_ready = 1;
        for (int n = 0; !pending.empty(); ++n) {
            require(n < 100, "drain timeout"); tick();
        }
    }

    void load(const Matrix& m, bool gaps = false) {
        dut.vertex_valid = 0; dut.out_ready = 1;
        for (unsigned i = 0; i < m.size(); ++i) {
            dut.matrix_valid = 1; dut.matrix_data = static_cast<uint32_t>(m[i]);
            for (int n = 0; ; ++n) {
                require(n < 100, "matrix load timeout");
                if (tick().matrix) break;
            }
            if (gaps && i != 15) {
                dut.matrix_valid = 0; dut.vertex_valid = 1;
                require(!tick().vertex, "vertex accepted during partial matrix load");
                dut.vertex_valid = 0;
            }
        }
        dut.matrix_valid = 0;
    }

    void send(Vertex v) {
        vertex(v); dut.vertex_valid = 1;
        for (int n = 0; ; ++n) {
            require(n < 100, "vertex timeout");
            if (tick().vertex) break;
        }
        dut.vertex_valid = 0;
    }

    void known(Vertex v, std::array<int32_t,4> expected, uint8_t flags = 0) {
        drain(); send(v);
        for (int i = 0; i < 4; ++i) tick();
        require(bool(dut.out_valid), "known example missing output");
        require(signed_word(dut.result_x) == expected[0] &&
                signed_word(dut.result_y) == expected[1] &&
                signed_word(dut.result_z) == expected[2] &&
                signed_word(dut.result_w) == expected[3] &&
                dut.out_overflow == flags, "hand-calculated result mismatch");
        drain();
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        Test t;
        t.dut.vertex_valid = 1;
        for (int i = 0; i < 5; ++i)
            require(!t.tick().vertex, "accepted before any matrix loaded");
        t.dut.vertex_valid = 0;
        Matrix identity{};
        for (int i = 0; i < 4; ++i) identity[i*4+i] = ONE;
        t.load(identity, true);
        t.known({-ONE, 2*ONE, 3*ONE}, {-ONE, 2*ONE, 3*ONE, ONE});
        t.known({INT32_MIN, INT32_MAX, -1}, {INT32_MIN, INT32_MAX, -1, ONE});
        std::cout << "PASS identity, matrix load gaps and implicit input W=1\n";

        Matrix projection{};
        projection[0] = projection[5] = 320*ONE;
        projection[10] = projection[14] = ONE;
        t.load(projection);
        t.known({-ONE,-ONE,4*ONE}, {-320*ONE,-320*ONE,4*ONE,4*ONE});
        std::cout << "PASS triangle A: (X,Y,Z,W) = (-320,-320,4,4)\n";

        Matrix all_rows{};
        for (int i = 0; i < 16; ++i) all_rows[i] = (i+1)*ONE;
        t.load(all_rows);
        t.known({ONE,2*ONE,3*ONE}, {18*ONE,46*ONE,74*ONE,102*ONE});
        std::cout << "PASS row-major matrix with four different row results\n";

        Matrix tiny{}; tiny[0] = 1; tiny[4] = -1; tiny[15] = ONE;
        t.load(tiny);
        t.known({-1,0,0}, {-1,0,0,ONE});
        Matrix extreme{};
        extreme[0] = extreme[1] = extreme[2] = INT32_MIN;
        extreme[4] = extreme[5] = extreme[6] = INT32_MAX;
        extreme[8] = INT32_MAX; extreme[9] = -INT32_MAX;
        extreme[15] = INT32_MIN;
        t.load(extreme);
        t.known({INT32_MIN,INT32_MIN,INT32_MIN}, {INT32_MAX,INT32_MIN,0,INT32_MIN}, 3);
        std::cout << "PASS signed fractional truncation, wide sums, cancellation and saturation\n";

        const std::array<uint32_t,16> pdf_words = {
            0x012e3fce,0xffbe63da,0xffade5e6,0x0ec23011,
            0x002cf82e,0x0132ae4f,0xffb07909,0x0452793c,
            0x00004bfe,0x000032dd,0x0000ef1c,0x000c1c10,
            0x00004bfe,0x000032dd,0x0000ef1c,0x000c1c10};
        Matrix pdf{};
        for (int i = 0; i < 16; ++i) pdf[i] = signed_word(pdf_words[i]);
        t.load(pdf);
        t.send({ONE,2*ONE,3*ONE});
        for (int i = 0; i < 4; ++i) t.tick();
        std::cout << "PASS C-generated PDF matrix: ("
                  << signed_word(t.dut.result_x)/65536.0 << ", "
                  << signed_word(t.dut.result_y)/65536.0 << ", "
                  << signed_word(t.dut.result_z)/65536.0 << ", "
                  << signed_word(t.dut.result_w)/65536.0 << ")\n";
        t.drain();

        // No bubbles: demonstrate acceptance every edge and exact latency.
        t.load(identity);
        for (int i = 0; i < 256; ++i) {
            t.vertex({i,-i,i*37}); t.dut.vertex_valid = 1;
            require(t.tick().vertex, "stream failed to accept one vertex per cycle");
        }
        t.drain();
        std::cout << "PASS 256 consecutive vertices and four-cycle pipeline latency\n";

        // Matrix update competes with vertices while output is blocked.
        for (int i = 0; i < 5; ++i) t.send({i,2*i,-i});
        t.dut.out_ready = 0;
        t.dut.matrix_valid = 1; t.dut.matrix_data = all_rows[0];
        t.dut.vertex_valid = 1;
        for (int i = 0; i < 10; ++i) {
            const Transfers tr = t.tick();
            require(!tr.matrix && !tr.vertex, "reload accepted while old output stalled");
        }
        t.dut.out_ready = 1;
        for (int n = 0; ; ++n) {
            require(n < 100, "reload drain timeout");
            if (t.tick().matrix) break;
        }
        require(!t.loaded, "partial new matrix should not be usable");
        for (int i = 1; i < 16; ++i) {
            t.dut.matrix_data = all_rows[i];
            require(t.tick().matrix, "reload word unexpectedly stalled");
        }
        t.dut.matrix_valid = 0; t.dut.vertex_valid = 0;
        t.known({ONE,2*ONE,3*ONE}, {18*ONE,46*ONE,74*ONE,102*ONE});
        std::cout << "PASS output hold, update priority and safe matrix replacement\n";

        // Reset both a partial matrix and a pipeline with work in flight.
        t.dut.matrix_valid = 1; t.dut.matrix_data = 123;
        for (int i = 0; i < 7; ++i) t.tick();
        t.reset(); t.load(identity);
        for (int i = 0; i < 4; ++i) t.send({i,i,i});
        t.dut.out_ready = 0; t.tick(); t.reset();
        t.dut.vertex_valid = 1;
        for (int i = 0; i < 10; ++i)
            require(!t.tick().vertex, "reset did not invalidate matrix");
        t.dut.vertex_valid = 0;
        std::cout << "PASS reset during partial load and stalled pipeline\n";

        std::mt19937 rng(0x4d415458u);
        for (int batch = 0; batch < 32; ++batch) {
            Matrix m;
            for (auto& word : m) word = (batch % 2)
                ? signed_word(rng()) : static_cast<int32_t>(rng()%524289)-262144;
            t.load(m, batch % 3 == 0);
            unsigned sent = 0;
            for (int watchdog = 0; sent < 128; ++watchdog) {
                require(watchdog < 10000, "randomized stream timeout");
                if (!t.dut.vertex_valid && rng()%4 != 0) {
                    Vertex v;
                    for (auto& coordinate : v) coordinate = (batch % 2)
                        ? signed_word(rng())
                        : static_cast<int32_t>(rng()%2097153)-1048576;
                    t.vertex(v);
                    t.dut.vertex_valid = 1;
                }
                t.dut.out_ready = rng()%4 != 0;
                if (t.tick().vertex) { ++sent; t.dut.vertex_valid = 0; }
            }
            t.drain();
        }
        require(t.accepted == t.completed + t.discarded, "lost/duplicated output");
        std::cout << "PASS randomized matrices, full-range vertices, bubbles and backpressure\n"
                  << "ALL TESTS PASSED: " << t.completed << " results checked, "
                  << t.discarded << " deliberately reset, " << t.saturated
                  << " saturated results, " << t.matrix_words << " matrix words accepted\n";
        t.dut.final();
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL: " << e.what() << '\n';
        return 1;
    }
}
