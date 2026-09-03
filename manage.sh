#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_env
cd "$ROOT_DIR"
LOCK_FILE="/var/lock/glm53-complete.lock"

require_docker_access() {
  if docker info >/dev/null 2>&1; then return 0; fi
  if [[ "${EUID}" -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi
  die "Docker daemon não está acessível."
}

acquire_operation_lock() {
  command -v flock >/dev/null 2>&1 || die "flock não encontrado; execute sudo ./install.sh para reparar dependências."
  exec 9>"$LOCK_FILE" || die "Não foi possível abrir lock operacional ${LOCK_FILE}."
  flock -n 9 || die "Outra operação mutável do GLM-5.3 já está em execução."
}

validate_deployment_config() {
  "$ROOT_DIR/scripts/preflight.sh"
  docker compose --env-file .env config >/dev/null
}

require_runtime_image() {
  docker image inspect "${VLLM_IMAGE:-glm53-complete-vllm:0.28.0-deepgemm}" >/dev/null 2>&1 \
    || die "Imagem de runtime ausente. Execute sudo ./install.sh ou glm-manage update."
}

build_runtime_image() {
  local target="$1" pull_base="${2:-0}"
  local -a build_args=()
  if [[ "$pull_base" == "1" ]]; then build_args+=(--pull); fi
  docker build "${build_args[@]}" \
    --build-arg "VLLM_BASE_IMAGE=${VLLM_BASE_IMAGE}" \
    --build-arg "VLLM_SOURCE_REF=${VLLM_SOURCE_REF}" \
    --build-arg "DEEPGEMM_REF=${DEEPGEMM_REF}" \
    -t "$target" \
    "$ROOT_DIR"
}

validate_runtime_image() {
  local image="${1:-${VLLM_IMAGE:-glm53-complete-vllm:0.28.0-deepgemm}}"
  docker run --rm --gpus all \
    -e "VLLM_ENABLE_CUDA_COMPATIBILITY=${VLLM_ENABLE_CUDA_COMPATIBILITY:-0}" \
    --entrypoint python3 "$image" \
    -c "import sys, pathlib, vllm, torch, deep_gemm; from importlib.metadata import version; from packaging.version import Version; import vllm.entrypoints.chat_utils as cu; n=torch.cuda.device_count(); vv=Version(vllm.__version__.split('+')[0]); tv=Version(version('transformers')); src=pathlib.Path(cu.__file__).read_text(); msgs=[{'role':'assistant','content':None,'tool_calls':[{'type':'function','function':{'name':'x','arguments':'{}'}}]}]; cu._postprocess_messages(msgs); patched='GLM53_NULL_TOOL_CONTENT_PATCH' in src and msgs[0]['content']==''; print(f'vLLM {vv}; Transformers {tv}; DeepGEMM OK; frontend_patch={patched}; CUDA GPUs={n}'); sys.exit(0 if n >= ${TENSOR_PARALLEL_SIZE:-8} and vv >= Version('0.28.0') and tv >= Version('5.15.0') and patched else 1)"
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

diagnose() {
  printf '%s\n' "=== Sistema ==="
  if [[ -r /etc/os-release ]]; then grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release || true; fi
  uname -srmo || true
  awk '/^MemTotal:/ {printf "RAM total: %.1f GiB\n", $2/1024/1024}' /proc/meminfo || true

  printf '\n%s\n' "=== NVIDIA ==="
  nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu --format=csv || true
  printf '\n%s\n' "--- Topologia ---"
  nvidia-smi topo -m || true
  if systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^nvidia-fabricmanager\.service'; then
    printf '\nFabric Manager: '
    systemctl is-active nvidia-fabricmanager.service 2>/dev/null || true
  fi

  printf '\n%s\n' "=== Docker ==="
  docker --version || true
  docker compose version || true
  docker info --format 'DockerRootDir={{.DockerRootDir}}' 2>/dev/null || true

  printf '\n%s\n' "=== Imagens ==="
  printf 'Base: %s\nRuntime: %s\nGateway: %s\n' "${VLLM_BASE_IMAGE}" "${VLLM_IMAGE}" "${NGINX_IMAGE}"
  docker image inspect "${VLLM_IMAGE}" --format 'Id={{.Id}} {{range .RepoDigests}}Digest={{.}} {{end}}' 2>/dev/null || true

  printf '\n%s\n' "=== Modelo configurado ==="
  printf 'MODEL_ID=%s\nMODEL_REVISION=%s\nMAX_MODEL_LEN=%s\nMAX_NUM_BATCHED_TOKENS=%s\nKV_CACHE_DTYPE=%s\nCUDA_COMPAT=%s\nDEEPGEMM_REF=%s\nDEEPGEMM_CACHE=%s\n' \
    "${MODEL_ID}" "${MODEL_REVISION}" "${MAX_MODEL_LEN:-131072}" "${MAX_NUM_BATCHED_TOKENS:-8192}" \
    "${KV_CACHE_DTYPE:-fp8}" "${VLLM_ENABLE_CUDA_COMPATIBILITY:-0}" "${DEEPGEMM_REF}" \
    "${DEEPGEMM_CACHE_DIR:-/var/lib/glm53-full/deepgemm-cache}"

  printf '\n%s\n' "=== Containers ==="
  docker compose --env-file .env ps || true
  if docker compose --env-file .env ps --services --status running | grep -qx vllm; then
    printf '\n%s\n' "=== Runtime ==="
    docker exec glm53-full-vllm python3 -c \
      "import pathlib, vllm, deep_gemm; from importlib.metadata import version; import vllm.entrypoints.chat_utils as cu; print('vLLM', vllm.__version__); print('Transformers', version('transformers')); print('DeepGEMM', deep_gemm.__file__); print('Agent patch', 'GLM53_NULL_TOOL_CONTENT_PATCH' in pathlib.Path(cu.__file__).read_text())" \
      2>/dev/null || true
  fi
}

show_info() {
  local origin status gpu_count gpu_names host_ip remote_url
  origin="$(api_origin)"; status="OFFLINE"
  if curl -fsS --max-time 4 -H "Authorization: Bearer ${API_KEY}" "${origin}/v1/models" >/dev/null 2>&1; then status="ONLINE"; fi
  gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ' || true)"
  gpu_names="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u | paste -sd ',' - | sed 's/,/, /g' || true)"
  host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -z "$host_ip" ]]; then host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"; fi
  case "${BIND_ADDRESS:-127.0.0.1}" in
    127.0.0.1|localhost) remote_url="DESATIVADO (API somente local)" ;;
    0.0.0.0) if [[ -n "$host_ip" ]]; then remote_url="http://${host_ip}:${API_PORT:-8000}/v1"; else remote_url="http://IP_DA_VM:${API_PORT:-8000}/v1"; fi ;;
    *) remote_url="http://${BIND_ADDRESS}:${API_PORT:-8000}/v1" ;;
  esac
  cat <<INFO
