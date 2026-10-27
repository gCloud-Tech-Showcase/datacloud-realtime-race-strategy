#!/usr/bin/env python3
"""Download one photo per team from Wikimedia Commons into the race-data bucket.

Runs on the machine that runs `tofu apply` (see media.tf). The photos are not
committed to this repository. media/car_photos.json lists them, with their
author and license, and each object keeps that credit as custom metadata, so
the object table and the pit wall can show it:

    gs://<bucket>/media/cars/<team>.jpg   metadata: team, author, license, ...

Commons serves a resized copy (WIDTH pixels wide), which is all the demo needs.

If every photo is already in the bucket, the script does nothing.

Usage: load_car_photos.py <bucket> <path to car_photos.json>
"""

import json
import logging
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

logger = logging.getLogger(__name__)

COMMONS_API = "https://commons.wikimedia.org/w/api.php"
# Wikimedia asks API clients to identify themselves with a contact URL.
USER_AGENT = (
    "datacloud-realtime-race-strategy "
    "(https://github.com/gCloud-Tech-Showcase/datacloud-realtime-race-strategy)"
)
WIDTH = 1280
MAX_ATTEMPTS = 5


def get(url: str) -> bytes:
    """Return the body of a GET request, retrying on rate limits and server errors."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == MAX_ATTEMPTS:
                raise
        delay = 2**attempt
        logger.info("Commons answered with an error, retrying in %ss", delay)
        time.sleep(delay)
    raise RuntimeError(f"unreachable: {url}")


def resized_url(commons_title: str) -> str:
    """Return the URL of a WIDTH-pixel copy of a Commons file."""
    params = {
        "action": "query",
        "format": "json",
        "titles": commons_title,
        "prop": "imageinfo",
        "iiprop": "url",
        "iiurlwidth": WIDTH,
    }
    data = json.loads(get(f"{COMMONS_API}?{urllib.parse.urlencode(params)}"))
    page = next(iter(data["query"]["pages"].values()))
    return page["imageinfo"][0]["thumburl"]


def already_loaded(destination: str, photos: list[dict]) -> bool:
    """Return True when every photo is already in the bucket."""
    listing = subprocess.run(
        ["gcloud", "storage", "ls", destination], capture_output=True, text=True, check=False
    )
    present = {line.rsplit("/", 1)[-1] for line in listing.stdout.split()}
    return all(photo["file"] in present for photo in photos)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    bucket, list_path = sys.argv[1:]
    photos = json.loads(Path(list_path).read_text(encoding="utf-8"))
    destination = f"gs://{bucket}/media/cars/"

    if already_loaded(destination, photos):
        logger.info("car photos already in %s, skipping the download", destination)
        return

    with tempfile.TemporaryDirectory() as tmp:
        for photo in photos:
            path = Path(tmp) / photo["file"]
            path.write_bytes(get(resized_url(photo["commons_title"])))
            # Custom metadata travels with the object into the object table.
            metadata = ",".join(
                f"{key}={photo[key]}"
                for key in ("team", "author", "license", "license_url", "source")
            )
            subprocess.run(
                [
                    "gcloud",
                    "storage",
                    "cp",
                    "--quiet",
                    "--content-type=image/jpeg",
                    f"--custom-metadata={metadata}",
                    str(path),
                    destination + photo["file"],
                ],
                check=True,
            )
            logger.info("%-16s %s", photo["team"], photo["commons_title"])
            # Stay well under Commons rate limits.
            time.sleep(1)
    logger.info("uploaded %d photos to %s", len(photos), destination)


if __name__ == "__main__":
    main()
