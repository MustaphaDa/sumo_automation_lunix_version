
# SUMO + GTFS Containerized Workflow

Automated end-to-end workflow for running SUMO traffic simulations with GTFS public transport data on Docker/HPC.

---

## What This Does

This project automates:
1. Download OSM road network for a city
2. Convert OSM to SUMO network with public transport infrastructure
3. Import GTFS schedules and match to the network
4. Create traffic zones (TAZ) for origin-destination matrices
5. Run baseline (PT-only) and mixed (PT + private traffic) simulations
6. Export delay analysis to Excel (two methods: stop-events and tripinfo)
7. Generate plots (optional)

---

## Project Files

### `Dockerfile`
Builds the container image with:
- **SUMO** (1.12): simulator + tools (`netconvert`, `od2trips`, `duarouter`, `gtfs2pt.py`)
- **Python 3** + packages: `numpy`, `pandas`, `lxml`, `shapely`, `rtree`, `pyproj`, `openpyxl`, `requests`
- **GIS libraries**: PROJ, GDAL, GEOS, spatialindex
- All project scripts

### `run_sumo.sh`
Main orchestrator that:
1. Loads configuration from `config.json` or environment variables
2. Downloads OSM map via Overpass API (or uses pre-downloaded file)
3. Converts OSM to SUMO network with `netconvert`
4. Auto-detects network center coordinates
5. Creates 3 traffic zones and TAZ file
6. Processes GTFS with `gtfs2pt.py`
7. Runs simulations in parallel:
   - Old method baseline (PT-only, tripinfo output)
   - Baseline simulations (PT-only, stop-event output)
   - Mixed simulations (PT + private traffic) for multiple OD values
8. Exports delay analysis to Excel:
   - `pt_delay.xlsx` (stop-event based)
   - `pt_delay_tripinfo.xlsx` (tripinfo based)
9. Generates plots (if `plot_pt_delay.py` is present)

### Python Helper Scripts

- **`get_map.py`**: Downloads OSM data from Overpass API with retry logic and multiple mirrors
- **`get_center.py`**: Calculates network bounding box center from SUMO `.net.xml` file
- **`get_zones.py`**: Creates 3 concentric zone polygons (inner, middle, outer) based on distance from center
- **`get_taz.py`**: Generates Traffic Analysis Zones (TAZ) XML file from zone polygons
- **`export_pt_delay_excel.py`**: Analyzes stop-event XMLs and exports PT delay statistics to Excel
- **`get_table_of_old_methode.py`**: Analyzes tripinfo XMLs and exports PT vehicle duration/delay to Excel
- **`plot_pt_delay.py`** (optional): Generates delay visualization plots from Excel data

---

## Configuration (`config.json`)

All parameters are optional; defaults are provided if omitted.

```json
{
    "cityName": "Grenoble",
    "gtfsPath": "gtfs_Grenoble.zip",
    "simDate": "20221110",
    "transportModes": "bus",
    "maxJobs": 7,
    "simsPerValue": 10,
    "simBegin": 21600,
    "simEnd": 36000,
    "baselineEnd": 39600,
    "centerX": 5023.28,
    "centerY": 5852.20
}
```

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `cityName` | string | **Yes** | - | City name for OSM download (e.g., "Budapest", "Grenoble") |
| `gtfsPath` | string | **Yes** | - | Path to GTFS zip file (inside container or bound from host) |
| `simDate` | string | **Yes** | - | Simulation date in `YYYYMMDD` format (e.g., "20231229") |
| `transportModes` | string | No | `"bus"` | GTFS transport modes to import (e.g., "bus", "tram,bus") |
| `maxJobs` | integer | No | CPU count | Number of parallel simulation jobs |
| `simsPerValue` | integer | No | `10` | Number of simulation runs per OD value (for statistical robustness) |
| `simBegin` | integer | No | `21600` | Simulation start time in seconds since midnight (21600 = 6:00 AM) |
| `simEnd` | integer | No | `36000` | Simulation end time for mixed traffic in seconds (36000 = 10:00 AM) |
| `baselineEnd` | integer | No | `39600` | Simulation end time for baseline (PT-only) in seconds (39600 = 11:00 AM) |
| `centerX` | float | No | Auto-detect | Network center X coordinate (SUMO projection) |
| `centerY` | float | No | Auto-detect | Network center Y coordinate (SUMO projection) |

**Time conversion**: Specify times in seconds since midnight. Script auto-converts to `HH.MM` format for OD matrix.
- Example: 6:00 AM = 6 × 3600 = 21600 seconds
- Example: 10:30 AM = (10 × 3600) + (30 × 60) = 37800 seconds

---

## Quick Start

### Docker (Local Testing)

1. **Build the image**:
```bash
docker build -t sumo-automation:latest .
```

