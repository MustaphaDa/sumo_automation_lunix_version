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

### Windows quick steps (PowerShell)
- Prereqs: Install Docker Desktop, enable WSL2 backend (Settings → General), ensure Linux engine.
- Build image:
```powershell
docker build -t sumo-automation:latest .
```
- Health check (simple):
```powershell
docker run --rm -it --entrypoint python3 sumo-automation:latest -c "import numpy,pandas,shapely,rtree,pyproj; print('ok')"
```
- Local smoke run with your `config.json` and `gtfs.zip`:
```powershell
docker run --rm -it `
  -v "${PWD}\config.json:/app/config.json:ro" `
  -v "${PWD}\gtfs_Grenoble.zip:/data/gtfs.zip:ro" `
  -v "${PWD}\outputs:/app/outputs" `
  -e GTFS_PATH="/data/gtfs.zip" `
  -e MAX_JOBS=2 `
  -e SIMS_PER_VALUE=1 `
  sumo-automation:latest
```
- Send to HPC (choose ONE approach below, details in sections further down):
  - Push to a registry (recommended), then run via Apptainer on HPC using `docker://...` (see “Ways to get the image onto the HPC”, Option 1).
  - Or build a `.sif` on Linux/WSL and `scp` it to HPC (see Option 2).
  - Or pull `.sif` directly on HPC if allowed (see Option 3).
  - If compute nodes have no internet, use `OSM_XML_PATH` on HPC (see “OSM download fallback”).

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

### Ways to get the image onto the HPC

- Option 1: Push Docker image to a registry and run directly (HPC converts on-the-fly)
```bash
docker tag sumo-automation:latest yourrepo/sumo-automation:latest
docker login
docker push yourrepo/sumo-automation:latest

# On HPC (Apptainer pulls and converts transparently):
apptainer run \
  --env GTFS_PATH=/data/gtfs.zip \
  --env MAX_JOBS=16 \
  --env SIMS_PER_VALUE=10 \
  --bind /path/config.json:/app/config.json:ro \
  --bind /path/gtfs.zip:/data/gtfs.zip:ro \
  --bind /scratch/$USER/outputs:/app/outputs \
  docker://yourrepo/sumo-automation:latest
```

- Option 2: Build `.sif` on Linux/WSL and copy via scp
```bash
# On Linux/WSL:
docker build -t sumo-automation:latest .
sudo apt update && sudo apt install -y apptainer   # if not present
apptainer build sumo-automation.sif docker-daemon://sumo-automation:latest

# Copy to HPC:
scp sumo-automation.sif your_user@login.university.edu:~/apps/
scp config.json your_user@login.university.edu:~/
scp gtfs_Grenoble.zip your_user@login.university.edu:~/data/

# On HPC:
module load apptainer
apptainer run \
  --env GTFS_PATH=/data/gtfs.zip \
  --bind ~/config.json:/app/config.json:ro \
  --bind ~/data/gtfs_Grenoble.zip:/data/gtfs.zip:ro \
  --bind /scratch/$USER/outputs:/app/outputs \
  ~/apps/sumo-automation.sif
```

- Option 3: Pull and save `.sif` directly on the HPC (if internet allowed)
```bash
module load apptainer
apptainer pull sumo-automation.sif docker://yourrepo/sumo-automation:latest
apptainer run \
  --env GTFS_PATH=/data/gtfs.zip \
  --bind /path/config.json:/app/config.json:ro \
  --bind /path/gtfs.zip:/data/gtfs.zip:ro \
  --bind /scratch/$USER/outputs:/app/outputs \
  sumo-automation.sif
```

### HPC step-by-step (SSH + scp quick guide)

#### What to get from the university
- HPC username and login instructions (SSH, VPN/2FA if required)
- Apptainer/Singularity availability (module name or system install)
- Scheduler details (e.g., Slurm partitions, CPU/RAM/walltime limits)
- Scratch path for outputs and disk quota
- Internet policy on compute nodes (needed for auto OSM; otherwise use `OSM_XML_PATH`)

#### Build the container and create a .sif (on Linux/WSL)
```bash
docker build -t sumo-automation:latest .
apptainer build sumo-automation.sif docker-daemon://sumo-automation:latest
```

#### Copy files to the HPC (from your computer)
```bash
scp sumo-automation.sif your_user@.......
scp config.json your_user@.......
scp gtfs.zip your_user@.....
```

#### Log in and verify Apptainer
```bash
ssh your_user@......
module load apptainer   # or: singularity
apptainer --version
apptainer exec ~/apps/sumo-automation.sif bash -lc "sumo --version && python3 -c 'import pandas; print(\"ok\")'"
```

#### Run a job interactively (simple test)
```bash
mkdir -p /scratch/$USER/outputs
apptainer run \
  --env GTFS_PATH=/data/gtfs.zip \
  --env MAX_JOBS=8 \
  --env SIMS_PER_VALUE=10 \
  --bind ~/config.json:/app/config.json:ro \
  --bind ~/data/gtfs_Grenoble.zip:/data/gtfs.zip:ro \
  --bind /scratch/$USER/outputs:/app/outputs \
  ~/apps/sumo-automation.sif
```

#### If compute nodes have no internet (provide OSM)
```bash
apptainer run \
  --env GTFS_PATH=/data/gtfs.zip \
  --env OSM_XML_PATH=/data/grenoble.osm \
  --bind ~/config.json:/app/config.json:ro \
  --bind ~/data/gtfs_Grenoble.zip:/data/gtfs.zip:ro \
  --bind ~/data/grenoble.osm:/data/grenoble.osm:ro \
  --bind /scratch/$USER/outputs:/app/outputs \
  ~/apps/sumo-automation.sif
```

#### Slurm batch example
```bash
#!/bin/bash
#SBATCH --job-name=sumo-grenoble
#SBATCH --cpus-per-task=16
#SBATCH --mem=32G
#SBATCH --time=12:00:00
#SBATCH --output=logs/%x-%j.out
module load apptainer
OUT=/scratch/$USER/sumo-outputs/$SLURM_JOB_ID
mkdir -p "$OUT"
apptainer run \
  --env GTFS_PATH=/data/gtfs.zip \
  --env MAX_JOBS=$SLURM_CPUS_PER_TASK \
  --env SIMS_PER_VALUE=10 \
  --bind /home/$USER/config.json:/app/config.json:ro \
  --bind /home/$USER/data/gtfs_Grenoble.zip:/data/gtfs.zip:ro \
  --bind $OUT:/app/outputs \
  /home/$USER/apps/sumo-automation.sif
```

#### Copy results back to your computer
```bash
scp your_user@.........:/scratch/$USER/outputs/analysis/pt_delay.xlsx .
```

### Notes
- The container includes SUMO CLI tools and Python libs (`requests`, `numpy`, `pandas`, `lxml`, `shapely`, `rtree`, `pyproj`, `openpyxl`).
- `SUMO_HOME` is set to `/usr/share/sumo` in the image.
- Network center is auto-detected from `get_center.py`; you can override with `CENTER_X` and `CENTER_Y`.
- The orchestrator will skip steps if valid outputs already exist, enabling resumable runs.