============================================================
 GLM-5.3 COMPLETO — INFORMAÇÕES DA API
============================================================
Status:             ${status}
Modelo:             ${SERVED_MODEL_NAME:-glm-5.3}
Checkpoint:         ${MODEL_ID:-zai-org/GLM-5.3}
Revisão modelo:     ${MODEL_REVISION}
Base URL local:     ${origin}/v1
Acesso remoto:      ${remote_url}
Bind:               ${BIND_ADDRESS:-127.0.0.1}
Porta:              ${API_PORT:-8000}
API key:            ${API_KEY}
Contexto inicial:   ${MAX_MODEL_LEN:-131072} tokens
Tensor Parallel:    ${TENSOR_PARALLEL_SIZE:-8}
KV cache:           ${KV_CACHE_DTYPE:-fp8}
MTP draft tokens:   ${MTP_SPECULATIVE_TOKENS:-5}
Max sequências:     ${MAX_NUM_SEQS:-8}
Lote máx. tokens:   ${MAX_NUM_BATCHED_TOKENS:-8192}
Imagem base vLLM:   ${VLLM_BASE_IMAGE}
Imagem runtime:     ${VLLM_IMAGE}
Imagem Nginx:       ${NGINX_IMAGE}
DeepGEMM ref:       ${DEEPGEMM_REF}
CUDA compat:        ${VLLM_ENABLE_CUDA_COMPATIBILITY:-0}
GPUs detectadas:    ${gpu_count:-0}
Modelo(s) de GPU:   ${gpu_names:-indisponível}
Cache HuggingFace:  ${HF_CACHE_DIR:-/var/lib/glm53-full/huggingface}
Cache vLLM:         ${VLLM_CACHE_DIR:-/var/lib/glm53-full/vllm-cache}
Cache DeepGEMM:     ${DEEPGEMM_CACHE_DIR:-/var/lib/glm53-full/deepgemm-cache}
Diretório runtime:  ${ROOT_DIR}
Mídia remota:       ${ALLOWED_MEDIA_DOMAIN:-bloqueada}

PARA USAR A API
---------------
Base URL: ${origin}/v1
Model:    ${SERVED_MODEL_NAME:-glm-5.3}
Header:   Authorization: Bearer <API_KEY_ACIMA>

Teste:
  export GLM_BASE_URL='${origin}/v1'
  export GLM_API_KEY='<API_KEY_ACIMA>'
  curl "$GLM_BASE_URL/models" -H "Authorization: Bearer $GLM_API_KEY"

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
  if [[ "${BIND_ADDRESS:-127.0.0.1}" == "127.0.0.1" ]]; then warn "A API está somente local. Para agentes remotos, veja SECURITY.md."; fi
}

