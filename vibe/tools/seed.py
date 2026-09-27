#!/usr/bin/env python3
"""
Sube en paralelo todos los audios de una carpeta a la API.
Sirve como carga inicial y como prueba de escalabilidad del worker
(sube 200 de golpe y mira cómo KEDA crea pods).

Uso:
    python tools/seed.py --api http://localhost:8000 --dir data/audio --parallel 10
"""
import argparse
import csv
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib import request

import mimetypes
import uuid


def multipart(fields: dict, file_field: str, path: Path) -> tuple[bytes, str]:
    boundary = f"----vibe{uuid.uuid4().hex}"
    body = bytearray()
    for k, v in fields.items():
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
    ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{path.name}\"\r\nContent-Type: {ctype}\r\n\r\n".encode()
    body += path.read_bytes()
    body += f"\r\n--{boundary}--\r\n".encode()
    return bytes(body), f"multipart/form-data; boundary={boundary}"


def upload(api: str, path: Path, meta: dict) -> tuple[str, bool, float]:
    t0 = time.time()
    body, ctype = multipart({"title": meta["title"], "artist": meta["artist"], "album": meta["album"]}, "file", path)
    req = request.Request(f"{api}/api/tracks", data=body, method="POST", headers={"Content-Type": ctype})
    try:
        with request.urlopen(req, timeout=120) as resp:
            return path.name, resp.status == 201, time.time() - t0
    except Exception as exc:  # noqa: BLE001
        print(f"  ERROR {path.name}: {exc}")
        return path.name, False, time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="http://localhost:8000")
    ap.add_argument("--dir", default="data/audio")
    ap.add_argument("--parallel", type=int, default=10)
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    d = Path(args.dir)
    manifest = {}
    if (d / "manifest.csv").exists():
        with open(d / "manifest.csv") as f:
            manifest = {r["file"]: r for r in csv.DictReader(f)}
    files = sorted(p for p in d.iterdir() if p.suffix.lower() in {".mp3", ".wav", ".flac", ".ogg", ".m4a"})
    if args.limit:
        files = files[: args.limit]

    print(f"Subiendo {len(files)} archivos a {args.api} con {args.parallel} en paralelo")
    t0 = time.time()
    ok = 0
    with ThreadPoolExecutor(args.parallel) as ex:
        futs = [ex.submit(upload, args.api, p, manifest.get(p.name, {"title": p.stem, "artist": "Desconocido", "album": "Single"})) for p in files]
        for i, fut in enumerate(as_completed(futs), 1):
            name, good, dt = fut.result()
            ok += good
            if i % 10 == 0 or i == len(files):
                print(f"  {i}/{len(files)} ({ok} ok) último: {name} en {dt:.2f}s")
    print(f"Listo: {ok}/{len(files)} en {time.time() - t0:.1f}s. Ahora mira la cola: {args.api}/api/stats")


if __name__ == "__main__":
    main()
