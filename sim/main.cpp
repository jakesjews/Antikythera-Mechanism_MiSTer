// SPDX-License-Identifier: GPL-2.0-or-later
// Native simulation of the actual RTL: headless regression against the
// Python reference model, frame captures as PNG, and an optional interactive
// SDL window.
#include "Vantikythera.h"
#include "verilated.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#ifdef USE_SDL
#include <SDL.h>
#endif

static void require(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}

// Minimal PNG writer (stored deflate blocks), no external dependencies.
static uint32_t crc_table[256];
static void init_crc() {
    for (uint32_t n = 0; n < 256; ++n) {
        uint32_t c = n;
        for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xedb88320u ^ (c >> 1) : c >> 1;
        crc_table[n] = c;
    }
}
static uint32_t crc(const uint8_t* data, size_t len, uint32_t c = 0xffffffffu) {
    for (size_t i = 0; i < len; ++i) c = crc_table[(c ^ data[i]) & 0xff] ^ (c >> 8);
    return c;
}
static void put32(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back(x >> 24); v.push_back(x >> 16); v.push_back(x >> 8); v.push_back(x);
}
static void chunk(std::ofstream& f, const char* type, const std::vector<uint8_t>& data) {
    std::vector<uint8_t> buf;
    put32(buf, data.size());
    buf.insert(buf.end(), type, type + 4);
    buf.insert(buf.end(), data.begin(), data.end());
    uint32_t c = crc(buf.data() + 4, data.size() + 4) ^ 0xffffffffu;
    put32(buf, c);
    f.write(reinterpret_cast<const char*>(buf.data()), buf.size());
}
static void write_png(const std::string& path, const std::vector<uint8_t>& rgb, int w, int hgt) {
    init_crc();
    std::ofstream f(path, std::ios::binary);
    require(f.good(), "cannot write " + path);
    static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    f.write(reinterpret_cast<const char*>(sig), 8);
    std::vector<uint8_t> ihdr;
    put32(ihdr, w); put32(ihdr, hgt);
    ihdr.insert(ihdr.end(), {8, 2, 0, 0, 0});
    chunk(f, "IHDR", ihdr);
    std::vector<uint8_t> raw;
    for (int y = 0; y < hgt; ++y) {
        raw.push_back(0);
        raw.insert(raw.end(), rgb.begin() + y * w * 3, rgb.begin() + (y + 1) * w * 3);
    }
    std::vector<uint8_t> z = {0x78, 0x01};
    size_t pos = 0;
    uint32_t a = 1, b = 0;
    for (uint8_t byte : raw) { a = (a + byte) % 65521; b = (b + a) % 65521; }
    while (pos < raw.size()) {
        size_t n = std::min<size_t>(65535, raw.size() - pos);
        bool last = pos + n == raw.size();
        z.push_back(last ? 1 : 0);
        z.push_back(n & 0xff); z.push_back(n >> 8);
        z.push_back(~n & 0xff); z.push_back((~n >> 8) & 0xff);
        z.insert(z.end(), raw.begin() + pos, raw.begin() + pos + n);
        pos += n;
    }
    put32(z, (b << 16) | a);
    chunk(f, "IDAT", z);
    chunk(f, "IEND", {});
}

class Simulation {
public:
    Vantikythera top;
    uint64_t clocks = 0;
    int h = 0, v = 0;
    bool last_vsync = true, last_hsync = true;
    bool await_first_line = true;
    std::vector<uint8_t> frame = std::vector<uint8_t>(640 * 480 * 3, 0);
    bool frame_complete = false;
    int pixels_in_frame = 0;

