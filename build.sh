#!/bin/zsh
# Quartus 17.0.2 build, either in the Docker image on the Ubuntu server
# (default) or locally through CrossOver. Never launched by make test.
# Usage: ./build.sh [remote|local] [map|compile]
set -euo pipefail
cd "$(dirname "$0")"

where=${1:-remote}
build_mode=${2:-compile}
case "$where" in remote|local) ;; *) print -u2 'Usage: ./build.sh [remote|local] [map|compile]'; exit 1 ;; esac
case "$build_mode" in map|compile) ;; *) print -u2 'Usage: ./build.sh [remote|local] [map|compile]'; exit 1 ;; esac

mkdir -p build
# Synthesis-only runs do not invoke the framework pre-flow date generator.
print -r -- "\`define BUILD_DATE \"$(date +%y%m%d)\"" > build_id.v

if [[ "$where" == remote ]]; then
    host=${BUILD_HOST:-ubuntu}
    dir=${BUILD_DIR:-dv-builds/Antikythera}
    rsync -a --delete --exclude build --exclude db --exclude incremental_db --exclude output_files \
        --exclude .git --exclude '*.rbf' ./ "$host:$dir/"
    if [[ "$build_mode" == map ]]; then
        ssh "$host" "docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp -v \$HOME/$dir:/project -w /project \
            theypsilon/quartus-lite-c5:17.0.2.docker0 \
            /opt/intelFPGA_lite/quartus/bin/quartus_map --read_settings_files=on --write_settings_files=off Antikythera -c Antikythera" \
            2>&1 | tee build/quartus-map.log
    else
        ssh "$host" "docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp -v \$HOME/$dir:/project -w /project \
            theypsilon/quartus-lite-c5:17.0.2.docker0 \
            /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile Antikythera" 2>&1 | tee build/quartus-compile.log
        ssh "$host" "docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp -v \$HOME/$dir:/project -w /project \
            theypsilon/quartus-lite-c5:17.0.2.docker0 \
            /opt/intelFPGA_lite/quartus/bin/quartus_sta -t tools/report_timing.tcl" 2>&1 | tee build/timing-report.log
        mkdir -p output_files
        rsync -a "$host:$dir/output_files/Antikythera.rbf" output_files/
        rsync -a "$host:$dir/build/" build/ 2>/dev/null || true
        if rg -q 'Timing requirements not met' build/quartus-compile.log; then
            print -u2 'Quartus produced output, but timing requirements were not met.'
            exit 2
        fi
        test -s output_files/Antikythera.rbf
    fi
else
    cx_bin=${CROSSOVER_BIN:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin}
    quartus_bottle=${QUARTUS_BOTTLE:-Quartus}
    quartus_bin=${QUARTUS_BIN:-C:/intelFPGA_lite/17.0/quartus/bin64}
    if [[ "$build_mode" == map ]]; then
        "$cx_bin/wine" --bottle "$quartus_bottle" --workdir "$PWD" --cx-app \
            "$quartus_bin/quartus_map.exe" --read_settings_files=on --write_settings_files=off \
            Antikythera -c Antikythera 2>&1 | tee build/quartus-map.log
    else
        "$cx_bin/wine" --bottle "$quartus_bottle" --workdir "$PWD" --cx-app \
            "$quartus_bin/quartus_sh.exe" --flow compile Antikythera 2>&1 | tee build/quartus-compile.log
        if rg -q 'Timing requirements not met' build/quartus-compile.log; then
            print -u2 'Quartus produced output, but timing requirements were not met.'
            exit 2
        fi
        "$cx_bin/wine" --bottle "$quartus_bottle" --workdir "$PWD" --cx-app \
            "$quartus_bin/quartus_sta.exe" -t tools/report_timing.tcl 2>&1 | tee build/timing-report.log
        test -s output_files/Antikythera.rbf
    fi
fi
