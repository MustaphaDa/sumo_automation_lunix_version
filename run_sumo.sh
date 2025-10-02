#!/usr/bin/env bash

set -euo pipefail

# ========================================
#    Automated SUMO Workflow (Linux)
# ========================================

# Base directory of this project (location of this script)
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colored logs
log_info()    { echo -e "\e[36m[INFO]\e[0m    $*"; }
log_success() { echo -e "\e[32m[SUCCESS]\e[0m $*"; }
log_warn()    { echo -e "\e[33m[WARNING]\e[0m $*"; }
log_error()   { echo -e "\e[31m[ERROR]\e[0m   $*"; }

die() { log_error "$*"; exit 1; }

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

get_python_cmd() {
    if [[ -n "${PYTHON:-}" ]]; then
        echo "$PYTHON"; return 0
    fi
    if check_cmd python3; then echo python3; return 0; fi
    if check_cmd python; then echo python; return 0; fi
    die "Python not found. Install python3 or set PYTHON env var."
}

sanitize_name() {
    # Remove diacritics and unsafe chars for filenames using Python
    local input="$1"
    $(get_python_cmd) - "$input" <<'PY'
import sys, unicodedata, re
text = sys.argv[1]
norm = unicodedata.normalize('NFD', text)
clean = ''.join(ch for ch in norm if unicodedata.category(ch) != 'Mn')
clean = unicodedata.normalize('NFC', clean)
clean = re.sub(r"[^A-Za-z0-9._-]", "_", clean)
print(clean)
PY
}

ensure_python_packages() {
    local pycmd="$1"
    log_info "Ensuring required Python packages are installed..."
    local modules=(requests numpy pandas lxml shapely rtree pyproj openpyxl)
    local missing=()
    for m in "${modules[@]}"; do
        if ! "$pycmd" -c "import ${m}" >/dev/null 2>&1; then
            missing+=("$m")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        log_info "Installing missing: ${missing[*]}"
        "$pycmd" -m pip install --no-cache-dir ${missing[@]}
    fi
}

resolve_sumo() {
    log_info "Checking SUMO tools..."
    local tools=(sumo netconvert od2trips duarouter)
    local missing=()
    for t in "${tools[@]}"; do
        if ! check_cmd "$t"; then missing+=("$t"); fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing tools: ${missing[*]}. Ensure SUMO is installed and on PATH."
    fi

    if [[ -z "${SUMO_HOME:-}" ]]; then
        # Common path on Debian/Ubuntu packages
        if [[ -d "/usr/share/sumo" ]]; then
            export SUMO_HOME="/usr/share/sumo"
        fi
    fi
    [[ -n "${SUMO_HOME:-}" ]] || die "SUMO_HOME not set. Set it or install sumo (so /usr/share/sumo exists)."

    GTFS2PT="$SUMO_HOME/tools/import/gtfs/gtfs2pt.py"
    [[ -f "$GTFS2PT" ]] || die "gtfs2pt.py not found at $GTFS2PT"
    export GTFS2PT
    log_info "Using SUMO_HOME: $SUMO_HOME"
}

parse_config_json() {
    # Reads config.json if present using Python (no jq dependency)
    local key="$1"
    if [[ ! -f config.json ]]; then return 0; fi
    $(get_python_cmd) - "$key" <<'PY'
import json,sys
k=sys.argv[1]
try:
    with open('config.json','r',encoding='utf-8') as f:
        cfg=json.load(f)
    v=cfg.get(k)
    if v is None:
        # also support centerX/centerY exact case
        if k in ('centerX','centerY'):
            v=cfg.get(k)
    if v is not None:
        print(v)
except Exception:
    pass
PY
}

