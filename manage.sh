#!/usr/bin/env bash
set -Eeuo pipefail
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/runtime.sh
source "$ROOT_DIR/scripts/runtime.sh"
load_env
require_resolved_profile
cd "$ROOT_DIR"
LOCK_FILE="/var/lock/glm53-complete.lock"

require_docker_access() {
  if docker info >/dev/null 2>&1; then return 0; fi
  if [[ "${EUID}" -ne 0 ]]; then exec sudo -E "$SELF" "$@"; fi
  die "Docker daemon não está acessível."
}

acquire_operation_lock() {
  command -v flock >/dev/null 2>&1 || die "flock não encontrado; execute sudo ./install.sh."
  exec 9>"$LOCK_FILE" || die "Não foi possível abrir lock ${LOCK_FILE}."
  flock -n 9 || die "Outra operação mutável do GLM-5.3 já está em execução."
}

validate_deployment_config() {
  "$ROOT_DIR/scripts/preflight.sh"
  compose config >/dev/null
}

require_runtime_image() {
  docker image inspect "${VLLM_IMAGE}" >/dev/null 2>&1 \
    || die "Imagem ${VLLM_IMAGE} ausente. Execute sudo ./install.sh ou glm-manage update."
}

wait_for_api() {
  local timeout_sec="${1:-${VLLM_ENGINE_READY_TIMEOUT_S:-7200}}"
  local deadline=$((SECONDS + timeout_sec))
  while (( SECONDS < deadline )); do
    if "$ROOT_DIR/healthcheck.sh" >/dev/null 2>&1; then return 0; fi
    sleep 10
  done
  return 1
}

accelerator_status() {
  case "$ACCELERATOR_PROFILE" in
    rocm)
      rocm-smi --showproductname --showmeminfo vram --showuse 2>/dev/null || rocm-smi 2>/dev/null || true
      ;;
    nvidia)
      nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv || true
      ;;
  esac
}

diagnose() {
  printf '%s\n' "=== Sistema ==="
  if [[ -r /etc/os-release ]]; then grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release || true; fi
  uname -srmo || true
  awk '/^MemTotal:/ {printf "RAM total: %.1f GiB\n", $2/1024/1024}' /proc/meminfo || true

  printf '\nPerfil: %s\n' "$ACCELERATOR_PROFILE"
  if [[ "$ACCELERATOR_PROFILE" == "rocm" ]]; then
    printf '%s\n' "=== AMD ROCm ==="
    rocm-smi --showproductname --showdriverversion --showmeminfo vram --showuse 2>/dev/null || true
    printf '%s\n' "--- gfx agents ---"
    rocminfo 2>/dev/null | grep -E 'Name:[[:space:]]+gfx|Marketing Name' || true
    printf '%s\n' "--- Topologia ---"
    rocm-smi --showtopo 2>/dev/null || true
    if [[ -r /opt/rocm/.info/version ]]; then printf 'ROCm host: %s\n' "$(< /opt/rocm/.info/version)"; fi
  else
    printf '%s\n' "=== NVIDIA ==="
    nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu --format=csv || true
    printf '%s\n' "--- Topologia ---"
    nvidia-smi topo -m || true
    if systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^nvidia-fabricmanager\.service'; then
      printf 'Fabric Manager: '
      systemctl is-active nvidia-fabricmanager.service 2>/dev/null || true
    fi
  fi

  printf '\n%s\n' "=== Docker ==="
  docker --version || true
  docker compose version || true
  docker info --format 'DockerRootDir={{.DockerRootDir}}' 2>/dev/null || true

  printf '\n%s\n' "=== Imagens ==="
  printf 'Base: %s\nRuntime: %s\nDockerfile: %s\nGateway: %s\n' \
    "$VLLM_BASE_IMAGE" "$VLLM_IMAGE" "$VLLM_DOCKERFILE" "$NGINX_IMAGE"
  docker image inspect "$VLLM_IMAGE" --format 'Id={{.Id}} {{range .RepoDigests}}Digest={{.}} {{end}}' 2>/dev/null || true

  printf '\n%s\n' "=== Modelo configurado ==="
  printf 'MODEL_ID=%s\nMODEL_REVISION=%s\nMAX_MODEL_LEN=%s\nMAX_NUM_SEQS=%s\nKV_CACHE_DTYPE=%s\nMTP=%s\n' \
    "$MODEL_ID" "$MODEL_REVISION" "$MAX_MODEL_LEN" "$MAX_NUM_SEQS" "$KV_CACHE_DTYPE" "$MTP_SPECULATIVE_TOKENS"
  if [[ "$ACCELERATOR_PROFILE" == "rocm" ]]; then
    printf 'AITER=enabled\nLINEAR_BACKEND=aiter\nMOE_BACKEND=aiter\n'
  else
    printf 'MAX_NUM_BATCHED_TOKENS=%s\nCUDA_COMPAT=%s\nDEEPGEMM_REF=%s\n' \
      "$MAX_NUM_BATCHED_TOKENS" "$VLLM_ENABLE_CUDA_COMPATIBILITY" "$DEEPGEMM_REF"
  fi

  printf '\n%s\n' "=== Containers ==="
  compose ps || true
  if compose ps --services --status running | grep -qx vllm; then
    printf '\n%s\n' "=== Runtime ==="
    if [[ "$ACCELERATOR_PROFILE" == "rocm" ]]; then
      docker exec glm53-full-vllm python3 -c \
        "import pathlib,vllm,torch,aiter; from importlib.metadata import version; import vllm.entrypoints.chat_utils as cu; print('vLLM',vllm.__version__); print('Transformers',version('transformers')); print('ROCm',torch.version.hip); print('AITER',aiter.__file__); print('Agent patch','GLM53_NULL_TOOL_CONTENT_PATCH' in pathlib.Path(cu.__file__).read_text())" \
        2>/dev/null || true
    else
      docker exec glm53-full-vllm python3 -c \
        "import pathlib,vllm,deep_gemm; from importlib.metadata import version; import vllm.entrypoints.chat_utils as cu; print('vLLM',vllm.__version__); print('Transformers',version('transformers')); print('DeepGEMM',deep_gemm.__file__); print('Agent patch','GLM53_NULL_TOOL_CONTENT_PATCH' in pathlib.Path(cu.__file__).read_text())" \
        2>/dev/null || true
    fi
  fi
}