    Simulation() {
        top.clk = 0; top.reset = 1; top.osd_open = 0; top.ps2_key = 0; top.joystick = 0;
        top.menu_epoch = 0; top.menu_b1_224 = 0; top.menu_ring_lunar = 0; top.menu_ring_manual = 0;
        top.menu_cosmos_off = 0; top.menu_view = 0; top.menu_view_set = 0; top.menu_run = 0; top.menu_home = 0;
        reset();
    }
    ~Simulation() { top.final(); }
    void tick(unsigned n = 1) {
        for (unsigned i = 0; i < n; ++i) {
            top.clk = 0; top.eval();
            top.clk = 1; top.eval();
            ++clocks;
            if (top.ce_pixel) capture_pixel();
        }
    }
    void reset() { top.reset = 1; tick(16); top.reset = 0; tick(16); }
    void capture_pixel() {
        bool vs = top.vsync, hs = top.hsync;
        if (!vs && last_vsync) {
            frame_complete = pixels_in_frame > 0;
            pixels_in_frame = 0;
            await_first_line = true;
        }
        if (!hs && last_hsync) {
            if (!await_first_line) ++v;
            h = -1;
        }
        last_vsync = vs; last_hsync = hs;
        if (top.de) {
            if (await_first_line) { await_first_line = false; v = 0; h = -1; }
            ++h;
            if (h >= 0 && h < 640 && v >= 0 && v < 480) {
                size_t i = (v * 640 + h) * 3;
                frame[i] = top.red; frame[i + 1] = top.green; frame[i + 2] = top.blue;
                ++pixels_in_frame;
            }
        }
    }
    void event(unsigned code, bool down) {
        top.ps2_key = ((top.ps2_key ^ 0x400) & 0x400) | (down ? 0x200 : 0) | code;
        tick(4);
    }
    void key(unsigned code) { event(code, true); event(code, false); }
    void until(const std::function<bool()>& predicate, uint64_t maximum = 4000000) {
        for (uint64_t n = 0; n < maximum; ++n) {
            if (predicate()) return;
            tick();
        }
        throw std::runtime_error("simulation timeout at clock " + std::to_string(clocks));
    }
    // Run whole frames. A change is computed at the end of one frame,
    // snapshotted by the renderer, and visible in the frame after that.
    void frames(int n) {
        for (int i = 0; i < n; ++i) {
            frame_complete = false;
            until([&] { return frame_complete; }, 2000000);
        }
    }
    void save(const std::string& path) { write_png(path, frame, 640, 480); }
    double frac(int shaft) const {
        uint32_t bits = 0;
        int base = shaft * 20;
        for (int b = 0; b < 20; ++b) {
            int bit = base + b;
            if ((top.fracs[bit / 32] >> (bit % 32)) & 1) bits |= 1u << b;
        }
        return bits / 1048576.0;
    }
    int64_t ticks() const {
        int64_t t = (int64_t)top.ticks;
        if (t & (1LL << 39)) t -= 1LL << 40;
        return t;
    }
};

struct Expect { int64_t ticks; int epoch; std::vector<double> fracs; std::vector<double> bodies; int met_cell, sar_cell; };

static std::vector<Expect> load_vectors(const std::string& path) {
    std::ifstream f(path);
    require(f.good(), "cannot read " + path);
    std::vector<Expect> out;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        Expect e;
        s >> e.ticks >> e.epoch;
        e.fracs.resize(23);
        for (auto& x : e.fracs) s >> x;
        e.bodies.resize(8);
        for (auto& x : e.bodies) s >> x;
        s >> e.met_cell >> e.sar_cell;
        out.push_back(e);
    }
    return out;
}

static double angle_error(double a, double b) {
    double d = std::fabs(a - b);
    return std::min(d, 1.0 - d);
}

