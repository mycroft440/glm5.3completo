#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
[[ -f "$ROOT_DIR/.env" ]] && load_env
require_resolved_profile

TP_SIZE="${TENSOR_PARALLEL_SIZE:-8}"
EXPECTED_GPU_COUNT="${EXPECTED_GPUS:-$TP_SIZE}"
STRICT_GPU_COUNT_VALUE="${STRICT_GPU_COUNT:-1}"
MIN_HOST_RAM="${MIN_HOST_RAM_GIB:-1400}"
MIN_HF_FREE_GIB="${MIN_FREE_DISK_GIB:-1200}"
MIN_DOCKER_FREE_GIB="${MIN_DOCKER_FREE_DISK_GIB:-100}"
MIN_VLLM_CACHE_FREE_GIB="${MIN_VLLM_CACHE_FREE_DISK_GIB:-30}"
HF_CACHE_PATH="${HF_CACHE_DIR:-/var/lib/glm53-full/huggingface}"
VLLM_CACHE_PATH="${VLLM_CACHE_DIR:-/var/lib/glm53-full/vllm-cache}"
MODEL_STORAGE_PATH="${MODEL_STORAGE_ROOT:-/var/lib/glm53-full}"
REQUIRE_SEPARATE_STORAGE="${REQUIRE_SEPARATE_MODEL_FILESYSTEM:-1}"
REJECT_AZURE_LOCAL_STORAGE="${REJECT_AZURE_LOCAL_MODEL_STORAGE:-1}"
API_LISTEN_PORT="${API_PORT:-8000}"
READY_TIMEOUT="${VLLM_ENGINE_READY_TIMEOUT_S:-14400}"
GPU_UTIL="${GPU_MEMORY_UTILIZATION:-0.80}"
MTP_TOKENS="${MTP_SPECULATIVE_TOKENS:-5}"
MAX_LEN="${MAX_MODEL_LEN:-524288}"
MAX_SEQS="${MAX_NUM_SEQS:-32}"

for value_name in TP_SIZE EXPECTED_GPU_COUNT MIN_HOST_RAM MIN_HF_FREE_GIB MIN_DOCKER_FREE_GIB MIN_VLLM_CACHE_FREE_GIB MAX_LEN MAX_SEQS MTP_TOKENS API_LISTEN_PORT READY_TIMEOUT; do
  value="${!value_name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "${value_name} deve ser inteiro positivo; recebido: ${value}."
done
[[ "$STRICT_GPU_COUNT_VALUE" =~ ^[01]$ ]] || die "STRICT_GPU_COUNT deve ser 0 ou 1."
[[ "$REQUIRE_SEPARATE_STORAGE" =~ ^[01]$ ]] || die "REQUIRE_SEPARATE_MODEL_FILESYSTEM deve ser 0 ou 1."
[[ "$REJECT_AZURE_LOCAL_STORAGE" =~ ^[01]$ ]] || die "REJECT_AZURE_LOCAL_MODEL_STORAGE deve ser 0 ou 1."
(( API_LISTEN_PORT <= 65535 )) || die "API_PORT deve estar entre 1 e 65535."
(( EXPECTED_GPU_COUNT >= TP_SIZE )) || die "EXPECTED_GPUS não pode ser menor que TENSOR_PARALLEL_SIZE."
[[ "$GPU_UTIL" =~ ^(0\.[0-9]+|1(\.0+)?)$ ]] || die "GPU_MEMORY_UTILIZATION inválido: ${GPU_UTIL}."
awk -v v="$GPU_UTIL" 'BEGIN { exit !(v > 0 && v <= 1) }' || die "GPU_MEMORY_UTILIZATION deve ser >0 e <=1."

[[ -n "${MODEL_ID:-}" ]] || die "MODEL_ID não pode ficar vazio."
[[ "${MODEL_REVISION:-}" =~ ^[0-9a-fA-F]{40}$ ]] || die "MODEL_REVISION deve ser commit Hugging Face de 40 caracteres."
[[ -n "${SERVED_MODEL_NAME:-}" ]] || die "SERVED_MODEL_NAME não pode ficar vazio."
[[ "${VLLM_BASE_IMAGE:-}" == *@sha256:* ]] || die "VLLM_BASE_IMAGE deve estar fixada por digest sha256."
[[ -n "${VLLM_IMAGE:-}" && "${VLLM_IMAGE}" != "auto" ]] || die "VLLM_IMAGE não foi resolvida."
[[ -n "${VLLM_DOCKERFILE:-}" && "${VLLM_DOCKERFILE}" != "auto" ]] || die "VLLM_DOCKERFILE não foi resolvido."
[[ "${NGINX_IMAGE:-}" == *@sha256:* ]] || die "NGINX_IMAGE deve estar fixada por digest sha256."
[[ -n "${API_KEY:-}" && "${API_KEY}" != "CHANGE_ME" ]] || die "API_KEY ausente ou ainda definida como CHANGE_ME."
[[ "${VLLM_MEDIA_URL_ALLOW_REDIRECTS:-0}" =~ ^[01]$ ]] || die "VLLM_MEDIA_URL_ALLOW_REDIRECTS deve ser 0 ou 1."
[[ "${ALLOWED_MEDIA_DOMAIN:-media.invalid}" != *[[:space:]]* ]] || die "ALLOWED_MEDIA_DOMAIN aceita um único domínio sem espaços."

