#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
[[ -f "$ROOT_DIR/.env" ]] && load_env

TP_SIZE="${TENSOR_PARALLEL_SIZE:-8}"
EXPECTED_GPU_COUNT="${EXPECTED_GPUS:-$TP_SIZE}"
STRICT_GPU_COUNT_VALUE="${STRICT_GPU_COUNT:-1}"
EXPECTED_GPU_PATTERN="${EXPECTED_GPU_NAME_REGEX:-H200}"
MIN_GPU_MEMORY_MIB="${MIN_GPU_MEMORY_MIB:-130000}"
MIN_HOST_RAM="${MIN_HOST_RAM_GIB:-1400}"
REQUIRE_FM="${REQUIRE_FABRIC_MANAGER:-1}"
MIN_HF_FREE_GIB="${MIN_FREE_DISK_GIB:-1200}"
MIN_DOCKER_FREE_GIB="${MIN_DOCKER_FREE_DISK_GIB:-100}"
MIN_VLLM_CACHE_FREE_GIB="${MIN_VLLM_CACHE_FREE_DISK_GIB:-30}"
MIN_DG_CACHE_FREE_GIB="${MIN_DEEPGEMM_CACHE_FREE_DISK_GIB:-20}"
HF_CACHE_PATH="${HF_CACHE_DIR:-/var/lib/glm53-full/huggingface}"
VLLM_CACHE_PATH="${VLLM_CACHE_DIR:-/var/lib/glm53-full/vllm-cache}"
DG_CACHE_PATH="${DEEPGEMM_CACHE_DIR:-/var/lib/glm53-full/deepgemm-cache}"
MAX_LEN="${MAX_MODEL_LEN:-131072}"
MAX_SEQS="${MAX_NUM_SEQS:-8}"
MAX_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
MTP_TOKENS="${MTP_SPECULATIVE_TOKENS:-5}"
API_LISTEN_PORT="${API_PORT:-8000}"
READY_TIMEOUT="${VLLM_ENGINE_READY_TIMEOUT_S:-7200}"
GPU_UTIL="${GPU_MEMORY_UTILIZATION:-0.90}"
CUDA_COMPAT="${VLLM_ENABLE_CUDA_COMPATIBILITY:-0}"

# Valores abaixo também são lidos indiretamente por nome.
# shellcheck disable=SC2034
: "$MAX_LEN" "$READY_TIMEOUT" "$MAX_SEQS" "$MAX_BATCHED_TOKENS" "$MTP_TOKENS"
for value_name in TP_SIZE EXPECTED_GPU_COUNT MIN_GPU_MEMORY_MIB MIN_HOST_RAM MIN_HF_FREE_GIB MIN_DOCKER_FREE_GIB MIN_VLLM_CACHE_FREE_GIB MIN_DG_CACHE_FREE_GIB MAX_LEN MAX_SEQS MAX_BATCHED_TOKENS MTP_TOKENS API_LISTEN_PORT READY_TIMEOUT; do
  value="${!value_name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "${value_name} deve ser inteiro positivo; recebido: ${value}."
done
for bool_value in "$STRICT_GPU_COUNT_VALUE" "$REQUIRE_FM" "$CUDA_COMPAT"; do
  [[ "$bool_value" =~ ^[01]$ ]] || die "Flags STRICT_GPU_COUNT, REQUIRE_FABRIC_MANAGER e VLLM_ENABLE_CUDA_COMPATIBILITY devem ser 0 ou 1."
done
(( API_LISTEN_PORT <= 65535 )) || die "API_PORT deve estar entre 1 e 65535."
(( EXPECTED_GPU_COUNT >= TP_SIZE )) || die "EXPECTED_GPUS não pode ser menor que TENSOR_PARALLEL_SIZE."
[[ "$GPU_UTIL" =~ ^(0\.[0-9]+|1(\.0+)?)$ ]] || die "GPU_MEMORY_UTILIZATION deve estar entre 0 e 1; recebido: ${GPU_UTIL}."
awk -v v="$GPU_UTIL" 'BEGIN { exit !(v > 0 && v <= 1) }' || die "GPU_MEMORY_UTILIZATION deve ser >0 e <=1."