static int run_tests(const std::string& vectors_path) {
    Simulation sim;
    auto vectors = load_vectors(vectors_path);
    const int64_t YEAR = 23937024, MONTH = 1935274, DAY = 65536;
    int checked = 0;
    for (const auto& e : vectors) {
        sim.top.menu_epoch = e.epoch;
        sim.top.menu_home = 1; sim.tick(4); sim.top.menu_home = 0; sim.tick(64);
        bool fwd = e.ticks >= 0;
        int64_t remaining = std::llabs(e.ticks);
        int64_t years = remaining / YEAR; remaining %= YEAR;
        int64_t months = remaining / MONTH; remaining %= MONTH;
        int64_t days = remaining / DAY; remaining %= DAY;
        require(remaining == 0, "vector ticks are not a sum of year, month and day steps");
        for (int64_t i = 0; i < years; ++i) sim.key(fwd ? 0x17d : 0x17a);
        for (int64_t i = 0; i < months; ++i) sim.key(fwd ? 0x175 : 0x172);
        for (int64_t i = 0; i < days; ++i) sim.key(fwd ? 0x174 : 0x16b);
        sim.until([&] { return sim.ticks() == e.ticks; }, 4000000);
        sim.frames(3);
        require(sim.ticks() == e.ticks, "tick count drifted after the steps");
        for (int s = 0; s < 23; ++s) {
            double err = angle_error(sim.frac(s), e.fracs[s]);
            if (err > 3e-6) {
                std::cerr << "shaft " << s << " at ticks " << e.ticks << " epoch " << e.epoch
                          << ": rtl " << sim.frac(s) << " model " << e.fracs[s] << " error " << err << "\n";
                return 1;
            }
        }
        const char* names[8] = {"sun", "moon", "node", "mercury", "venus", "mars", "jupiter", "saturn"};
        double rtl[8] = {sim.top.lon_sun / 1048576.0, sim.top.lon_moon / 1048576.0, sim.top.lon_node / 1048576.0,
                         sim.top.lon_mercury / 1048576.0, sim.top.lon_venus / 1048576.0, sim.top.lon_mars / 1048576.0,
                         sim.top.lon_jupiter / 1048576.0, sim.top.lon_saturn / 1048576.0};
        for (int b = 0; b < 8; ++b) {
            if (angle_error(rtl[b], e.bodies[b]) > 1e-5) {
                std::cerr << names[b] << " longitude at ticks " << e.ticks << ": rtl " << rtl[b] << " model " << e.bodies[b] << "\n";
                return 1;
            }
        }
        if (sim.top.met_cell != e.met_cell || sim.top.sar_cell != e.sar_cell) {
            std::cerr << "cells at ticks " << e.ticks << ": metonic rtl " << (int)sim.top.met_cell << " model " << e.met_cell
                      << ", saros rtl " << (int)sim.top.sar_cell << " model " << e.sar_cell << "\n";
            return 1;
        }
        ++checked;
    }
    // Turning the calendar ring by hand moves the reading one day per turn.
    sim.top.menu_epoch = 0;
    sim.top.menu_home = 1; sim.tick(4); sim.top.menu_home = 0; sim.frames(3);
    int index0 = sim.top.debug_ring_index;
    require(sim.top.debug_ring_auto == 1, "ring should register automatically after the epoch");
    sim.key(0x5b); sim.frames(3);
    require(sim.top.debug_ring_auto == 0 && sim.top.debug_ring_index == index0 - 1, "ring turn forward did not move one day");
    sim.key(0x54); sim.key(0x54); sim.frames(3);
    require(sim.top.debug_ring_index == index0 + 1, "ring turn back did not move one day");
    std::cout << "PASS " << checked << " vectors: all 23 shafts, the Sun, Moon, node and five planets, Metonic and Saros cells match the model; ring turns by hand\n";
    return 0;
}

