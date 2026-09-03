#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

if [[ "${EUID}" -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi
cd "$ROOT_DIR"
OWNER_USER="${SUDO_USER:-root}"
OWNER_GROUP="$(id -gn "$OWNER_USER")"
COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-v5.5.0}"
INSTALL_DIR="${GLM_INSTALL_DIR:-/opt/glm53-complete}"
LOCK_FILE="/var/lock/glm53-complete.lock"

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg jq openssl rsync util-linux
install -m 0660 /dev/null "$LOCK_FILE"
exec 9>"$LOCK_FILE"
flock -n 9 || die "Outra instalação/atualização GLM-5.3 já está em execução."

[[ -r /etc/os-release ]] || die "Não foi possível identificar o sistema operacional."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "O instalador automático suporta Ubuntu. Recomendado: Azure Ubuntu HPC 24.04 A100+."
command -v nvidia-smi >/dev/null 2>&1 || die "Driver NVIDIA ausente. Use a imagem Azure Ubuntu HPC A100+ recomendada."

install_docker_ce() {
  local pkg
  log "Docker não encontrado; instalando Docker Engine oficial..."
  for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do apt-get remove -y "$pkg" >/dev/null 2>&1 || true; done
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_compose_fallback() {
  local arch asset base tmpdir expected actual
  case "$(uname -m)" in x86_64|amd64) arch="x86_64" ;; aarch64|arm64) arch="aarch64" ;; *) die "Arquitetura não suportada: $(uname -m)" ;; esac
  asset="docker-compose-linux-${arch}"; base="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}"; tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' RETURN
  curl -fsSL "${base}/${asset}" -o "${tmpdir}/${asset}"
  curl -fsSL "${base}/${asset}.sha256" -o "${tmpdir}/${asset}.sha256"
  expected="$(awk '{print $1}' "${tmpdir}/${asset}.sha256")"; actual="$(sha256sum "${tmpdir}/${asset}" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || die "Checksum do Docker Compose não confere."
  install -m 0755 -d /usr/local/lib/docker/cli-plugins
  install -m 0755 "${tmpdir}/${asset}" /usr/local/lib/docker/cli-plugins/docker-compose
  rm -rf "$tmpdir"; trap - RETURN
}

if ! command -v docker >/dev/null 2>&1; then install_docker_ce; fi
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-v2 >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || install_compose_fallback
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose não está funcional."
systemctl enable --now docker

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "Instalando NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
fi
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

if [[ ! -f .env ]]; then cp .env.example .env; log "Arquivo .env criado."; fi

ensure_env_key() {
  local key="$1" value="$2"
  if ! grep -qE "^${key}=" .env; then
    printf '%s=%s\n' "$key" "$value" >> .env
    log "Configuração ${key} adicionada ao .env existente."
  fi
}
replace_env_exact() {
  local key="$1" old="$2" new="$3" current
  current="$(grep -E "^${key}=" .env | head -n1 | cut -d= -f2- || true)"
  if [[ "$current" == "$old" ]]; then
    sed -i "s#^${key}=.*#${key}=${new}#" .env
    log "${key} migrada para valor fixado/auditado."
  fi
}

# Migra instalações anteriores sem apagar preferências customizadas.
ensure_env_key VLLM_BASE_IMAGE "vllm/vllm-openai@sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635"
ensure_env_key NGINX_IMAGE "nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de"
ensure_env_key VLLM_SOURCE_REF "2cf0a6915ce544dc493a0990f2ea38d81601128a"
ensure_env_key DEEPGEMM_REF "8b1392b978f5a03c828dd1711090d7fb50958b8a"
ensure_env_key VLLM_ENABLE_CUDA_COMPATIBILITY "auto"
ensure_env_key MODEL_REVISION "187fb9fff6319062325ff825627ef6db084d9bc6"
ensure_env_key STRICT_GPU_COUNT "1"
ensure_env_key EXPECTED_GPU_NAME_REGEX "H200"
ensure_env_key MIN_HOST_RAM_GIB "1400"
ensure_env_key REQUIRE_FABRIC_MANAGER "1"
ensure_env_key MAX_NUM_BATCHED_TOKENS "8192"
ensure_env_key DEEPGEMM_CACHE_DIR "/var/lib/glm53-full/deepgemm-cache"
ensure_env_key MIN_FREE_DISK_GIB "1200"
ensure_env_key MIN_DOCKER_FREE_DISK_GIB "100"
ensure_env_key MIN_VLLM_CACHE_FREE_DISK_GIB "30"
ensure_env_key MIN_DEEPGEMM_CACHE_FREE_DISK_GIB "20"
replace_env_exact VLLM_BASE_IMAGE "vllm/vllm-openai:v0.28.0" "vllm/vllm-openai@sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635"
replace_env_exact MODEL_REVISION "main" "187fb9fff6319062325ff825627ef6db084d9bc6"
replace_env_exact VLLM_IMAGE "vllm/vllm-openai:v0.28.0" "glm53-complete-vllm:0.28.0-deepgemm"