show_info() {
  local origin status detected_count detected_names host_ip remote_url accel_line
  origin="$(api_origin)"
  status="OFFLINE"
  if curl -fsS --max-time 4 -H "Authorization: Bearer ${API_KEY}" "${origin}/v1/models" >/dev/null 2>&1; then
    status="ONLINE"
  fi
  detected_count="$(gpu_count)"
  detected_names="$(gpu_summary)"
  host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  [[ -n "$host_ip" ]] || host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  case "${BIND_ADDRESS:-127.0.0.1}" in
    127.0.0.1|localhost) remote_url="DESATIVADO (API somente local)" ;;
    0.0.0.0) remote_url="http://${host_ip:-IP_DA_VM}:${API_PORT:-8000}/v1" ;;
    *) remote_url="http://${BIND_ADDRESS}:${API_PORT:-8000}/v1" ;;
  esac
  if [[ "$ACCELERATOR_PROFILE" == "rocm" ]]; then
    accel_line="AMD ROCm / AITER (MI300X)"
  else
    accel_line="NVIDIA CUDA / DeepGEMM (H200)"
  fi

  cat <<INFO
============================================================
 GLM-5.3 COMPLETO — INFORMAÇÕES DA API
============================================================
Status:             ${status}
Perfil acelerador:  ${ACCELERATOR_PROFILE}
Runtime:            ${accel_line}
Modelo:             ${SERVED_MODEL_NAME:-glm-5.3}
Checkpoint:         ${MODEL_ID}
Revisão modelo:     ${MODEL_REVISION}
Base URL local:     ${origin}/v1
Acesso remoto:      ${remote_url}
Bind:               ${BIND_ADDRESS:-127.0.0.1}
Porta:              ${API_PORT:-8000}
API key:            ${API_KEY}
Contexto:           ${MAX_MODEL_LEN} tokens
Tensor Parallel:    ${TENSOR_PARALLEL_SIZE:-8}
KV cache:           ${KV_CACHE_DTYPE}
MTP draft tokens:   ${MTP_SPECULATIVE_TOKENS:-5}
Max sequências:     ${MAX_NUM_SEQS}
GPU utilization:    ${GPU_MEMORY_UTILIZATION}
Imagem base vLLM:   ${VLLM_BASE_IMAGE}
Imagem runtime:     ${VLLM_IMAGE}
Imagem Nginx:       ${NGINX_IMAGE}
GPUs detectadas:    ${detected_count:-0}
Modelo(s) de GPU:   ${detected_names:-indisponível}
Cache HuggingFace:  ${HF_CACHE_DIR}
Cache vLLM:         ${VLLM_CACHE_DIR}
Diretório runtime:  ${ROOT_DIR}
Mídia remota:       ${ALLOWED_MEDIA_DOMAIN:-bloqueada}

PARA USAR A API
---------------
Base URL: ${origin}/v1
Model:    ${SERVED_MODEL_NAME:-glm-5.3}
Header:   Authorization: Bearer <API_KEY_ACIMA>