static int screenshots(const std::string& dir) {
    Simulation sim;
    sim.frames(3);
    sim.save(dir + "/01-front.png");
    sim.key(0x1e); sim.frames(3); sim.save(dir + "/02-back.png");
    sim.key(0x26); sim.frames(3); sim.save(dir + "/03-gears.png");
    sim.key(0x16); sim.key(0x05); sim.frames(3); sim.save(dir + "/04-help.png");
    sim.key(0x05);
    // Four years forward, a lunar month at a time, to show the pointers moving.
    for (int i = 0; i < 50; ++i) sim.key(0x175);
    sim.until([&] { return sim.ticks() >= 50LL * 1935274; }, 4000000);
    sim.frames(3); sim.save(dir + "/05-front-four-years.png");
    sim.key(0x1e); sim.frames(3); sim.save(dir + "/06-back-four-years.png");
    sim.top.menu_epoch = 1; sim.top.menu_home = 1; sim.tick(4); sim.top.menu_home = 0;
    sim.key(0x16); sim.frames(3); sim.save(dir + "/07-front-178bc.png");
    sim.top.menu_ring_lunar = 1; sim.frames(3); sim.save(dir + "/08-lunar-ring.png");
    sim.top.menu_ring_lunar = 0; sim.top.menu_cosmos_off = 1; sim.frames(3); sim.save(dir + "/09-sun-moon-only.png");
    sim.top.menu_cosmos_off = 0;
    // Turn the ring by hand, then run at the fastest speed for a century.
    sim.key(0x5b); sim.key(0x5b); sim.frames(3); sim.save(dir + "/10-ring-by-hand.png");
    for (int i = 0; i < 4; ++i) sim.key(0x55);
    sim.key(0x29);
    sim.until([&] { return sim.ticks() > 100LL * 23937024; }, 160000000);
    sim.key(0x29); sim.frames(3); sim.save(dir + "/11-a-century-later.png");
    std::cout << "screenshots written to " << dir << "\n";
    return 0;
}

#ifdef USE_SDL
static int interactive() {
    Simulation sim;
    SDL_Init(SDL_INIT_VIDEO);
    SDL_Window* win = SDL_CreateWindow("Antikythera Mechanism", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 1280, 960, SDL_WINDOW_SHOWN);
    SDL_Renderer* ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture* tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGB24, SDL_TEXTUREACCESS_STREAMING, 640, 480);
    bool quit = false;
    auto code_of = [](SDL_Keycode k) -> unsigned {
        switch (k) {
            case SDLK_SPACE: return 0x29; case SDLK_LEFT: return 0x16b; case SDLK_RIGHT: return 0x174;
            case SDLK_UP: return 0x175; case SDLK_DOWN: return 0x172; case SDLK_PAGEUP: return 0x17d;
            case SDLK_PAGEDOWN: return 0x17a; case SDLK_EQUALS: return 0x55; case SDLK_MINUS: return 0x4e;
            case SDLK_r: return 0x2d; case SDLK_HOME: return 0x16c; case SDLK_TAB: return 0x0d;
            case SDLK_1: return 0x16; case SDLK_2: return 0x1e; case SDLK_3: return 0x26;
            case SDLK_F1: return 0x05; case SDLK_ESCAPE: return 0x76;
            case SDLK_LEFTBRACKET: return 0x54; case SDLK_RIGHTBRACKET: return 0x5b;
            default: return 0;
        }
    };
    while (!quit) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT) quit = true;
            if (ev.type == SDL_KEYDOWN || ev.type == SDL_KEYUP) {
                if (ev.key.repeat) continue;
                unsigned c = code_of(ev.key.keysym.sym);
                if (c) sim.event(c, ev.type == SDL_KEYDOWN);
            }
        }
        sim.frames(1);
        SDL_UpdateTexture(tex, nullptr, sim.frame.data(), 640 * 3);
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, nullptr, nullptr);
        SDL_RenderPresent(ren);
    }
    SDL_Quit();
    return 0;
}
#endif

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        if (argc >= 3 && std::strcmp(argv[1], "--test") == 0) return run_tests(argv[2]);
        if (argc >= 3 && std::strcmp(argv[1], "--screenshots") == 0) return screenshots(argv[2]);
#ifdef USE_SDL
        if (argc >= 2 && std::strcmp(argv[1], "--interactive") == 0) return interactive();
#endif
        std::cerr << "usage: am_sim --test vectors.txt | --screenshots dir | --interactive\n";
        return 2;
    } catch (const std::exception& e) {
        std::cerr << "FAIL " << e.what() << "\n";
        return 1;
    }
}