rollback_vllm_image() {
  local old_vllm_id="$1" timeout_sec="${2:-${VLLM_ENGINE_READY_TIMEOUT_S:-7200}}"
  [[ -n "$old_vllm_id" ]] || return 1
  docker tag "$old_vllm_id" "${VLLM_IMAGE}" || return 1
  docker compose --env-file .env up -d --force-recreate --pull never || return 1
  if ! wait_for_api "$timeout_sec"; then
    warn "A imagem anterior foi restaurada, mas a API não voltou dentro do limite."
    return 1
  fi
  "$ROOT_DIR/healthcheck.sh" --deep >/dev/null 2>&1 || return 1
  return 0
}

safe_update() {
  local image="${VLLM_IMAGE}" old_vllm_id="" candidate timeout_sec
  [[ "$image" != *@sha256:* ]] || die "VLLM_IMAGE deve ser uma tag local reconstruível, não um digest."
  validate_deployment_config
  old_vllm_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"
  candidate="${image}-candidate-$(date +%s)"

  log "Construindo runtime candidato a partir da base fixada ${VLLM_BASE_IMAGE}..."
  if ! build_runtime_image "$candidate" 1; then die "Build candidato falhou; servidor atual não foi alterado."; fi
  log "Validando CUDA/vLLM/Transformers/DeepGEMM/frontend antes da troca..."
  if ! validate_runtime_image "$candidate"; then
    docker image rm "$candidate" >/dev/null 2>&1 || true
    die "Imagem candidata falhou na validação; servidor atual não foi alterado."
  fi

  if ! docker tag "$candidate" "$image"; then
    docker image rm "$candidate" >/dev/null 2>&1 || true
    die "Não foi possível promover a imagem candidata."
  fi

  timeout_sec="${VLLM_ENGINE_READY_TIMEOUT_S:-7200}"
  if ! docker compose --env-file .env up -d --force-recreate --pull never; then
    warn "Falha ao recriar containers com a candidata."
    if [[ -n "$old_vllm_id" ]]; then rollback_vllm_image "$old_vllm_id" "$timeout_sec" || warn "Rollback não pôde ser confirmado."; fi
    docker image rm "$candidate" >/dev/null 2>&1 || true
    die "Atualização abortada durante docker compose up."
  fi

  if wait_for_api "$timeout_sec" && "$ROOT_DIR/test-api.sh"; then
    docker image rm "$candidate" >/dev/null 2>&1 || true
    if [[ -n "$old_vllm_id" ]]; then docker image rm "$old_vllm_id" >/dev/null 2>&1 || true; fi
    log "Atualização concluída, validada e imagem antiga liberada quando possível."
    return 0
  fi

  if [[ -n "$old_vllm_id" ]]; then
    warn "Atualização rejeitada; restaurando imagem anterior."
    rollback_vllm_image "$old_vllm_id" "$timeout_sec" || warn "Rollback executado, mas recuperação não pôde ser confirmada."
  else
    warn "Não havia imagem anterior para rollback automático."
  fi
  docker image rm "$candidate" >/dev/null 2>&1 || true
  die "Atualização falhou. Execute glm-manage logs e glm-manage diagnose."
}

case "${1:-status}" in
  start)
    require_docker_access "$@"; acquire_operation_lock; validate_deployment_config; require_runtime_image
    docker compose --env-file .env up -d --pull never
    ;;
  stop)
    require_docker_access "$@"; acquire_operation_lock
    docker compose --env-file .env stop
    ;;
  restart|apply)
    require_docker_access "$@"; acquire_operation_lock; validate_deployment_config; require_runtime_image
    docker compose --env-file .env up -d --force-recreate --pull never
    ;;
  status)
    require_docker_access "$@"
    docker compose --env-file .env ps
    nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv
    ;;
  logs)
    require_docker_access "$@"
    docker compose --env-file .env logs -f --tail=200 vllm gateway
    ;;
  pull|update)
    require_docker_access "$@"; acquire_operation_lock; safe_update
    ;;
  wait)
    timeout_sec="${VLLM_ENGINE_READY_TIMEOUT_S:-7200}"
    log "Aguardando API (limite ${timeout_sec}s)..."
    if wait_for_api "$timeout_sec"; then "$ROOT_DIR/healthcheck.sh" --deep; else die "API não ficou pronta; execute glm-manage logs."; fi
    ;;
  test) "$ROOT_DIR/test-api.sh" ;;
  diagnose) require_docker_access "$@"; diagnose ;;
  info) show_info ;;
  key) printf '%s\n' "${API_KEY}" ;;
  *) printf '%s\n' "Uso: glm-manage {start|stop|restart|apply|status|logs|pull|update|wait|test|diagnose|info|key}"; exit 2 ;;
esac