load_config() {
    log_info "Loading configuration from env or config.json..."

    CITY_NAME="${CITY_NAME:-$(parse_config_json cityName || true)}"
    GTFS_PATH="${GTFS_PATH:-$(parse_config_json gtfsPath || true)}"
    SIM_DATE="${SIM_DATE:-$(parse_config_json simDate || true)}"
    TRANSPORT_MODES="${TRANSPORT_MODES:-$(parse_config_json transportModes || true)}"
    MAX_JOBS="${MAX_JOBS:-$(parse_config_json maxJobs || true)}"
    CENTER_X="${CENTER_X:-$(parse_config_json centerX || true)}"
    CENTER_Y="${CENTER_Y:-$(parse_config_json centerY || true)}"
    SIMS_PER_VALUE="${SIMS_PER_VALUE:-$(parse_config_json simsPerValue || true)}"
    
    # Time configuration (in seconds for SUMO, will convert for OD matrix)
    SIM_BEGIN="${SIM_BEGIN:-$(parse_config_json simBegin || true)}"
    SIM_END="${SIM_END:-$(parse_config_json simEnd || true)}"
    BASELINE_END="${BASELINE_END:-$(parse_config_json baselineEnd || true)}"

    TRANSPORT_MODES=${TRANSPORT_MODES:-bus}
    SIMS_PER_VALUE=${SIMS_PER_VALUE:-10}
    MAX_JOBS=${MAX_JOBS:-$(nproc || echo 2)}
    SIM_BEGIN=${SIM_BEGIN:-21600}    # default 6:00 AM
    SIM_END=${SIM_END:-36000}        # default 10:00 AM
    BASELINE_END=${BASELINE_END:-39600}  # default 11:00 AM for baseline

    [[ -n "${CITY_NAME:-}" ]] || die "CITY_NAME is required (env or config.json cityName)"
    [[ -n "${GTFS_PATH:-}" ]] || die "GTFS_PATH is required (env or config.json gtfsPath)"
    [[ -f "$GTFS_PATH" ]] || die "GTFS file not found: $GTFS_PATH"
    [[ "${SIM_DATE:-}" =~ ^[0-9]{8}$ ]] || die "SIM_DATE must be YYYYMMDD"

    GTFS_PATH_ABS="$(readlink -f "$GTFS_PATH")"
    CITY_SAFE="$(sanitize_name "$CITY_NAME")"
    
    # Convert seconds to HH.MM format for OD matrix
    OD_FROM_TIME=$(printf "%02d.%02d" $((SIM_BEGIN / 3600)) $(((SIM_BEGIN % 3600) / 60)))
    OD_TO_TIME=$(printf "%02d.%02d" $((SIM_END / 3600)) $(((SIM_END % 3600) / 60)))

    export CITY_NAME CITY_SAFE GTFS_PATH GTFS_PATH_ABS SIM_DATE TRANSPORT_MODES MAX_JOBS CENTER_X CENTER_Y SIMS_PER_VALUE
    export SIM_BEGIN SIM_END BASELINE_END OD_FROM_TIME OD_TO_TIME
    log_success "Config loaded: CITY='${CITY_NAME}', DATE=${SIM_DATE}, MODES='${TRANSPORT_MODES}', JOBS=${MAX_JOBS}, SIMS=${SIMS_PER_VALUE}"
    log_info "Simulation times: BEGIN=${SIM_BEGIN}s (${OD_FROM_TIME}), END=${SIM_END}s (${OD_TO_TIME}), BASELINE_END=${BASELINE_END}s"
}

create_config_files() {
    log_info "Creating OD template and od2trips config if missing..."
    if [[ ! -f private_traffic.od ]]; then
        cat > private_traffic.od <<OD
\$O;D2
*From-Time To-Time
${OD_FROM_TIME} ${OD_TO_TIME}
*Factor
1.00
*some
*additional
*comments
    zone2	zone1	10000	
    zone3	zone1   10000
OD
        log_success "private_traffic.od created with time ${OD_FROM_TIME} to ${OD_TO_TIME}"
    fi

    if [[ ! -f od2trips.config.xml ]]; then
        cat > od2trips.config.xml <<'XML'
<configuration>

    <input>
        <taz-files value="zones.taz.xml"/>
        <od-matrix-files value="private_traffic.od"/>
    </input>

</configuration>

XML
        log_success "od2trips.config.xml created"
    fi
}

