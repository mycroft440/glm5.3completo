#!/usr/bin/env bash
set -Eeuo pipefail
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd -- "$(dirname -- "$SELF")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

EVENTS_URL="http://169.254.169.254/metadata/scheduledevents?api-version=2020-07-01"

has_preempt_event() {
  jq -e '.Events[]? | select(.EventType == "Preempt")' >/dev/null
}

if [[ "${1:-}" == "--self-test" ]]; then
  printf '%s\n' '{"Events":[{"EventType":"Preempt","Resources":["vm"]}]}' | has_preempt_event
  if printf '%s\n' '{"Events":[{"EventType":"Reboot"}]}' | has_preempt_event; then
    die "spot-watch self-test aceitou evento não-Preempt."
  fi
  log "spot-watch self-test OK."
  exit 0
fi

load_env
require_resolved_profile
POLL_INTERVAL="${SPOT_POLL_INTERVAL_S:-5}"
[[ "$POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "SPOT_POLL_INTERVAL_S deve ser inteiro positivo."
MARKER_DIR="${MODEL_STORAGE_ROOT:-/var/lib/glm53-full}"
MARKER_FILE="${MARKER_DIR}/spot-preempt.log"

log "Azure Spot watcher ativo; consultando Scheduled Events a cada ${POLL_INTERVAL}s."
while :; do
  events="$(curl --noproxy '*' -fsS --max-time 3 -H Metadata:true "$EVENTS_URL" 2>/dev/null || true)"
  if [[ -n "$events" ]] && printf '%s\n' "$events" | has_preempt_event; then
    warn "Azure Scheduled Events sinalizou PREEMPT. Fechando gateway e runtime."
    mkdir -p "$MARKER_DIR" 2>/dev/null || true
    printf '%s PREEMPT detected; profile=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ACCELERATOR_PROFILE" >>"$MARKER_FILE" 2>/dev/null || true
    sync || true
    compose stop -t 5 gateway >/dev/null 2>&1 || true
    compose stop -t 10 vllm >/dev/null 2>&1 || true
    sync || true
    exit 0
  fi
  sleep "$POLL_INTERVAL"
done
