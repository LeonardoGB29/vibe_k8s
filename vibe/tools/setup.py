#!/usr/bin/env python3
"""
Verifica las herramientas del proyecto e instala SOLO las que faltan.
Funciona en macOS (Homebrew), Windows (winget) y Linux (apt/brew).
Solo usa la librería estándar de Python.

    python tools/setup.py             # reporte: qué tienes y qué falta (no instala nada)
    python tools/setup.py --install   # instala únicamente lo que falta
"""
import argparse
import platform
import shutil
import subprocess
import sys

OS = {"Darwin": "mac", "Windows": "win", "Linux": "linux"}.get(platform.system(), "linux")

# nombre: (comando para versión, {so: comando de instalación}, requerido)
TOOLS = {
    "docker": (["docker", "--version"], {
        "mac": "brew install --cask docker",
        "win": "winget install -e --id Docker.DockerDesktop",
        "linux": "curl -fsSL https://get.docker.com | sh",
    }, True),
    "kind": (["kind", "version"], {
        "mac": "brew install kind",
        "win": "winget install -e --id Kubernetes.kind",
        "linux": "brew install kind",
    }, True),
    "kubectl": (["kubectl", "version", "--client"], {
        "mac": "brew install kubernetes-cli",
        "win": "winget install -e --id Kubernetes.kubectl",
        "linux": "brew install kubernetes-cli",
    }, True),
    "helm": (["helm", "version", "--short"], {
        "mac": "brew install helm",
        "win": "winget install -e --id Helm.Helm",
        "linux": "brew install helm",
    }, True),
    "k6": (["k6", "version"], {
        "mac": "brew install k6",
        "win": "winget install -e --id k6.k6",
        "linux": "brew install k6",
    }, True),
    "ffmpeg": (["ffmpeg", "-version"], {
        "mac": "brew install ffmpeg",
        "win": "winget install -e --id Gyan.FFmpeg",
        "linux": "sudo apt-get install -y ffmpeg",
    }, True),
    "make": (["make", "--version"], {
        "mac": "xcode-select --install",
        "win": "winget install -e --id ezwinports.make",
        "linux": "sudo apt-get install -y make",
    }, True),
    "k9s": (["k9s", "version", "--short"], {
        "mac": "brew install k9s",
        "win": "winget install -e --id Derailed.k9s",
        "linux": "brew install k9s",
    }, False),
}

PKG_MANAGER = {"mac": "brew", "win": "winget", "linux": "apt-get"}[OS]

G, R, Y, N = ("\033[32m", "\033[31m", "\033[33m", "\033[0m") if sys.stdout.isatty() else ("", "", "", "")


def version_of(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        line = (out.stdout or out.stderr).strip().splitlines()
        return line[0][:60] if line else ""
    except Exception:  # noqa: BLE001
        return ""


def docker_status():
    if not shutil.which("docker"):
        return R, "FALTA", ""
    try:
        out = subprocess.run(["docker", "info", "--format", "{{.NCPU}} {{.MemTotal}}"],
                             capture_output=True, text=True, timeout=20)
        if out.returncode != 0:
            return R, "APAGADO", "abre Docker Desktop (o OrbStack en Mac)"
        cpu, mem = out.stdout.split()
        gb = int(mem) // (1024 ** 3)
        if gb >= 8:
            return G, "OK", f"{cpu} CPUs, {gb} GB RAM"
        return Y, "POCA RAM", f"{cpu} CPUs, {gb} GB (sube a 8 GB en Settings > Resources)"
    except Exception:  # noqa: BLE001
        return R, "APAGADO", "abre Docker Desktop"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--install", action="store_true", help="instala solo lo que falta")
    args = ap.parse_args()

    print(f"Sistema: {platform.system()} {platform.machine()}  ·  gestor: {PKG_MANAGER}\n")
    if OS == "mac" and not shutil.which("brew"):
        print(f"{R}Falta Homebrew{N}: instálalo primero desde https://brew.sh\n")
    if OS == "win" and not shutil.which("winget"):
        print(f"{R}Falta winget{N}: viene con 'App Installer' de la Microsoft Store\n")

    missing = []
    print("Herramientas:")
    for name, (vcmd, installers, required) in TOOLS.items():
        if shutil.which(name):
            print(f"  {name:<10} {G}OK{N:<6}  {version_of(vcmd)}")
        else:
            tag = "FALTA" if required else "OPCIONAL"
            color = R if required else Y
            print(f"  {name:<10} {color}{tag}{N:<6}  -> {installers[OS]}")
            missing.append((name, installers[OS], required))

    print("\nDocker:")
    c, st, info = docker_status()
    print(f"  {'daemon':<10} {c}{st}{N:<6}  {info}")

    if shutil.which("kind"):
        out = subprocess.run(["kind", "get", "clusters"], capture_output=True, text=True)
        exists = "vibe" in out.stdout.split()
        print("\nCluster kind:")
        print(f"  {'vibe':<10} {G + 'EXISTE' if exists else Y + 'NO'}{N:<6}  {'make status' if exists else 'make up lo crea'}")

    print()
    if not missing:
        print(f"{G}Todo instalado.{N} Siguiente paso: make compose")
        return
    req = [m for m in missing if m[2]]
    print(f"{Y}Faltan {len(req)} requeridas{N} y {len(missing) - len(req)} opcionales.")
    if not args.install:
        print("Instala solo lo que falta con:  python tools/setup.py --install")
        return

    for name, cmd, _ in missing:
        print(f"\n{Y}Instalando {name}{N}: {cmd}")
        rc = subprocess.run(cmd, shell=True).returncode
        print(f"  {G + 'listo' if rc == 0 else R + 'falló (rc=' + str(rc) + ')'}{N}")
    if OS == "win":
        print("\nEn Windows abre una terminal nueva para que se actualice el PATH.")
    print("Docker Desktop hay que abrirlo manualmente la primera vez.")


if __name__ == "__main__":
    main()
