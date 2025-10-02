import argparse
import os
import re
from collections import defaultdict
from typing import Dict, List, Tuple

import pandas as pd

try:
    import lxml.etree as ET  # type: ignore
    _HAS_LXML = True
except Exception:  # pragma: no cover
    import xml.etree.ElementTree as ET  # type: ignore
    _HAS_LXML = False


TRIPINFO_RE = re.compile(r"^4_(\d+)_(\d+)_.*_sim_output\.xml$")


def _parse_root(path: str):
    if _HAS_LXML:
        parser = ET.XMLParser(recover=True)
        return ET.parse(path, parser=parser).getroot()
    else:
        return ET.parse(path).getroot()


def extract_pt_durations(path: str) -> Dict[str, float]:
    """Return per-vehicle duration for PT bus-like vehicles from a tripinfo.xml.

    - Uses 'duration' attribute when present.
    - Falls back to (arrival - depart) if needed.
    - Filters to public transport vehicles:
      - Prefer vType containing 'bus' (case-insensitive)
      - If vType is absent, keep vehicles whose id is not purely digits
    """
    durations: Dict[str, float] = {}
    try:
        root = _parse_root(path)
    except Exception as e:
        print(f"Warning: skipping malformed XML: {path} ({e})")
        return durations

    for el in root.findall(".//tripinfo"):
        vid = el.attrib.get("id") or el.attrib.get("tripid") or ""
        if not vid:
            continue
        vtype = el.attrib.get("vType") or el.attrib.get("vtype")
        is_bus = (vtype is not None and ("bus" in vtype.lower())) or (vtype is None and not vid.isdigit())
        if not is_bus:
            continue
        dur_str = el.attrib.get("duration")
        dur: float
        try:
            if dur_str is not None:
                dur = float(dur_str)
            else:
                arr = float(el.attrib.get("arrival", "nan"))
                dep = float(el.attrib.get("depart", "nan"))
                dur = arr - dep
        except Exception:
            continue
        if dur <= 0:
            continue
        durations[vid] = dur
    return durations


def discover_value_to_sims(simdir: str) -> Dict[int, List[Tuple[int, str]]]:
    mapping: Dict[int, List[Tuple[int, str]]] = defaultdict(list)
    for name in os.listdir(simdir):
        m = TRIPINFO_RE.match(name)
        if not m:
            continue
        value = int(m.group(1))
        sim = int(m.group(2))
        mapping[value].append((sim, os.path.join(simdir, name)))
    for value in list(mapping.keys()):
        mapping[value].sort(key=lambda t: t[0])
    return mapping


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", default=os.path.join("old_method", "tripinfo.xml"), help="Baseline PT-only tripinfo.xml")
    ap.add_argument("--simdir", default=os.path.join("outputs", "sim"))
    ap.add_argument("--sims", type=int, default=10, help="Number of sims per value (used for reporting)")
    ap.add_argument("--out", default=os.path.join("outputs", "analysis", "pt_delay_tripinfo.xlsx"))
    args = ap.parse_args()

    baseline_path = os.path.abspath(args.baseline)
    simdir = os.path.abspath(args.simdir)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    baseline = extract_pt_durations(baseline_path)
    if not baseline:
        raise SystemExit(f"No baseline PT durations parsed from: {baseline_path}")

    value_to_sims = discover_value_to_sims(simdir)
    all_values = sorted(value_to_sims.keys())

    summaries = []
    with pd.ExcelWriter(args.out, engine="openpyxl") as writer:
        for value in all_values:
            per_sim_files = value_to_sims[value]
            # Aggregate durations per vehicle across sims (average)
            vessel_to_sum: Dict[str, float] = defaultdict(float)
            vessel_to_count: Dict[str, int] = defaultdict(int)
            for _, path in per_sim_files:
                durs = extract_pt_durations(path)
                for vid, dur in durs.items():
                    vessel_to_sum[vid] += dur
                    vessel_to_count[vid] += 1

            rows = []
            delays: List[float] = []
            for vid, base_dur in baseline.items():
                if vid in vessel_to_sum:
                    avg_dur = vessel_to_sum[vid] / max(1, vessel_to_count[vid])
                    delay = avg_dur - base_dur
                    delays.append(delay)
                    rows.append({
                        "vehicle_id": vid,
                        "baseline_duration_s": base_dur,
                        "avg_duration_s": avg_dur,
                        "delay_s": delay,
                        "sims_count": vessel_to_count[vid],
                    })
            df = pd.DataFrame(rows, columns=[
                "vehicle_id",
                "baseline_duration_s",
                "avg_duration_s",
                "delay_s",
                "sims_count",
            ])
            df.to_excel(writer, sheet_name=str(value), index=False)

            if len(df) > 0:
                s = df["delay_s"].describe(percentiles=[0.1, 0.5, 0.9]).to_dict()
                summaries.append({
                    "value": value,
                    "count": int(s.get("count", 0)),
                    "mean_delay_s": float(s.get("mean", 0.0)),
                    "median_delay_s": float(s.get("50%", 0.0)),
                    "p10_delay_s": float(s.get("10%", 0.0)),
                    "p90_delay_s": float(s.get("90%", 0.0)),
                    "min_delay_s": float(s.get("min", 0.0)),
                    "max_delay_s": float(s.get("max", 0.0)),
                })
            else:
                summaries.append({
                    "value": value,
                    "count": 0,
                    "mean_delay_s": 0.0,
                    "median_delay_s": 0.0,
                    "p10_delay_s": 0.0,
                    "p90_delay_s": 0.0,
                    "min_delay_s": 0.0,
                    "max_delay_s": 0.0,
                })

        if summaries:
            sdf = pd.DataFrame(summaries).sort_values("value")
            sdf.to_excel(writer, sheet_name="summary", index=False)

    print(f"Excel written: {args.out}")


if __name__ == "__main__":
    main()