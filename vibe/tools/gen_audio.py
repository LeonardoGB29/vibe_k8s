#!/usr/bin/env python3
"""
Genera un dataset de audios sintéticos (sin derechos de autor) con ffmpeg.
Cada pista es una mezcla de tonos con envolvente, distinta en cada archivo.

Uso:
    python tools/gen_audio.py --count 200 --out data/audio --min-sec 20 --max-sec 60
"""
import argparse
import csv
import random
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ADJ = ["Neon", "Vice", "Sunset", "Midnight", "Electric", "Velvet", "Ocean", "Golden", "Retro", "Static",
       "Chrome", "Violet", "Coral", "Pulse", "Mirage", "Lunar", "Solar", "Crimson", "Glass", "Echo"]
NOUN = ["Drive", "Skyline", "Boulevard", "Tide", "Signal", "Horizon", "Motel", "Runway", "Circuit", "Lagoon",
        "Fever", "Parade", "Ghost", "Dream", "Radio", "Riot", "Bloom", "Cascade", "Shadow", "Glow"]
ARTISTS = ["Los Andes Sintéticos", "Kilo Byte", "Miss Latencia", "Pod & Node", "Cluster Club", "DJ Replica",
           "Ingress Boys", "Sidecar", "The Rolling Updates", "Chaos Monkey", "Persistent Volume", "Helm Chart"]
ALBUMS = ["Vol. VI", "Control Plane", "Namespace", "Orchestrated", "Zero Downtime", "Scale Out"]

# escalas pentatónicas (Hz) para que suene a algo y no a alarma
SCALES = [
    [261.63, 293.66, 329.63, 392.00, 440.00, 523.25],
    [220.00, 246.94, 277.18, 329.63, 369.99, 440.00],
    [196.00, 220.00, 246.94, 293.66, 329.63, 392.00],
]


def build_filter(duration: float, seed: int) -> str:
    rnd = random.Random(seed)
    scale = rnd.choice(SCALES)
    bpm = rnd.choice([84, 96, 108, 120, 128])
    beat = 60 / bpm
    voices = []
    # 3 voces: bajo, acorde, melodía con tremolo distinto
    for i, (mult, vol, trem) in enumerate([(0.5, 0.35, 2), (1.0, 0.22, 4), (2.0, 0.18, 8)]):
        f = rnd.choice(scale) * mult
        voices.append(
            f"sine=frequency={f:.2f}:duration={duration}[v{i}a];"
            f"[v{i}a]tremolo=f={trem / beat / 4:.3f}:d=0.6,volume={vol}[v{i}]"
        )
    # capa de "percusión": ruido con puerta rítmica
    voices.append(
        f"anoisesrc=color=pink:duration={duration}:seed={seed}[na];"
        f"[na]tremolo=f={1 / beat:.3f}:d=1.0,highpass=f=2000,volume=0.12[v3]"
    )
    mix = ";".join(voices) + ";[v0][v1][v2][v3]amix=inputs=4:normalize=0,afade=t=in:d=1.5,afade=t=out:st={:.2f}:d=2".format(duration - 2)
    return mix


def gen_one(idx: int, out: Path, dur: float) -> dict:
    rnd = random.Random(idx * 7919)
    title = f"{rnd.choice(ADJ)} {rnd.choice(NOUN)}"
    artist = rnd.choice(ARTISTS)
    album = rnd.choice(ALBUMS)
    path = out / f"{idx:03d} - {artist} - {title}.mp3"
    if not path.exists():
        cmd = [
            "ffmpeg", "-v", "error", "-y",
            "-filter_complex", build_filter(dur, idx),
            "-t", str(dur), "-c:a", "libmp3lame", "-b:a", "160k",
            "-metadata", f"title={title}", "-metadata", f"artist={artist}", "-metadata", f"album={album}",
            str(path),
        ]
        subprocess.run(cmd, check=True)
    return {"file": path.name, "title": title, "artist": artist, "album": album, "seconds": dur}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=50)
    ap.add_argument("--out", default="data/audio")
    ap.add_argument("--min-sec", type=float, default=20)
    ap.add_argument("--max-sec", type=float, default=60)
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rnd = random.Random(42)
    durations = [round(rnd.uniform(args.min_sec, args.max_sec), 1) for _ in range(args.count)]

    with ThreadPoolExecutor(args.jobs) as ex:
        rows = list(ex.map(lambda i: gen_one(i + 1, out, durations[i]), range(args.count)))

    with open(out / "manifest.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys())
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} audios en {out}/ (manifest.csv)")


if __name__ == "__main__":
    main()