command -v docker >/dev/null 2>&1 || die "Docker não encontrado."
docker compose version >/dev/null 2>&1 || die "Docker Compose não encontrado."
docker info >/dev/null 2>&1 || die "Docker daemon não está acessível."
command -v findmnt >/dev/null 2>&1 || die "findmnt não encontrado."
command -v lsblk >/dev/null 2>&1 || die "lsblk não encontrado."

MEM_TOTAL_KIB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
[[ "$MEM_TOTAL_KIB" =~ ^[0-9]+$ ]] || die "Não foi possível ler a RAM do host."
HOST_RAM_GIB="$(( MEM_TOTAL_KIB / 1024 / 1024 ))"
(( HOST_RAM_GIB >= MIN_HOST_RAM )) || die "RAM insuficiente: ${HOST_RAM_GIB} GiB; mínimo ${MIN_HOST_RAM} GiB."

base_block_device() {
  local dev="$1" parent
  [[ "$dev" == /dev/* ]] || { printf '%s\n' "$dev"; return 0; }
  dev="$(readlink -f -- "$dev" 2>/dev/null || printf '%s' "$dev")"
  while :; do
    parent="$(lsblk -ndo PKNAME "$dev" 2>/dev/null | head -n1 || true)"
    [[ -n "$parent" ]] || break
    dev="/dev/$parent"
  done
  printf '%s\n' "$dev"
}

is_known_azure_local_device() {
  local source_dev="$1" member member_resolved member_base link link_target link_base model
  local -a source_members=() azure_local_bases=()
  [[ "$source_dev" == /dev/* ]] || return 1
  source_dev="$(readlink -f -- "$source_dev" 2>/dev/null || printf '%s' "$source_dev")"

  # Walk the entire block-device graph instead of following one PKNAME chain.
  # Azure MI300X commonly assembles local NVMe as mdraid/RAID0; LVM is also
  # possible. Any ephemeral physical member makes the model filesystem unsafe.
  mapfile -t source_members < <(
    {
      printf '%s\n' "$source_dev"
      lsblk -srno PATH "$source_dev" 2>/dev/null || true
    } | awk 'NF' | sort -u
  )

  shopt -s nullglob
  for link in \
    /dev/disk/azure/resource \
    /dev/disk/azure/resource-part* \
    /dev/disk/azure/local/by-serial/* \
    /dev/disk/azure/local/by-index/* \
    /dev/disk/azure/local/by-name/*; do
    [[ -e "$link" || -L "$link" ]] || continue
    link_target="$(readlink -f -- "$link" 2>/dev/null || true)"
    [[ -n "$link_target" ]] || continue
    azure_local_bases+=("$(base_block_device "$link_target")")
  done
  shopt -u nullglob

  for member in "${source_members[@]}"; do
    [[ "$member" == /dev/* ]] || continue
    member_resolved="$(readlink -f -- "$member" 2>/dev/null || printf '%s' "$member")"
    member_base="$(base_block_device "$member_resolved")"

    for link_base in "${azure_local_bases[@]}"; do
      [[ "$member_base" == "$link_base" ]] && return 0
    done

    # Check both the graph node and its base device. The former catches leaf
    # NVMe members returned by lsblk -s; the latter also catches partitions.
    model="$(lsblk -dn -o MODEL "$member_resolved" 2>/dev/null | head -n1 | xargs || true)"
    [[ "$model" == *"Microsoft NVMe Direct Disk"* ]] && return 0
    model="$(lsblk -dn -o MODEL "$member_base" 2>/dev/null | head -n1 | xargs || true)"
    [[ "$model" == *"Microsoft NVMe Direct Disk"* ]] && return 0
  done
  return 1
}

validate_model_storage() {
  local storage_source storage_mm root_mm
  mkdir -p "$MODEL_STORAGE_PATH" "$HF_CACHE_PATH" "$VLLM_CACHE_PATH" || die "Não foi possível criar diretórios de armazenamento."
  storage_source="$(findmnt -T "$HF_CACHE_PATH" -n -o SOURCE 2>/dev/null || true)"
  storage_mm="$(findmnt -T "$HF_CACHE_PATH" -n -o MAJ:MIN 2>/dev/null || true)"
  root_mm="$(findmnt -T / -n -o MAJ:MIN 2>/dev/null || true)"
  [[ -n "$storage_source" && -n "$storage_mm" && -n "$root_mm" ]] || die "Não foi possível identificar o filesystem de ${HF_CACHE_PATH}."

  if [[ "$REQUIRE_SEPARATE_STORAGE" == "1" && "$storage_mm" == "$root_mm" ]]; then
    die "Os pesos estão no mesmo filesystem do sistema (${storage_source}). Anexe um Managed Disk persistente de pelo menos 2 TiB e monte-o em ${MODEL_STORAGE_PATH} antes de instalar."
  fi
  if [[ "$REJECT_AZURE_LOCAL_STORAGE" == "1" ]] && is_known_azure_local_device "$storage_source"; then
    die "${HF_CACHE_PATH} está em disco local/resource efêmero do Azure (${storage_source}), inclusive possivelmente via RAID/LVM. Use Managed Disk persistente; Spot/deallocate pode apagar o NVMe local."
  fi
  log "Armazenamento do modelo: ${storage_source} em ${MODEL_STORAGE_PATH}; separado do root e sem membros Azure locais efêmeros detectados."
}

validate_nvidia() {
  local expected_pattern="${EXPECTED_GPU_NAME_REGEX:-H200}"
  local min_mem="${MIN_GPU_MEMORY_MIB:-130000}"
  local require_fm="${REQUIRE_FABRIC_MANAGER:-1}"
  local cuda_compat="${VLLM_ENABLE_CUDA_COMPATIBILITY:-0}"
  local driver_version driver_major topo_output nvlink_rows unique_names gpu_count_value mem name i
  local -a gpu_mem gpu_name

  command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi não encontrado para perfil NVIDIA."
  mapfile -t gpu_mem < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
  mapfile -t gpu_name < <(nvidia-smi --query-gpu=name --format=csv,noheader)
  gpu_count_value="${#gpu_mem[@]}"
  if [[ "$STRICT_GPU_COUNT_VALUE" == "1" ]]; then
    (( gpu_count_value == EXPECTED_GPU_COUNT )) || die "Perfil NVIDIA exige exatamente ${EXPECTED_GPU_COUNT} GPUs; detectadas ${gpu_count_value}."
  else
    (( gpu_count_value >= EXPECTED_GPU_COUNT )) || die "São necessárias pelo menos ${EXPECTED_GPU_COUNT} GPUs."
  fi
  [[ "$min_mem" =~ ^[1-9][0-9]*$ ]] || die "MIN_GPU_MEMORY_MIB inválido."
  for ((i=0; i<EXPECTED_GPU_COUNT; i++)); do
    mem="${gpu_mem[$i]}"
    name="${gpu_name[$i]:-desconhecida}"
    [[ "$mem" =~ ^[0-9]+$ ]] || die "VRAM inválida na GPU ${i}: ${mem}"
    (( mem >= min_mem )) || die "GPU ${i} (${name}) tem ${mem} MiB; mínimo ${min_mem}."
    [[ "$name" =~ $expected_pattern ]] || die "GPU ${i} (${name}) não corresponde a ${expected_pattern}."
  done
  unique_names="$(printf '%s\n' "${gpu_name[@]:0:EXPECTED_GPU_COUNT}" | sort -u | wc -l | tr -d ' ')"
  [[ "$unique_names" == "1" ]] || die "GPUs NVIDIA heterogêneas detectadas."

  driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')"
  driver_major="${driver_version%%.*}"
  if [[ "$driver_major" =~ ^[0-9]+$ ]] && (( driver_major < 580 )) && [[ "$cuda_compat" != "1" ]]; then
    die "Driver NVIDIA ${driver_version} < R580 e CUDA compatibility não está ativa."
  fi

  topo_output="$(nvidia-smi topo -m 2>/dev/null || true)"
  [[ -n "$topo_output" ]] || die "Não foi possível ler topologia NVIDIA."
  nvlink_rows="$(printf '%s\n' "$topo_output" | awk '/^GPU[0-9]+/ && /NV[0-9]+/ {c++} END {print c+0}')"
  (( nvlink_rows >= EXPECTED_GPU_COUNT )) || die "NVLink/NVSwitch não aparece para todas as GPUs esperadas."

  if [[ "$require_fm" == "1" ]]; then
    systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^nvidia-fabricmanager\.service' || die "NVIDIA Fabric Manager ausente."
    systemctl is-active --quiet nvidia-fabricmanager.service || die "NVIDIA Fabric Manager não está ativo."
  fi
  log "NVIDIA OK: ${gpu_count_value} GPUs; driver ${driver_version}; NVLink/NVSwitch OK."
}

validate_rocm() {
  local expected_arch="${EXPECTED_GPU_ARCH:-gfx942}"
  local min_mem_mib="${MIN_GPU_MEMORY_MIB:-180000}"
  local gfx_count card_count=0 memory_checked=0 mem_bytes mem_mib vendor card hive_path current_hive first_hive="" topo_type
  local -a amd_cards=()

  [[ -e /dev/kfd ]] || die "/dev/kfd ausente. Use a imagem Azure Ubuntu HPC ROCm para MI300X."
  [[ -d /dev/dri ]] || die "/dev/dri ausente. ROCm não poderá acessar as GPUs."
  command -v rocminfo >/dev/null 2>&1 || die "rocminfo não encontrado. Use microsoft-dsvm:ubuntu-hpc:2404-rocm."
  command -v rocm-smi >/dev/null 2>&1 || die "rocm-smi não encontrado."

  gfx_count="$(rocminfo 2>/dev/null | grep -Ec "Name:[[:space:]]+${expected_arch}" || true)"
  if [[ "$STRICT_GPU_COUNT_VALUE" == "1" ]]; then
    (( gfx_count == EXPECTED_GPU_COUNT )) || die "Perfil ROCm exige exatamente ${EXPECTED_GPU_COUNT} agentes ${expected_arch}; detectados ${gfx_count}."
  else
    (( gfx_count >= EXPECTED_GPU_COUNT )) || die "São necessários pelo menos ${EXPECTED_GPU_COUNT} agentes ${expected_arch}."
  fi

  for card in /sys/class/drm/card[0-9]*; do
    [[ -r "$card/device/vendor" ]] || continue
    vendor="$(<"$card/device/vendor")"
    [[ "$vendor" == "0x1002" ]] || continue
    amd_cards+=("$card")
  done
  card_count="${#amd_cards[@]}"
  (( card_count >= EXPECTED_GPU_COUNT )) || die "Menos de ${EXPECTED_GPU_COUNT} GPUs AMD visíveis em /sys/class/drm: ${card_count}."

  [[ "$min_mem_mib" =~ ^[1-9][0-9]*$ ]] || die "MIN_GPU_MEMORY_MIB inválido."
  for card in "${amd_cards[@]:0:EXPECTED_GPU_COUNT}"; do
    if [[ -r "$card/device/mem_info_vram_total" ]]; then
      mem_bytes="$(<"$card/device/mem_info_vram_total")"
      if [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
        mem_mib="$(( mem_bytes / 1024 / 1024 ))"
        (( mem_mib >= min_mem_mib )) || die "${card} tem ${mem_mib} MiB; mínimo ${min_mem_mib} MiB."
        memory_checked=$((memory_checked + 1))
      fi
    fi

    hive_path="$card/device/xgmi_info/xgmi_hive_id"
    [[ -r "$hive_path" ]] || die "${card} não expõe xgmi_hive_id; Infinity Fabric/XGMI não pôde ser validado."
    current_hive="$(tr -d '[:space:]' < "$hive_path")"
    [[ "$current_hive" =~ [1-9a-fA-F] ]] || die "${card} possui XGMI hive id inválido: ${current_hive:-vazio}."
    if [[ -z "$first_hive" ]]; then
      first_hive="$current_hive"
    elif [[ "$current_hive" != "$first_hive" ]]; then
      die "GPUs MI300X não estão no mesmo XGMI hive: ${first_hive} != ${current_hive}."
    fi
  done
  if (( memory_checked < EXPECTED_GPU_COUNT )); then
    warn "VRAM não pôde ser confirmada por sysfs em todas as GPUs; a validação dentro do container ROCm será obrigatória."
  fi

  topo_type="$(rocm-smi --showtopotype 2>/dev/null || true)"
  [[ "$topo_type" == *XGMI* ]] || die "Topologia ROCm não reporta links XGMI/Infinity Fabric."
  rocm-smi --showtopo >/dev/null 2>&1 || die "rocm-smi não conseguiu consultar a topologia Infinity Fabric."
  log "ROCm OK: ${gfx_count} GPUs ${expected_arch}; XGMI hive ${first_hive}; Infinity Fabric visível."
}

validate_model_storage

case "$ACCELERATOR_PROFILE" in
  nvidia)
    [[ "${KV_CACHE_DTYPE:-}" =~ ^(fp8|fp8_e4m3|auto)$ ]] || die "KV_CACHE_DTYPE NVIDIA inválido."
    [[ "${MAX_NUM_BATCHED_TOKENS:-}" =~ ^[1-9][0-9]*$ ]] || die "MAX_NUM_BATCHED_TOKENS deve ser positivo no perfil NVIDIA."
    if (( MAX_NUM_BATCHED_TOKENS > 8192 )); then
      warn "MAX_NUM_BATCHED_TOKENS=${MAX_NUM_BATCHED_TOKENS} aumenta o workspace sparse-decode; 8192 é o baseline conservador H200."
    fi
    validate_nvidia
    ;;
  rocm)
    [[ "${KV_CACHE_DTYPE:-}" == "fp8_e4m3" ]] || die "Perfil MI300X exige KV_CACHE_DTYPE=fp8_e4m3."
    [[ "${MAX_NUM_BATCHED_TOKENS:-0}" == "0" ]] || warn "MAX_NUM_BATCHED_TOKENS é ignorado no perfil ROCm para seguir o recipe oficial."
    validate_rocm
    ;;
esac

DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
[[ -n "$DOCKER_ROOT" ]] || die "Não foi possível descobrir DockerRootDir."

declare -A REQUIRED_GIB=()
declare -A FREE_GIB=()
declare -A FS_LABELS=()
add_disk_requirement() {
  local path="$1" required="$2" label="$3" probe="$1" device free_kib free_gib
  if ! df -Pk "$probe" >/dev/null 2>&1; then probe="$(dirname -- "$path")"; fi
  df -Pk "$probe" >/dev/null 2>&1 || die "Não foi possível medir espaço para ${label} em ${path}."
  device="$(df -Pk "$probe" | awk 'NR==2 {print $1}')"
  free_kib="$(df -Pk "$probe" | awk 'NR==2 {print $4}')"
  [[ -n "$device" && "$free_kib" =~ ^[0-9]+$ ]] || die "Falha ao interpretar filesystem de ${label}."
  free_gib="$(( free_kib / 1024 / 1024 ))"
  REQUIRED_GIB["$device"]="$(( ${REQUIRED_GIB[$device]:-0} + required ))"
  FREE_GIB["$device"]="$free_gib"
  if [[ -n "${FS_LABELS[$device]:-}" ]]; then
    FS_LABELS["$device"]+=" + ${label}"
  else
    FS_LABELS["$device"]="$label"
  fi
}
add_disk_requirement "$HF_CACHE_PATH" "$MIN_HF_FREE_GIB" "pesos/Hugging Face"
add_disk_requirement "$VLLM_CACHE_PATH" "$MIN_VLLM_CACHE_FREE_GIB" "cache vLLM"
add_disk_requirement "$DOCKER_ROOT" "$MIN_DOCKER_FREE_GIB" "Docker"
if [[ "$ACCELERATOR_PROFILE" == "nvidia" ]]; then
  DG_CACHE_PATH="${DEEPGEMM_CACHE_DIR:-/var/lib/glm53-full/deepgemm-cache}"
  DG_REQ="${MIN_DEEPGEMM_CACHE_FREE_DISK_GIB:-20}"
  [[ "$DG_REQ" =~ ^[1-9][0-9]*$ ]] || die "MIN_DEEPGEMM_CACHE_FREE_DISK_GIB inválido."
  mkdir -p "$DG_CACHE_PATH"
  add_disk_requirement "$DG_CACHE_PATH" "$DG_REQ" "cache JIT DeepGEMM"
fi

for device in "${!REQUIRED_GIB[@]}"; do
  required="${REQUIRED_GIB[$device]}"
  free="${FREE_GIB[$device]}"
  (( free >= required )) || die "Espaço insuficiente em ${device} (${FS_LABELS[$device]}): ${free} GiB livres; mínimo ${required} GiB."
  log "Disco OK em ${device}: ${free} GiB livres para ${FS_LABELS[$device]} (mínimo ${required} GiB)."
done

log "Pré-validação OK: perfil=${ACCELERATOR_PROFILE}; GPUs=${EXPECTED_GPU_COUNT}; TP=${TP_SIZE}; RAM=${HOST_RAM_GIB} GiB; contexto=${MAX_LEN}; seqs=${MAX_SEQS}; MTP=${MTP_TOKENS}; timeout=${READY_TIMEOUT}s."