make_dirs() {
    OUT_ROOT="$(pwd)/outputs"
    OUT_OSM="$OUT_ROOT/osm"
    OUT_NET="$OUT_ROOT/net"
    OUT_ZONES="$OUT_ROOT/zones"
    OUT_GTFS="$OUT_ROOT/gtfs"
    OUT_SIM="$OUT_ROOT/sim"
    mkdir -p "$OUT_ROOT" "$OUT_OSM" "$OUT_NET" "$OUT_ZONES" "$OUT_GTFS" "$OUT_SIM"
}

download_osm() {
    local osm_file="$OUT_OSM/${CITY_SAFE}.osm"
    # If user provided a pre-downloaded OSM file, use it
    if [[ -n "${OSM_XML_PATH:-}" ]]; then
        if [[ -f "$OSM_XML_PATH" ]]; then
            log_info "Using provided OSM XML from OSM_XML_PATH: $OSM_XML_PATH"
            cp -f "$OSM_XML_PATH" "$osm_file"
            OSM_FILE="$osm_file"; export OSM_FILE; return 0
        else
            log_warn "OSM_XML_PATH set but file not found: $OSM_XML_PATH (falling back to download)"
        fi
    fi
    if [[ -f "$osm_file" ]] && [[ $(stat -c%s "$osm_file") -ge 50000 ]]; then
        log_warn "OSM already present and looks valid: $osm_file"
        OSM_FILE="$osm_file"; export OSM_FILE; return 0
    fi
    log_info "Downloading OSM map for '${CITY_NAME}'..."
    $(get_python_cmd) get_map.py --city "$CITY_NAME" --outfile "$osm_file"
    [[ -f "$osm_file" ]] || die "OSM download failed"
    local size=$(stat -c%s "$osm_file")
    (( size >= 50000 )) || die "Downloaded OSM seems too small ($size bytes)"
    log_success "OSM downloaded: $osm_file ($size bytes)"
    OSM_FILE="$osm_file"; export OSM_FILE
}

build_network() {
    NET_FILE="$OUT_NET/${CITY_SAFE}_full.net.xml"
    if [[ -f "$NET_FILE" ]]; then
        log_warn "Network already exists: $NET_FILE"
        return 0
    fi
    log_info "Converting OSM to SUMO network..."
    local ptStops="$OUT_NET/osm_ptstops.xml"
    local ptLines="$OUT_NET/osm_ptlines.xml"
    netconvert --osm-files "$OSM_FILE" -o "$NET_FILE" \
               --ptstop-output "$ptStops" \
               --ptline-output "$ptLines" \
               --ignore-errors \
               --remove-edges.isolated \
               --ramps.guess \
               --junctions.join | cat
    [[ -f "$NET_FILE" ]] || die "Failed to create network file"
    log_success "Network file created: $NET_FILE"
}

auto_center() {
    if [[ -n "${CENTER_X:-}" && -n "${CENTER_Y:-}" ]]; then
        log_info "Using center from config: X=$CENTER_X Y=$CENTER_Y"
        return 0
    fi
    log_info "Detecting center coordinates from network..."
    ( cd "$OUT_NET" && $(get_python_cmd) "$BASE_DIR/get_center.py" "$(basename "$NET_FILE")" ) | tee /tmp/center.out
    if grep -Eo "Suggested center: \([0-9.-]+, [0-9.-]+\)" /tmp/center.out >/dev/null; then
        local line
        line=$(grep -Eo "Suggested center: \([0-9.-]+, [0-9.-]+\)" /tmp/center.out | head -n1)
        CENTER_X=$(echo "$line" | sed -E 's/.*\(([0-9.-]+), ([0-9.-]+)\).*/\1/')
        CENTER_Y=$(echo "$line" | sed -E 's/.*\(([0-9.-]+), ([0-9.-]+)\).*/\2/')
        export CENTER_X CENTER_Y
        log_success "Center: X=$CENTER_X Y=$CENTER_Y"
    else
        die "Could not parse center coordinates"
    fi
}

