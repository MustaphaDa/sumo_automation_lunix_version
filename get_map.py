#!/usr/bin/env python3
import argparse
import requests

HEADERS = {"User-Agent": "sumo-automation/1.0 (contact: example@example.com)", "Accept-Language": "en"}

def get_bbox(city_name: str):
    url = "https://nominatim.openstreetmap.org/search"
    params = {"q": city_name, "format": "json", "limit": 1}
    r = requests.get(url, params=params, headers=HEADERS, timeout=30)
    r.raise_for_status()
    data = r.json()
    if not data:
        raise SystemExit(f"No results from Nominatim for '{city_name}'")
    bb = data[0]["boundingbox"]  # [south, north, west, east]
    south, north, west, east = map(float, bb)
    # Lightly expand bbox by 10%
    lat_pad = (north - south) * 0.1
    lon_pad = (east - west) * 0.1
    return south - lat_pad, north + lat_pad, west - lon_pad, east + lon_pad

def download_osm_map(city_name: str, outfile: str):
    mirrors = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.openstreetmap.ru/api/interpreter",
        "https://overpass.osm.ch/api/interpreter",
    ]
    south, north, west, east = get_bbox(city_name)
    overpass_query = f"""
    [out:xml][timeout:180];
    (
      node({south},{west},{north},{east});
      way({south},{west},{north},{east});
      relation({south},{west},{north},{east});
    );
    out body;
    >;
    out skel qt;
    """
    print(f"Downloading OSM map for {city_name} with bbox S={south}, W={west}, N={north}, E={east} ...")

    last_error = None
    for url in mirrors:
        for attempt in range(1, 4):
            try:
                response = requests.post(url, data={'data': overpass_query}, headers=HEADERS, timeout=180)
                if response.status_code == 200 and len(response.content) > 10000:
                    with open(outfile, "wb") as file:
                        file.write(response.content)
                    print(f"Map saved as '{outfile}' via {url}")
                    return
                else:
                    print(f"[{url}] attempt {attempt}: HTTP {response.status_code}, size={len(response.content)}")
            except Exception as e:
                last_error = e
                print(f"[{url}] attempt {attempt}: error {e}")
            # brief backoff
            import time
            time.sleep(3 * attempt)

    if last_error:
        print(f"All mirrors failed, last error: {last_error}")
    raise SystemExit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--city", required=True)
    parser.add_argument("--outfile", required=True)
    args = parser.parse_args()
    download_osm_map(args.city, args.outfile)