CURRENT_KEY="$(grep -E '^API_KEY=' .env | head -n1 | cut -d= -f2- || true)"
if [[ -z "$CURRENT_KEY" || "$CURRENT_KEY" == "CHANGE_ME" ]]; then
  GENERATED_KEY="$(openssl rand -hex 32)"
  if grep -q '^API_KEY=' .env; then sed -i "s/^API_KEY=.*/API_KEY=${GENERATED_KEY}/" .env; else printf '\nAPI_KEY=%s\n' "$GENERATED_KEY" >> .env; fi
  log "API key segura gerada automaticamente."
fi

CUDA_COMPAT_VALUE="$(grep -E '^VLLM_ENABLE_CUDA_COMPATIBILITY=' .env | head -n1 | cut -d= -f2- || true)"
if [[ "$CUDA_COMPAT_VALUE" == "auto" ]]; then
  DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')"
  DRIVER_MAJOR="${DRIVER_VERSION%%.*}"
  if [[ "$DRIVER_MAJOR" =~ ^[0-9]+$ ]] && (( DRIVER_MAJOR < 580 )); then
    CUDA_COMPAT_VALUE=1
    log "Driver ${DRIVER_VERSION}: ativando CUDA forward compatibility."
  else
    CUDA_COMPAT_VALUE=0
    log "Driver ${DRIVER_VERSION}: forward compatibility extra não é necessária."
  fi
  sed -i "s/^VLLM_ENABLE_CUDA_COMPATIBILITY=.*/VLLM_ENABLE_CUDA_COMPATIBILITY=${CUDA_COMPAT_VALUE}/" .env
fi

chmod 600 .env; chown "$OWNER_USER:$OWNER_GROUP" .env
[[ "$OWNER_USER" == "root" ]] || usermod -aG docker "$OWNER_USER" || true
chown root:docker "$LOCK_FILE" 2>/dev/null || chown root:root "$LOCK_FILE"
chmod 0660 "$LOCK_FILE"

set -a
# shellcheck disable=SC1091
source .env
set +a
HF_CACHE_PATH="${HF_CACHE_DIR:-/var/lib/glm53-full/huggingface}"
VLLM_CACHE_PATH="${VLLM_CACHE_DIR:-/var/lib/glm53-full/vllm-cache}"
DG_CACHE_PATH="${DEEPGEMM_CACHE_DIR:-/var/lib/glm53-full/deepgemm-cache}"
mkdir -p "$HF_CACHE_PATH" "$VLLM_CACHE_PATH" "$DG_CACHE_PATH"
chown "$OWNER_USER:$OWNER_GROUP" "$HF_CACHE_PATH" "$VLLM_CACHE_PATH" "$DG_CACHE_PATH"
chmod 700 "$HF_CACHE_PATH" "$VLLM_CACHE_PATH" "$DG_CACHE_PATH"

"$ROOT_DIR/scripts/preflight.sh"
docker compose --env-file .env config >/dev/null

log "Garantindo a imagem do gateway fixada por digest..."
docker compose --env-file .env pull --policy missing gateway

if ! docker image inspect "${VLLM_IMAGE}" >/dev/null 2>&1; then
  log "Construindo runtime GLM-5.3 com DeepGEMM e patches de compatibilidade..."
  docker build \
    --build-arg "VLLM_BASE_IMAGE=${VLLM_BASE_IMAGE}" \
    --build-arg "VLLM_SOURCE_REF=${VLLM_SOURCE_REF}" \
    --build-arg "DEEPGEMM_REF=${DEEPGEMM_REF}" \
    -t "${VLLM_IMAGE}" \
    "$ROOT_DIR"
