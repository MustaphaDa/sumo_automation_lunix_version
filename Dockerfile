FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git \
        python3 python3-pip python3-venv python3-distutils \
        build-essential pkg-config \
        libproj-dev proj-bin \
        libgdal-dev gdal-bin \
        libgeos-dev \
        libspatialindex-dev \
        libxml2 libxslt1.1 \
        sumo sumo-tools sumo-doc \
    && rm -rf /var/lib/apt/lists/*

# SUMO_HOME provided by Debian/Ubuntu packages
ENV SUMO_HOME=/usr/share/sumo

WORKDIR /app

# Copy project files
COPY . /app

# Install Python deps early to leverage layer cache
# Pin pandas<2 for SUMO 1.12 compatibility (uses DataFrame.append)
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir \
      numpy==1.24.4 \
      pandas==1.5.3 \
      lxml shapely rtree pyproj openpyxl requests

# Ensure scripts are executable
RUN chmod +x /app/run_sumo.sh

# Default envs (can be overridden at run-time)
ENV TRANSPORT_MODES=bus \
    SIMS_PER_VALUE=10 \
    MAX_JOBS=4

ENTRYPOINT ["/app/run_sumo.sh"]


