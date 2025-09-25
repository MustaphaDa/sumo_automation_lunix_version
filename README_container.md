## Containerized SUMO workflow (Linux/HPC)

This project provides a Linux bash orchestrator (`run_sumo.sh`) and a Docker image to run the full SUMO + GTFS workflow end-to-end.

### Inputs
- `config.json` (optional) with keys: `cityName`, `gtfsPath`, `simDate`, `transportModes`, `maxJobs`, `centerX`, `centerY`, `simsPerValue`.
- Or set environment variables: `CITY_NAME`, `GTFS_PATH`, `SIM_DATE` (YYYYMMDD). Others optional: `TRANSPORT_MODES`, `MAX_JOBS`, `CENTER_X`, `CENTER_Y`, `SIMS_PER_VALUE`.

### Build
```bash
docker build -t sumo-automation:latest .
```

### Run (Docker)
Assuming the GTFS zip is on the host at `/abs/path/to/gtfs.zip`:
```bash
docker run --rm -it \
  -e CITY_NAME="Budapest" \
  -e GTFS_PATH="/data/gtfs.zip" \
  -e SIM_DATE=20231229 \
  -e TRANSPORT_MODES=bus \
  -e MAX_JOBS=$(nproc) \
  -e SIMS_PER_VALUE=10 \
  -v /abs/path/to/gtfs.zip:/data/gtfs.zip:ro \
  -v $(pwd)/outputs:/app/outputs \
  sumo-automation:latest
```

If you use `config.json`, mount it into `/app/config.json`:
```bash
docker run --rm -it \
  -v $(pwd)/config.json:/app/config.json:ro \
  -v /abs/path/to/gtfs.zip:/data/gtfs.zip:ro \
  -e GTFS_PATH=/data/gtfs.zip \
  sumo-automation:latest
```

Outputs will be in the `outputs/` directory (mounted from the host).

### Health check (override entrypoint)
To quickly verify tools inside the image without starting the workflow:
```bash
docker run --rm -it --entrypoint bash sumo-automation:latest -lc \
  "sumo --version && netconvert --version && python3 -c 'import numpy,pandas,shapely,rtree,pyproj; print(\"python-deps-ok\")'"
```

### OSM download fallback
Overpass may time out. You can provide a pre-downloaded OSM file and skip the download step:
```bash
docker run --rm -it \
  -e CITY_NAME="Grenoble" \
  -e GTFS_PATH="/data/gtfs.zip" \
  -e SIM_DATE=20221110 \
  -e OSM_XML_PATH="/data/grenoble.osm" \
  -v /abs/path/to/gtfs_Grenoble.zip:/data/gtfs.zip:ro \
  -v /abs/path/to/grenoble.osm:/data/grenoble.osm:ro \
  -v $(pwd)/outputs:/app/outputs \
  sumo-automation:latest
```


### Apptainer/Singularity (HPC)
Most HPCs prefer Apptainer (formerly Singularity). You can convert the Docker image:

1) On a machine with Docker and Apptainer:
```bash
docker build -t sumo-automation:latest .
apptainer build sumo-automation.sif docker-daemon://sumo-automation:latest
```

2) Copy `sumo-automation.sif` to the HPC and run:
```bash
apptainer run \
  --env CITY_NAME="Budapest" \
  --env GTFS_PATH="/data/gtfs.zip" \
  --env SIM_DATE=20231229 \
  --env TRANSPORT_MODES=bus \
  --env MAX_JOBS=8 \
  --env SIMS_PER_VALUE=10 \
  --bind /path/on/hpc/gtfs.zip:/data/gtfs.zip:ro \
  --bind $PWD/outputs:/app/outputs \
  sumo-automation.sif
```

### Notes
- The container includes SUMO CLI tools and Python libs (`requests`, `numpy`, `pandas`, `lxml`, `shapely`, `rtree`, `pyproj`, `openpyxl`).
- `SUMO_HOME` is set to `/usr/share/sumo` in the image.
- Network center is auto-detected from `get_center.py`; you can override with `CENTER_X` and `CENTER_Y`.
- The orchestrator will skip steps if valid outputs already exist, enabling resumable runs.


