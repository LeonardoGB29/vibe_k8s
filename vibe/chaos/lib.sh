#!/usr/bin/env bash

NS="${NS:-vibe}"
BASE_URL="${BASE_URL:-http://localhost}"
EVIDENCE_DIR="${EVIDENCE_DIR:-docs/evidencia}"
PROBE_PID=""
PROBE_FILE=""
PROBE_TOTAL=0
PROBE_ERRORS=0

now() { date '+%H:%M:%S'; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_cmds() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Falta la herramienta: $cmd"
  done
}

require_positive_int() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 debe ser un entero positivo"
}

require_cluster() {
  kubectl get namespace "$NS" >/dev/null 2>&1 || die "No existe el namespace $NS"
}

start_probe() {
  local name="$1" url="${2:-$BASE_URL/api/stats}" interval="${3:-0.5}"
  mkdir -p "$EVIDENCE_DIR"
  PROBE_FILE="$EVIDENCE_DIR/${name}-$(date '+%Y%m%d-%H%M%S').csv"
  (
    trap 'exit 0' TERM INT
    echo 'timestamp,http_status,time_seconds'
    while true; do
      result="$(curl -sS -o /dev/null --max-time 5 -w '%{http_code},%{time_total}' "$url" 2>/dev/null || true)"
      [[ "$result" == *,* ]] || result='000,5.000000'
      printf '%s,%s\n' "$(date -Iseconds)" "$result"
      sleep "$interval"
    done
  ) >"$PROBE_FILE" &
  PROBE_PID=$!
  echo "[$(now)] Sondeo HTTP: $url -> $PROBE_FILE"
}

stop_probe() {
  [[ -n "$PROBE_PID" ]] || return 0
  kill "$PROBE_PID" 2>/dev/null || true
  wait "$PROBE_PID" 2>/dev/null || true
  PROBE_PID=""
  read -r PROBE_TOTAL PROBE_ERRORS < <(
    awk -F, 'NR>1 {total++; if ($2 !~ /^2[0-9][0-9]$/) errors++} END {print total+0, errors+0}' "$PROBE_FILE"
  )
  echo "[$(now)] Sondeo terminado: $PROBE_TOTAL requests, $PROBE_ERRORS errores"
}