COMANDOS
--------
glm-info                 Mostrar este painel
glm-manage status        Status dos containers e GPUs
glm-manage logs          Logs do servidor
glm-manage wait          Aguardar API + inferência real
glm-manage test          Smoke test completo, tools e streaming
glm-manage diagnose      Diagnóstico técnico
glm-manage restart       Reaplicar .env sem puxar imagens
glm-manage update        Reconstruir runtime com rollback
glm-manage key           Mostrar somente a API key
============================================================
INFO
  if [[ "${BIND_ADDRESS:-127.0.0.1}" == "127.0.0.1" ]]; then
    warn "A API está somente local. Para agentes remotos, veja SECURITY.md."
  fi
}

rollback_vllm_image() {
  local old_vllm_id="$1" timeout_sec="${2:-${VLLM_ENGINE_READY_TIMEOUT_S:-7200}}"
  [[ -n "$old_vllm_id" ]] || return 1
  docker tag "$old_vllm_id" "$VLLM_IMAGE" || return 1
  compose up -d --force-recreate --pull never || return 1
  if ! wait_for_api "$timeout_sec"; then
    warn "Imagem anterior restaurada, mas a API não voltou no limite."
    return 1
  fi
  "$ROOT_DIR/healthcheck.sh" --deep >/dev/null 2>&1 || return 1
}

safe_update() {
  local image="$VLLM_IMAGE" old_vllm_id="" candidate timeout_sec
  [[ "$image" != *@sha256:* ]] || die "VLLM_IMAGE deve ser tag local reconstruível."
  validate_deployment_config
  old_vllm_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"
  candidate="${image}-candidate-$(date +%s)"

  log "Construindo runtime candidato ${ACCELERATOR_PROFILE}..."
  if ! build_runtime_image "$candidate" 1; then
    die "Build candidato falhou; servidor atual não foi alterado."
  fi
  log "Validando runtime candidato e acesso às GPUs..."
  if ! validate_runtime_image "$candidate"; then
    docker image rm "$candidate" >/dev/null 2>&1 || true
    die "Imagem candidata falhou; servidor atual não foi alterado."
  fi
  if ! docker tag "$candidate" "$image"; then
    docker image rm "$candidate" >/dev/null 2>&1 || true
    die "Não foi possível promover a imagem candidata."
  fi

  timeout_sec="${VLLM_ENGINE_READY_TIMEOUT_S:-7200}"
  if ! compose up -d --force-recreate --pull never; then
    warn "Falha ao recriar containers com a candidata."
    [[ -z "$old_vllm_id" ]] || rollback_vllm_image "$old_vllm_id" "$timeout_sec" || warn "Rollback não pôde ser confirmado."
    docker image rm "$candidate" >/dev/null 2>&1 || true
    die "Atualização abortada durante Docker Compose."
  fi

  if wait_for_api "$timeout_sec" && "$ROOT_DIR/test-api.sh"; then
    docker image rm "$candidate" >/dev/null 2>&1 || true
    [[ -z "$old_vllm_id" ]] || docker image rm "$old_vllm_id" >/dev/null 2>&1 || true
    log "Atualização concluída e validada."
    return 0
  fi

  if [[ -n "$old_vllm_id" ]]; then
    warn "Atualização rejeitada; restaurando imagem anterior."
    rollback_vllm_image "$old_vllm_id" "$timeout_sec" || warn "Rollback não pôde ser confirmado."
  fi
  docker image rm "$candidate" >/dev/null 2>&1 || true
  die "Atualização falhou. Execute glm-manage logs e glm-manage diagnose."
}

case "${1:-status}" in
  start)
    require_docker_access "$@"; acquire_operation_lock; validate_deployment_config; require_runtime_image
    compose up -d --pull never
    ;;
  stop)
    require_docker_access "$@"; acquire_operation_lock
    compose stop
    ;;
  restart|apply)
    require_docker_access "$@"; acquire_operation_lock; validate_deployment_config; require_runtime_image
    compose up -d --force-recreate --pull never
    ;;
  status)
    require_docker_access "$@"
    compose ps
    accelerator_status
    ;;
  logs)
    require_docker_access "$@"
    compose logs -f --tail=200 vllm gateway
    ;;
  pull|update)
    require_docker_access "$@"; acquire_operation_lock; safe_update
    ;;
  wait)
    timeout_sec="${VLLM_ENGINE_READY_TIMEOUT_S:-7200}"
    log "Aguardando API (limite ${timeout_sec}s)..."
    if wait_for_api "$timeout_sec"; then
      "$ROOT_DIR/healthcheck.sh" --deep
    else
      die "API não ficou pronta; execute glm-manage logs e glm-manage diagnose."
    fi
    ;;
  test)
    "$ROOT_DIR/test-api.sh"
    ;;
  diagnose)
    require_docker_access "$@"; diagnose
    ;;
  info)
    show_info
    ;;
  key)
    printf '%s\n' "$API_KEY"
    ;;
  *)
    cat <<USAGE
Uso: glm-manage <comando>
  start stop restart apply status logs update wait test diagnose info key
USAGE
    exit 2
    ;;
esac
