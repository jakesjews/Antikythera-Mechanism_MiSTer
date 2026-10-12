PYTHON ?= python3
VERILATOR ?= verilator

RTL := rtl/am_font.sv rtl/am_strings.sv rtl/am_cordic.sv rtl/am_polar.sv rtl/am_shafts.sv \
       rtl/am_timebase.sv rtl/am_cosmos.sv rtl/am_calendar.sv rtl/am_controls.sv rtl/am_video.sv \
       rtl/antikythera.sv
GENERATED := rtl/am_tables.svh rtl/am_strings.sv rtl/am_font.sv
# FPGA power-up values and explicitly unused output ports are intentional.
# Comparisons against integer geometry constants expand widths harmlessly.
VFLAGS := -Wall -Wno-PROCASSINIT -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Irtl

.PHONY: all tables lint test test-mister sim screenshots framework-check clean

all: test

$(GENERATED): tools/generate_tables.py tools/mechanism.py
	$(PYTHON) tools/generate_tables.py

tables: $(GENERATED)

lint: $(GENERATED)
	$(VERILATOR) --lint-only $(VFLAGS) --top-module antikythera $(RTL)

build/vectors.txt: sim/generate_vectors.py tools/mechanism.py tools/generate_tables.py
	@mkdir -p build
	$(PYTHON) sim/generate_vectors.py

build/sim/am_sim: $(RTL) $(GENERATED) sim/main.cpp
	@mkdir -p build/sim
	$(VERILATOR) --cc --exe --build -j 4 $(VFLAGS) --top-module antikythera \
		--Mdir build/sim -o am_sim -CFLAGS "-std=c++17 -O2" $(RTL) $(CURDIR)/sim/main.cpp

build/sim-sdl/am_sim: $(RTL) $(GENERATED) sim/main.cpp
	@mkdir -p build/sim-sdl
	$(VERILATOR) --cc --exe --build -j 4 $(VFLAGS) --top-module antikythera \
		--Mdir build/sim-sdl -o am_sim -CFLAGS "-std=c++17 -O2 -DUSE_SDL $$(sdl2-config --cflags)" \
		-LDFLAGS "$$(sdl2-config --libs)" $(RTL) $(CURDIR)/sim/main.cpp

test: lint build/vectors.txt build/sim/am_sim
	$(PYTHON) tools/mechanism.py > build/model.log
	build/sim/am_sim --test build/vectors.txt
	$(MAKE) test-mister

# The unmodified framework's hps_io, video_mixer and video_freak around the
# wrapper. Framework compatibility warnings stay in build/mister-build.log.
# video_mixer_sim.sv is the framework mixer with three declarations hoisted out of an
# unnamed generate block that Verilator scopes differently from Quartus.
FRAMEWORK_VIDEO := sys/hps_io.sv sim/video_mixer_sim.sv sys/video_freezer.sv sys/gamma_corr.sv \
                   sys/scandoubler.v sys/hq2x.sv sys/math.sv sys/video_freak.sv
test-mister: screenshots
	@mkdir -p build/mister
	$(VERILATOR) --binary --timing -j 4 -Wno-fatal -Wno-PINMISSING -Wno-PROCASSWIRE -Irtl -Isim -I. \
		--top-module tb_emu --Mdir build/mister -o tb_emu \
		$(RTL) sim/am_pll.sv Antikythera.sv $(FRAMEWORK_VIDEO) sim/tb_emu.sv > build/mister-build.log 2>&1
	build/mister/tb_emu
	uv run --quiet sim/compare_frames.py build/mister/frame.ppm build/screenshots/01-front.png

sim: build/sim-sdl/am_sim
	build/sim-sdl/am_sim --interactive

screenshots: build/sim/am_sim
	@mkdir -p build/screenshots
	build/sim/am_sim --screenshots build/screenshots

framework-check:
	@git diff --exit-code 24e9a13aa19722853c962a35a367a62e474002b3 -- sys
	@echo "MiSTer sys/ matches the initial template commit."

clean:
	rm -rf build/sim build/sim-sdl build/mister build/vectors.txt build/screenshots build/model.log build/mister-build.log