create_zones_and_taz() {
    local zone1="$OUT_ZONES/zone1.xml"
    local zone2="$OUT_ZONES/zone2.xml"
    local zone3="$OUT_ZONES/zone3.xml"
    if [[ -f "$zone1" && -f "$zone2" && -f "$zone3" ]]; then
        log_warn "Zone files already exist"
    else
        log_info "Creating zones..."
        ( cd "$OUT_ZONES" && $(get_python_cmd) "$BASE_DIR/get_zones.py" "$NET_FILE" "$CENTER_X" "$CENTER_Y" ) | cat
        [[ -f "$zone1" && -f "$zone2" && -f "$zone3" ]] || die "Failed to create all zone files"
        log_success "Zones created"
    fi
    local taz="$OUT_ZONES/zones.taz.xml"
    if [[ -f "$taz" ]]; then
        log_warn "TAZ already exists: $taz"
    else
        log_info "Creating TAZ..."
        ( cd "$OUT_ZONES" && $(get_python_cmd) "$BASE_DIR/get_taz.py" ) | cat
        [[ -f "$taz" ]] || die "Failed to create TAZ"
        log_success "TAZ created"
    fi
    ZONES_TAZ="$taz"; export ZONES_TAZ
}

process_gtfs() {
    local vtypes="$OUT_GTFS/pt_vtypes.xml"
    local gtfs_rou="$OUT_GTFS/gtfs_publictransport.rou.xml"
    local gtfs_add="$OUT_GTFS/gtfs_publictransport.add.xml"
    if [[ -f "$vtypes" && -f "$gtfs_rou" && -f "$gtfs_add" ]]; then
        log_warn "GTFS outputs already exist"
    else
        log_info "Processing GTFS..."
        ( cd "$OUT_GTFS" && $(get_python_cmd) "$GTFS2PT" -n "$NET_FILE" --gtfs "$GTFS_PATH_ABS" --date "$SIM_DATE" --modes "$TRANSPORT_MODES" \
            --vtype-output "$vtypes" \
            --route-output "$gtfs_rou" \
            --additional-output "$gtfs_add" ) | cat
        [[ -f "$vtypes" && -f "$gtfs_rou" && -f "$gtfs_add" ]] || die "GTFS processing failed"
        log_success "GTFS processed"
    fi
    export GTFS_VTYPES="$vtypes" GTFS_ROU="$gtfs_rou" GTFS_ADD="$gtfs_add"
}

# Simple concurrency limiter
max_jobs_run() {
    local max_jobs="$1"; shift
    while (( $(jobs -pr | wc -l) >= max_jobs )); do
        wait -n || true
    done
    "$@" &
}

