#!/usr/bin/env python3
"""
Build an Excel workbook with one sheet per private-traffic value showing
public transport schedule delay deltas (mixed vs baseline) per stop occurrence.

Inputs:
- --simdir: folder containing stop_events_baseline_*.xml and stop_events_<value>_<sim>.xml
- --sims: number of simulations per value
- --out: output xlsx path

Notes:
- We infer values from files found under simdir (stop_events_<value>_<sim>.xml)
- Requires: pandas, openpyxl
"""

import argparse
import os
import re
from collections import defaultdict
from typing import Dict, List
import pandas as pd

# Prefer lxml (with recover) when available
try:
    import lxml.etree as ET  # type: ignore
    _HAS_LXML = True
except Exception:  # pragma: no cover
    import xml.etree.ElementTree as ET  # type: ignore
    _HAS_LXML = False

STOP_MIXED_RE = re.compile(r"stop_events_(\d+)_(\d+)\.xml$")


def _parse_root(path: str):
    if _HAS_LXML:
        parser = ET.XMLParser(recover=True)
        return ET.parse(path, parser=parser).getroot()
    else:
        return ET.parse(path).getroot()


def parse_stop_delays(path: str) -> Dict[str, List[float]]:
    delays: Dict[str, List[float]] = defaultdict(list)
    try:
        root = _parse_root(path)
    except Exception as e:  # malformed or incomplete XML
        print(f"Warning: skipping malformed XML: {path} ({e})")
        return delays
    for el in root.findall(".//stopinfo"):
        stop_id = el.attrib.get("busStop") or el.attrib.get("stop")
        if not stop_id:
            continue
        try:
            delay = float(el.attrib.get("delay", "0"))
        except ValueError:
            continue
        delays[stop_id].append(delay)
    for k in delays:
        delays[k].sort()
    return delays


def _generate_values() -> List[int]:
    values: List[int] = []
    for v in range(1000, 33000 + 1, 1000):
        values.append(v)
    for v in range(36000, 58000 + 1, 2000):
        values.append(v)
    return values


def _find_baseline_path(simdir: str, sim_index: int) -> str:
    # Prefer explicit baseline naming, fallback to value=0 naming convention
    candidates = [
        os.path.join(simdir, f"stop_events_baseline_{sim_index}.xml"),
        os.path.join(simdir, f"stop_events_0_{sim_index}.xml"),
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    return ""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--simdir", required=True)
    ap.add_argument("--sims", type=int, required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    simdir = os.path.abspath(args.simdir)
    # Load baselines per sim index with fallback
    baselines: Dict[int, Dict[str, List[float]]] = {}
    for sim in range(1, args.sims + 1):
        p = _find_baseline_path(simdir, sim)
        if p:
            b = parse_stop_delays(p)
            if b:
                baselines[sim] = b
            else:
                print(f"Warning: no usable baseline delays in {p}")
        else:
            print(f"Warning: missing baseline file for sim {sim} (looked for stop_events_baseline_{sim}.xml and stop_events_0_{sim}.xml)")

    # Discover mixed files and group by value
    value_to_simpaths: Dict[int, Dict[int, str]] = defaultdict(dict)
    for name in os.listdir(simdir):
        m = STOP_MIXED_RE.match(name)
        if not m:
            continue
        value = int(m.group(1))
        sim = int(m.group(2))
        value_to_simpaths[value][sim] = os.path.join(simdir, name)

    # Fixed value set as requested
    values = _generate_values()

    summaries = []
    with pd.ExcelWriter(args.out, engine="openpyxl") as writer:
        for value in values:
            rows = []
            for sim in range(1, args.sims + 1):
                path = value_to_simpaths.get(value, {}).get(sim)
                mixed = parse_stop_delays(path)
                base = baselines.get(sim)
                if not base:
                    continue
                # align by stop id and occurrence order
                for stop_id, base_list in base.items():
                    mix_list = mixed.get(stop_id)
                    if not mix_list:
                        continue
                    n = min(len(base_list), len(mix_list))
                    for idx in range(n):
                        rows.append({
                            "value": value,
                            "sim": sim,
                            "stop": stop_id,
                            "occurrence": idx + 1,
                            "delay_baseline_s": base_list[idx],
                            "delay_mixed_s": mix_list[idx],
                            "delay_delta_s": mix_list[idx] - base_list[idx],
                        })
            # Always create the sheet (even if empty) to cover all requested values
            df = pd.DataFrame(rows, columns=[
                "value",
                "sim",
                "stop",
                "occurrence",
                "delay_baseline_s",
                "delay_mixed_s",
                "delay_delta_s",
            ])
            if len(df) > 0:
                # Per-stop average delta across all sims/occurrences for this value
                stop_means = (
                    df.groupby("stop", as_index=False)["delay_delta_s"].mean()
                      .rename(columns={"delay_delta_s": "stop_avg_delta_s"})
                )
                df = df.merge(stop_means, on="stop", how="left")
            df.to_excel(writer, sheet_name=str(value), index=False)
            # summary per value across sims
            if len(df) > 0:
                s = df["delay_delta_s"].describe(percentiles=[0.1, 0.5, 0.9]).to_dict()
                summaries.append({
                    "value": value,
                    "count": int(s.get("count", 0)),
                    "mean_delta_s": float(s.get("mean", 0.0)),
                    "median_delta_s": float(s.get("50%", 0.0)),
                    "p10_delta_s": float(s.get("10%", 0.0)),
                    "p90_delta_s": float(s.get("90%", 0.0)),
                    "min_delta_s": float(s.get("min", 0.0)),
                    "max_delta_s": float(s.get("max", 0.0)),
                })
            else:
                summaries.append({
                    "value": value,
                    "count": 0,
                    "mean_delta_s": 0.0,
                    "median_delta_s": 0.0,
                    "p10_delta_s": 0.0,
                    "p90_delta_s": 0.0,
                    "min_delta_s": 0.0,
                    "max_delta_s": 0.0,
                })

        if summaries:
            sdf = pd.DataFrame(summaries).sort_values("value")
            sdf.to_excel(writer, sheet_name="summary", index=False)

    print(f"Excel written: {args.out}")


if __name__ == "__main__":
    main()


