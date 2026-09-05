#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '\033[1;34m[glm53-full]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[glm53-full][warn]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[glm53-full][error]\033[0m %s\n' "$*" >&2; exit 1; }

project_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd
}

load_env() {
  local root
  root="$(project_dir)"
  [[ -f "$root/.env" ]] || die "Arquivo .env ausente. Execute ./install.sh primeiro."
  set -a
  # shellcheck disable=SC1091
  source "$root/.env"
  set +a
}

detect_accelerator_profile() {
  if [[ -e /dev/kfd ]] && command -v rocminfo >/dev/null 2>&1 \
      && rocminfo 2>/dev/null | grep -Eq 'Name:[[:space:]]+gfx942'; then
    printf 'rocm\n'
    return 0
  fi
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    printf 'nvidia\n'
    return 0
  fi
  return 1
}

require_resolved_profile() {
  case "${ACCELERATOR_PROFILE:-}" in
    rocm|nvidia) ;;
    auto|"") die "ACCELERATOR_PROFILE ainda não foi resolvido. Execute sudo ./install.sh." ;;
    *) die "ACCELERATOR_PROFILE inválido: ${ACCELERATOR_PROFILE}. Use auto, rocm ou nvidia." ;;
  esac
}

compose() {
  local root profile
  root="$(project_dir)"
  profile="${ACCELERATOR_PROFILE:-}"
  case "$profile" in
    rocm|nvidia) ;;
    *) die "Perfil de acelerador não resolvido para Docker Compose: ${profile:-vazio}." ;;
  esac
  docker compose \
    --env-file "$root/.env" \
    -f "$root/docker-compose.yml" \
    -f "$root/docker-compose.${profile}.yml" \
    "$@"
}

api_origin() {
  local host="${BIND_ADDRESS:-127.0.0.1}"
  local port="${API_PORT:-8000}"
  case "$host" in
    0.0.0.0) host="127.0.0.1" ;;
    "::") host="[::1]" ;;
    *:*) [[ "$host" == \[*\] ]] || host="[$host]" ;;
  esac
  printf 'http://%s:%s\n' "$host" "$port"
}

gpu_summary() {
  case "${ACCELERATOR_PROFILE:-}" in
    rocm)
      if command -v rocm-smi >/dev/null 2>&1; then
        rocm-smi --showproductname 2>/dev/null | sed -n 's/.*Card series:[[:space:]]*//p' | sort -u | paste -sd ',' -
      else
        printf 'AMD gfx942 (MI300X esperado)\n'
      fi
      ;;
    nvidia)
      nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u | paste -sd ',' -
      ;;
    *) printf 'indisponível\n' ;;
  esac
}

gpu_count() {
  case "${ACCELERATOR_PROFILE:-}" in
    rocm)
      rocminfo 2>/dev/null | grep -Ec 'Name:[[:space:]]+gfx942' || true
      ;;
    nvidia)
      nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d ' '
      ;;
    *) printf '0\n' ;;
  esac
}