[[ -n "${MODEL_ID:-}" ]] || die "MODEL_ID não pode ficar vazio."
[[ "${MODEL_REVISION:-}" =~ ^[0-9a-fA-F]{40}$ ]] || die "MODEL_REVISION deve ser um commit Hugging Face de 40 caracteres; não use main em produção."
[[ -n "${SERVED_MODEL_NAME:-}" ]] || die "SERVED_MODEL_NAME não pode ficar vazio."
[[ "${VLLM_BASE_IMAGE:-}" == *@sha256:* ]] || die "VLLM_BASE_IMAGE deve estar fixada por digest sha256."
[[ -n "${VLLM_IMAGE:-}" ]] || die "VLLM_IMAGE não pode ficar vazio."
[[ "${VLLM_IMAGE}" != "${VLLM_BASE_IMAGE}" ]] || die "VLLM_IMAGE deve ser uma tag local diferente de VLLM_BASE_IMAGE."
[[ "${NGINX_IMAGE:-}" == *@sha256:* ]] || die "NGINX_IMAGE deve estar fixada por digest sha256."
[[ -n "${VLLM_SOURCE_REF:-}" ]] || die "VLLM_SOURCE_REF não pode ficar vazio."
[[ -n "${DEEPGEMM_REF:-}" ]] || die "DEEPGEMM_REF não pode ficar vazio."
[[ -n "${API_KEY:-}" && "${API_KEY}" != "CHANGE_ME" ]] || die "API_KEY ausente ou ainda definida como CHANGE_ME."
[[ "${KV_CACHE_DTYPE:-fp8}" =~ ^(fp8|fp8_e4m3|auto)$ ]] || die "KV_CACHE_DTYPE deve ser fp8, fp8_e4m3 ou auto neste perfil."
[[ "${VLLM_MEDIA_URL_ALLOW_REDIRECTS:-0}" =~ ^[01]$ ]] || die "VLLM_MEDIA_URL_ALLOW_REDIRECTS deve ser 0 ou 1."
[[ "${ALLOWED_MEDIA_DOMAIN:-media.invalid}" != *[[:space:]]* ]] || die "ALLOWED_MEDIA_DOMAIN aceita um único domínio sem espaços."

if (( MAX_BATCHED_TOKENS > 8192 )); then
  warn "MAX_NUM_BATCHED_TOKENS=${MAX_BATCHED_TOKENS} aumenta o workspace de sparse decode. O perfil H200 conservador começa em 8192."
fi

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi não encontrado. Use a imagem Azure HPC A100+ recomendada."
command -v docker >/dev/null 2>&1 || die "Docker não encontrado."
docker compose version >/dev/null 2>&1 || die "Docker Compose não encontrado."
docker info >/dev/null 2>&1 || die "Docker daemon não está acessível."

MEM_TOTAL_KIB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
[[ "$MEM_TOTAL_KIB" =~ ^[0-9]+$ ]] || die "Não foi possível ler a RAM do host."
HOST_RAM_GIB="$(( MEM_TOTAL_KIB / 1024 / 1024 ))"
(( HOST_RAM_GIB >= MIN_HOST_RAM )) || die "RAM insuficiente: ${HOST_RAM_GIB} GiB detectados; perfil exige >= ${MIN_HOST_RAM} GiB."

mapfile -t GPU_MEM < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
mapfile -t GPU_NAME < <(nvidia-smi --query-gpu=name --format=csv,noheader)
GPU_COUNT="${#GPU_MEM[@]}"
if [[ "$STRICT_GPU_COUNT_VALUE" == "1" ]]; then
  (( GPU_COUNT == EXPECTED_GPU_COUNT )) || die "Este perfil exige exatamente ${EXPECTED_GPU_COUNT} GPUs; detectadas: ${GPU_COUNT}."
else
  (( GPU_COUNT >= EXPECTED_GPU_COUNT )) || die "São necessárias pelo menos ${EXPECTED_GPU_COUNT} GPUs; detectadas: ${GPU_COUNT}."
fi
for ((i=0; i<EXPECTED_GPU_COUNT; i++)); do
  mem="${GPU_MEM[$i]}"
  name="${GPU_NAME[$i]:-desconhecida}"
  [[ "$mem" =~ ^[0-9]+$ ]] || die "Não foi possível interpretar a VRAM da GPU $i: $mem"
  (( mem >= MIN_GPU_MEMORY_MIB )) || die "GPU $i (${name}) tem ${mem} MiB; este perfil exige >= ${MIN_GPU_MEMORY_MIB} MiB por GPU."
  [[ "$name" =~ $EXPECTED_GPU_PATTERN ]] || die "GPU $i (${name}) não corresponde a EXPECTED_GPU_NAME_REGEX=${EXPECTED_GPU_PATTERN}."
done
UNIQUE_GPU_NAMES="$(printf '%s\n' "${GPU_NAME[@]:0:EXPECTED_GPU_COUNT}" | sort -u | wc -l | tr -d ' ')"
[[ "$UNIQUE_GPU_NAMES" == "1" ]] || die "Topologia heterogênea detectada entre as GPUs selecionadas; use GPUs idênticas."

DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')"
DRIVER_MAJOR="${DRIVER_VERSION%%.*}"
if [[ "$DRIVER_MAJOR" =~ ^[0-9]+$ ]] && (( DRIVER_MAJOR < 580 )) && [[ "$CUDA_COMPAT" != "1" ]]; then
  die "Driver NVIDIA ${DRIVER_VERSION} é anterior a R580 e CUDA forward compatibility não está ativa. Execute install.sh."
fi

TOPO_OUTPUT="$(nvidia-smi topo -m 2>/dev/null || true)"
[[ -n "$TOPO_OUTPUT" ]] || die "Não foi possível ler a topologia NVIDIA."
NVLINK_ROWS="$(printf '%s\n' "$TOPO_OUTPUT" | awk '/^GPU[0-9]+/ && /NV[0-9]+/ {c++} END {print c+0}')"
(( NVLINK_ROWS >= EXPECTED_GPU_COUNT )) || die "A topologia não mostra NVLink/NVSwitch para todas as GPUs esperadas."

if [[ "$REQUIRE_FM" == "1" ]]; then
  systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^nvidia-fabricmanager\.service' || die "NVIDIA Fabric Manager não está instalado/registrado."
  systemctl is-active --quiet nvidia-fabricmanager.service || die "NVIDIA Fabric Manager está instalado, mas não está ativo."
elif systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^nvidia-fabricmanager\.service'; then
  systemctl is-active --quiet nvidia-fabricmanager.service || warn "NVIDIA Fabric Manager foi detectado, mas não está ativo."
fi

mkdir -p "$HF_CACHE_PATH" "$VLLM_CACHE_PATH" "$DG_CACHE_PATH" || die "Não foi possível criar os diretórios de cache."
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
[[ -n "$DOCKER_ROOT" ]] || die "Não foi possível descobrir DockerRootDir."

declare -A REQUIRED_GIB=()
declare -A FREE_GIB=()
declare -A FS_LABELS=()
add_disk_requirement() {
  local path="$1" required="$2" label="$3" probe="$1" device free_kib free_gib
  if ! df -Pk "$probe" >/dev/null 2>&1; then probe="$(dirname -- "$path")"; fi
  df -Pk "$probe" >/dev/null 2>&1 || die "Não foi possível medir espaço livre para ${label} em ${path}."
  device="$(df -Pk "$probe" | awk 'NR==2 {print $1}')"
  free_kib="$(df -Pk "$probe" | awk 'NR==2 {print $4}')"
  [[ -n "$device" && "$free_kib" =~ ^[0-9]+$ ]] || die "Falha ao interpretar filesystem de ${label}."
  free_gib="$(( free_kib / 1024 / 1024 ))"
  REQUIRED_GIB["$device"]="$(( ${REQUIRED_GIB[$device]:-0} + required ))"
  FREE_GIB["$device"]="$free_gib"
  if [[ -n "${FS_LABELS[$device]:-}" ]]; then FS_LABELS["$device"]+=" + ${label}"; else FS_LABELS["$device"]="$label"; fi
}
add_disk_requirement "$HF_CACHE_PATH" "$MIN_HF_FREE_GIB" "pesos/Hugging Face"
add_disk_requirement "$VLLM_CACHE_PATH" "$MIN_VLLM_CACHE_FREE_GIB" "cache vLLM"
add_disk_requirement "$DG_CACHE_PATH" "$MIN_DG_CACHE_FREE_GIB" "cache JIT DeepGEMM"
add_disk_requirement "$DOCKER_ROOT" "$MIN_DOCKER_FREE_GIB" "Docker"
for device in "${!REQUIRED_GIB[@]}"; do
  required="${REQUIRED_GIB[$device]}"; free="${FREE_GIB[$device]}"
  (( free >= required )) || die "Espaço insuficiente em ${device} (${FS_LABELS[$device]}): ${free} GiB livres; mínimo agregado: ${required} GiB."
  log "Disco OK em ${device}: ${free} GiB livres para ${FS_LABELS[$device]} (mínimo agregado ${required} GiB)."
done

GPU_SUMMARY="$(printf '%s\n' "${GPU_NAME[@]:0:EXPECTED_GPU_COUNT}" | sort -u | paste -sd ';' -)"
log "Pré-validação OK: ${EXPECTED_GPU_COUNT}/${GPU_COUNT} GPUs (${GPU_SUMMARY}); TP=${TP_SIZE}; RAM=${HOST_RAM_GIB} GiB; driver ${DRIVER_VERSION}; NVLink/NVSwitch OK; lote máximo=${MAX_BATCHED_TOKENS}."