else
  log "Runtime ${VLLM_IMAGE} já existe; preservando a imagem instalada. Use glm-manage update para reconstruir deliberadamente."
fi

log "Validando CUDA, vLLM, Transformers, DeepGEMM e patches do frontend..."
docker run --rm --gpus all \
  -e "VLLM_ENABLE_CUDA_COMPATIBILITY=${VLLM_ENABLE_CUDA_COMPATIBILITY}" \
  --entrypoint python3 "${VLLM_IMAGE}" \
  -c "import sys, pathlib, vllm, torch, deep_gemm; from importlib.metadata import version; from packaging.version import Version; import vllm.entrypoints.chat_utils as cu; n=torch.cuda.device_count(); vv=Version(vllm.__version__.split('+')[0]); tv=Version(version('transformers')); src=pathlib.Path(cu.__file__).read_text(); msgs=[{'role':'assistant','content':None,'tool_calls':[{'type':'function','function':{'name':'x','arguments':'{}'}}]}]; cu._postprocess_messages(msgs); patched='GLM53_NULL_TOOL_CONTENT_PATCH' in src and msgs[0]['content']==''; print(f'vLLM {vv}; Transformers {tv}; DeepGEMM OK; frontend_patch={patched}; CUDA GPUs={n}'); sys.exit(0 if n >= ${TENSOR_PARALLEL_SIZE:-8} and vv >= Version('0.28.0') and tv >= Version('5.15.0') and patched else 1)"

log "Subindo GLM-5.3 completo..."
docker compose --env-file .env up -d --pull never

# Install an operational snapshot so deleting/moving the Git clone does not
# break future management or the Nginx bind mount.
if [[ "$ROOT_DIR" != "$INSTALL_DIR" ]]; then
  log "Instalando snapshot operacional em ${INSTALL_DIR}..."
  mkdir -p "$INSTALL_DIR"
  rsync -a --delete --exclude '.git/' --exclude '.github/' --exclude '.env' "$ROOT_DIR/" "$INSTALL_DIR/"
  if [[ "$(readlink -f .env)" != "${INSTALL_DIR}/.env" ]]; then
    install -m 0600 -o "$OWNER_USER" -g "$OWNER_GROUP" .env "$INSTALL_DIR/.env"
  fi
  chmod 0755 "$INSTALL_DIR"/install.sh "$INSTALL_DIR"/manage.sh "$INSTALL_DIR"/healthcheck.sh "$INSTALL_DIR"/test-api.sh "$INSTALL_DIR"/info "$INSTALL_DIR"/scripts/*.sh
  ln -sfn "$INSTALL_DIR/info" /usr/local/bin/glm-info
  ln -sfn "$INSTALL_DIR/manage.sh" /usr/local/bin/glm-manage
  rm -f "$ROOT_DIR/.env"
  ln -s "$INSTALL_DIR/.env" "$ROOT_DIR/.env"
  chown -h "$OWNER_USER:$OWNER_GROUP" "$ROOT_DIR/.env"

  # Recreate only the gateway from the stable snapshot so its config bind mount
  # no longer depends on the clone directory. The fixed Compose project name
  # ensures this operates on the same deployment.
  docker compose -f "$INSTALL_DIR/docker-compose.yml" --env-file "$INSTALL_DIR/.env" up -d --no-deps --force-recreate --pull never gateway
else
  ln -sfn "$ROOT_DIR/info" /usr/local/bin/glm-info
  ln -sfn "$ROOT_DIR/manage.sh" /usr/local/bin/glm-manage
fi

cat <<MSG

Instalação iniciada com sucesso.
O primeiro boot precisa baixar aproximadamente 893 GB de pesos FP8 para:
  ${HF_CACHE_PATH}

A carga do modelo continua em segundo plano. Para acompanhar de qualquer pasta:
  glm-manage logs
  glm-manage wait
  glm-manage test
  glm-info

Arquivos operacionais persistentes:
  ${INSTALL_DIR}

O painel completo da API será exibido agora. O Status pode aparecer OFFLINE enquanto os pesos ainda estiverem baixando/carregando.
MSG

"$INSTALL_DIR/manage.sh" info
