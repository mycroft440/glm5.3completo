#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_env

if ! docker info >/dev/null 2>&1 && [[ "${EUID}" -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi
ORIGIN="$(api_origin)"
RUNNING_SERVICES="$(docker compose --env-file "$ROOT_DIR/.env" -f "$ROOT_DIR/docker-compose.yml" ps --services --status running)"
grep -qx 'vllm' <<<"$RUNNING_SERVICES" || die "Container vllm não está em execução."
grep -qx 'gateway' <<<"$RUNNING_SERVICES" || die "Container gateway não está em execução."
curl --fail-with-body -sS --max-time 15 -H "Authorization: Bearer ${API_KEY}" "${ORIGIN}/v1/models" >/dev/null || die "API ainda não respondeu em ${ORIGIN}/v1/models."
log "API saudável em ${ORIGIN}/v1"