2. **Run with config.json**:
```bash
docker run --rm -it \
  -v $(pwd)/config.json:/app/config.json:ro \
  -v $(pwd)/gtfs_Grenoble.zip:/data/gtfs.zip:ro \
  -v $(pwd)/outputs:/app/outputs \
  -e GTFS_PATH="/data/gtfs.zip" \
  sumo-automation:latest
```

3. **Or use environment variables** (no config.json):
```bash
docker run --rm -it \
  -e CITY_NAME="Budapest" \
  -e GTFS_PATH="/data/gtfs.zip" \
  -e SIM_DATE=20231229 \
  -v $(pwd)/gtfs.zip:/data/gtfs.zip:ro \
  -v $(pwd)/outputs:/app/outputs \
  sumo-automation:latest
```

### HPC (Apptainer/Singularity)

#### Option 1: Push to registry, run directly on HPC
```bash
# On your machine:
docker tag sumo-automation:latest yourrepo/sumo-automation:latest
docker push yourrepo/sumo-automation:latest

# On HPC:
module load apptainer
apptainer run \
  --env GTFS_PATH=/data/gtfs.zip \
  --bind ~/config.json:/app/config.json:ro \
  --bind ~/gtfs.zip:/data/gtfs.zip:ro \
  --bind /scratch/$USER/outputs:/app/outputs \
  docker://yourrepo/sumo-automation:latest
```

#### Option 2: Build .sif locally, copy to HPC
```bash
# On Linux/WSL:
docker build -t sumo-automation:latest .
apptainer build sumo-automation.sif docker-daemon://sumo-automation:latest
scp sumo-automation.sif user@hpc:~/apps/
scp config.json user@hpc:~/
scp gtfs.zip user@hpc:~/data/

# On HPC:
module load apptainer
apptainer run \
  --env GTFS_PATH=/data/gtfs.zip \
  --bind ~/config.json:/app/config.json:ro \
  --bind ~/data/gtfs.zip:/data/gtfs.zip:ro \
  --bind /scratch/$USER/outputs:/app/outputs \
  ~/apps/sumo-automation.sif
```

#### Slurm batch job example
```bash
#!/bin/bash
#SBATCH --job-name=sumo-sim
#SBATCH --cpus-per-task=16
#SBATCH --mem=32G
#SBATCH --time=12:00:00

module load apptainer
OUT=/scratch/$USER/sumo-outputs/$SLURM_JOB_ID
mkdir -p "$OUT"

apptainer run \
  --env GTFS_PATH=/data/gtfs.zip \
  --env MAX_JOBS=$SLURM_CPUS_PER_TASK \
  --bind ~/config.json:/app/config.json:ro \
  --bind ~/data/gtfs.zip:/data/gtfs.zip:ro \
  --bind $OUT:/app/outputs \
  ~/apps/sumo-automation.sif
```

---

## Outputs

All outputs are written to `outputs/` (bound to host or HPC scratch):

```
outputs/
├── osm/              # Downloaded OSM map
├── net/              # SUMO network files
├── zones/            # Zone polygons and TAZ
├── gtfs/             # Processed GTFS (routes, stops, vtypes)
├── sim/              # Simulation outputs
│   ├── old_method/   # Baseline tripinfo.xml
│   ├── logs/         # SUMO logs
│   ├── stop_events_baseline_*.xml
│   ├── stop_events_*_*.xml
│   └── 4_*_*_*_sim_output.xml
└── analysis/         # Final Excel and plots
    ├── pt_delay.xlsx           # Stop-event based analysis
    ├── pt_delay_tripinfo.xlsx  # Tripinfo based analysis
    └── *.png                   # Plots (if generated)
```

---

## Advanced Options

### Provide pre-downloaded OSM (skip Overpass)
If compute nodes have no internet or Overpass times out:
```bash
-e OSM_XML_PATH="/data/city.osm" \
--bind /path/to/city.osm:/data/city.osm:ro
```

### Override time parameters
```bash
-e SIM_BEGIN=25200 \   # 7:00 AM
-e SIM_END=32400 \     # 9:00 AM
-e BASELINE_END=36000  # 10:00 AM
```

### Override center coordinates
```bash
-e CENTER_X=5023.28 \
-e CENTER_Y=5852.20
```

---

## Requirements for HPC

Ask your HPC admins for:
- **Apptainer/Singularity** (module or system install)
- **Slurm** (or other scheduler) access
- **CPU/RAM**: 8–32 cores, 8–32 GB RAM per job
- **Storage**: 20–100 GB scratch space
- **Walltime**: 8–24 hours (depends on city size and `simsPerValue`)
- **Internet** (optional): for auto OSM download; otherwise provide OSM via `OSM_XML_PATH`

---

## Notes

- Container is self-contained: SUMO, Python, and all dependencies are pre-installed
- Workflow is resumable: skips steps if valid outputs already exist
- Times are in seconds since midnight; script auto-converts for OD matrix
- Center coordinates are auto-detected if not provided
- OD values range: 1000–33000 (step 1000), 36000–58000 (step 2000)
- Each OD value runs `simsPerValue` times with different seeds for statistical robustness