run_simulations() {
    log_info "Starting simulations..."
    local base_seed=12345
    local values=()
    for ((v=1000; v<=33000; v+=1000)); do values+=("$v"); done
    for ((v=36000; v<=58000; v+=2000)); do values+=("$v"); done

    local od_var_dir="$OUT_SIM/od_variants"
    local log_dir="$OUT_SIM/logs"
    mkdir -p "$od_var_dir" "$log_dir"

    # Old method baseline: run once for tripinfo-based analysis
    local old_method_dir="$OUT_SIM/old_method"
    mkdir -p "$old_method_dir"
    local old_tripinfo="$old_method_dir/tripinfo.xml"
    if [[ -f "$old_tripinfo" ]] && [[ $(stat -c%s "$old_tripinfo") -gt 1000 ]]; then
        log_warn "Old method baseline tripinfo already exists: $old_tripinfo"
    else
        log_info "Running old method baseline (PT-only) for tripinfo..."
        local old_tmp="$old_tripinfo.tmp"
        rm -f "$old_tmp"
        sumo -n "$NET_FILE" --additional "$GTFS_VTYPES,$GTFS_ADD" --routes "$GTFS_ROU" \
             --begin $SIM_BEGIN --end $SIM_END --seed $base_seed --tripinfo-output "$old_tmp" --ignore-route-errors \
             --log "$log_dir/old_method_baseline.log" | cat
        [[ -f "$old_tmp" ]] && [[ $(stat -c%s "$old_tmp") -gt 1000 ]] || die "Old method tripinfo too small"
        mv -f "$old_tmp" "$old_tripinfo"
        log_success "Old method baseline tripinfo created: $old_tripinfo"
    fi

    log_info "Creating OD variants..."
    local template
    template="$(cat private_traffic.od)"
    for value in "${values[@]}"; do
        echo "${template}" | sed -E "s/\b10000\b/${value}/g" >"${od_var_dir}/private_${value}.od"
    done
    log_success "OD variants ready"

    # Baseline (PT only)
    for ((sim=1; sim<=SIMS_PER_VALUE; sim++)); do
        local seed=$((base_seed + sim))
        local baseline_stop="$OUT_SIM/stop_events_baseline_${sim}.xml"
        if [[ -f "$baseline_stop" ]] && [[ $(stat -c%s "$baseline_stop") -gt 500 ]]; then
            if $(get_python_cmd) - <<PY >/dev/null 2>&1
import sys,xml.etree.ElementTree as ET
ET.parse("$baseline_stop")
PY
            then
                log_warn "Baseline exists and looks valid, skipping: $baseline_stop"
                continue
            fi
        fi
        run_baseline() {
            local seed="$1" sim="$2"
            local stop_tmp="$OUT_SIM/stop_events_baseline_${sim}.xml.tmp"
            rm -f "$stop_tmp"
            log_info "[BASELINE] sim=${sim} seed=${seed}"
            sumo -n "$NET_FILE" --additional "$GTFS_VTYPES,$GTFS_ADD" --routes "$GTFS_ROU" \
                 --begin $SIM_BEGIN --end $BASELINE_END --seed "$seed" --stop-output "$stop_tmp" --ignore-route-errors \
                 --log "$log_dir/baseline_${sim}.log" | cat
            [[ -f "$stop_tmp" ]] || die "baseline stop missing"
            mv -f "$stop_tmp" "$OUT_SIM/stop_events_baseline_${sim}.xml"
            log_success "Baseline done: sim=${sim}"
        }
        max_jobs_run "$MAX_JOBS" run_baseline "$seed" "$sim"
    done

    wait || true

    # Mixed sims (PT + private)
    for value in "${values[@]}"; do
        for ((sim=1; sim<=SIMS_PER_VALUE; sim++)); do
            local seed=$((base_seed + sim + value))
            local stop_file="$OUT_SIM/stop_events_${value}_${sim}.xml"
            local sim_file="$OUT_SIM/4_${value}_${sim}_${CITY_SAFE}_sim_output.xml"
            if [[ -f "$stop_file" && -f "$sim_file" ]] && [[ $(stat -c%s "$sim_file") -gt 1000 ]]; then
                if $(get_python_cmd) - <<PY >/dev/null 2>&1
import xml.etree.ElementTree as ET
ET.parse("$sim_file"); ET.parse("$stop_file")
PY
                then
                    log_warn "Outputs exist, skipping: value=${value} sim=${sim}"
                    continue
                fi
            fi
            run_mixed() {
                local value="$1" sim="$2" seed="$3"
                local od_file="$od_var_dir/private_${value}.od"
                local trip="$OUT_SIM/4_${value}_${sim}_private_for.trips.xml"
                local route="$OUT_SIM/4_${value}_${sim}_private.rou.xml"
                local trip_tmp="${trip}.tmp" route_tmp="${route}.tmp"
                local stop_tmp="$OUT_SIM/stop_events_${value}_${sim}.xml.tmp"
                local sim_tmp="$OUT_SIM/4_${value}_${sim}_${CITY_SAFE}_sim_output.xml.tmp"
                rm -f "$trip_tmp" "$route_tmp" "$stop_tmp" "$sim_tmp"
                log_info "[SIM] value=${value} sim=${sim} seed=${seed}"
                od2trips --taz-files "$ZONES_TAZ" --od-matrix-files "$od_file" --seed "$seed" -o "$trip_tmp" 2>&1 | tee -a "$log_dir/od2trips_${value}_${sim}.log" | cat
                [[ -f "$trip_tmp" ]] && [[ $(stat -c%s "$trip_tmp") -gt 500 ]] || die "trip too small"
                mv -f "$trip_tmp" "$trip"
                duarouter -n "$NET_FILE" --route-files "$trip" --seed "$seed" -o "$route_tmp" --ignore-errors --repair 2>&1 | tee -a "$log_dir/duarouter_${value}_${sim}.log" | cat
                [[ -f "$route_tmp" ]] && [[ $(stat -c%s "$route_tmp") -gt 500 ]] || die "route too small"
                mv -f "$route_tmp" "$route"
                sumo -n "$NET_FILE" --additional "$GTFS_VTYPES,$GTFS_ADD" --routes "$GTFS_ROU,$route" \
                     --begin $SIM_BEGIN --end $SIM_END --seed "$seed" --tripinfo-output "$sim_tmp" --tripinfo-output.write-unfinished true \
                     --stop-output "$stop_tmp" --ignore-route-errors --log "$log_dir/sumo_${value}_${sim}.log" | cat
                [[ -f "$sim_tmp" ]] && [[ $(stat -c%s "$sim_tmp") -gt 1000 ]] || die "sim output too small"
                mv -f "$sim_tmp" "$sim_file"
                [[ -f "$stop_tmp" ]] || die "stop output missing"
                mv -f "$stop_tmp" "$stop_file"
                log_success "Completed: value=${value} sim=${sim}"
            }
            max_jobs_run "$MAX_JOBS" run_mixed "$value" "$sim" "$seed"
        done
    done

    wait || true
    log_success "All simulations completed"

    # Analysis
    local out_analysis="$OUT_ROOT/analysis"
    mkdir -p "$out_analysis"
    local excel="$out_analysis/pt_delay.xlsx"
    log_info "Exporting Excel: $excel"
    if ! $(get_python_cmd) export_pt_delay_excel.py --simdir "$OUT_SIM" --sims "$SIMS_PER_VALUE" --out "$excel"; then
        log_warn "Export failed"
    else
        log_success "Excel generated"
        if [[ -f plot_pt_delay.py ]]; then
            log_info "Generating plots..."
            $(get_python_cmd) plot_pt_delay.py --excel "$excel" \
                --out "$out_analysis/pt_delay.png" \
                --out-heat "$out_analysis/pt_delay_heat.png" \
                --out-fan "$out_analysis/pt_delay_fan.png" \
                --out-box "$out_analysis/pt_delay_box.png" \
                --out-range "$out_analysis/pt_delay_range.png" || log_warn "Plotting failed"
        fi
    fi

    # Old method analysis (tripinfo-based)
    local excel_tripinfo="$out_analysis/pt_delay_tripinfo.xlsx"
    log_info "Exporting tripinfo-based delay analysis to: $excel_tripinfo"
    if ! $(get_python_cmd) "$BASE_DIR/get_table_of_old_methode.py" \
        --baseline "$old_method_dir/tripinfo.xml" \
        --simdir "$OUT_SIM" \
        --sims "$SIMS_PER_VALUE" \
        --out "$excel_tripinfo"; then
        log_warn "Tripinfo export failed"
    else
        log_success "Tripinfo-based Excel generated: $excel_tripinfo"
    fi
}

main() {
    echo "========================================="
    echo "    Automated SUMO Workflow (Linux)       "
    echo "========================================="
    echo

    local pycmd
    pycmd=$(get_python_cmd)
    ensure_python_packages "$pycmd"
    resolve_sumo
    load_config
    create_config_files
    make_dirs
    download_osm
    build_network
    auto_center
    create_zones_and_taz
    process_gtfs
    run_simulations

    log_success "Workflow completed! Outputs in ./outputs"
}

main "$@"


