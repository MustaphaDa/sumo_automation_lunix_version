#!/usr/bin/env python3
import xml.etree.ElementTree as ET
import os
import sys

# Input zone files and output
zone_files = ["zone1.xml", "zone2.xml", "zone3.xml"]
output_taz_file = "zones.taz.xml"

# Verify all zone files exist
missing = [zf for zf in zone_files if not os.path.exists(zf)]
if missing:
    print(f"Missing zone files: {', '.join(missing)}")
    sys.exit(1)

# Extract edges from each zone file with robust parsing
zones = {}
total_edges = 0
for zone_file in zone_files:
    zone_id = os.path.splitext(zone_file)[0]
    zones[zone_id] = []
    try:
        tree = ET.parse(zone_file)
        root = tree.getroot()
    except ET.ParseError as e:
        print(f"Failed to parse '{zone_file}': {e}")
        sys.exit(1)
    except OSError as e:
        print(f"Failed to read '{zone_file}': {e}")
        sys.exit(1)

    for edge in root.findall(".//edge"):
        edge_id = edge.get("id")
        if edge_id:
            zones[zone_id].append(edge_id)
            total_edges += 1

if total_edges == 0:
    print("No edges found in any zone files; refusing to write empty TAZ.")
    sys.exit(1)

# Generate TAZ XML file
with open(output_taz_file, "w", encoding="utf-8") as f:
    f.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
    f.write("<tazs>\n")
    for zone, edges in zones.items():
        edge_string = " ".join(edges)
        f.write(f"    <taz id=\"{zone}\" edges=\"{edge_string}\"/>\n")
    f.write("</tazs>\n")

print(f"Generated TAZ file: {output_taz_file}")


