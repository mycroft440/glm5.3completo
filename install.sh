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

[[ -r /etc/os-release ]] || die "Não foi possível identificar o sistema operacional."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "O instalador automático suporta Ubuntu. Recomendado: Azure Ubuntu HPC 24.04."

log "Instalando dependências básicas..."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg jq openssl
command -v nvidia-smi >/dev/null 2>&1 || die "Driver NVIDIA ausente. Use Azure Ubuntu HPC ou instale o driver NVIDIA antes."

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
CURRENT_KEY="$(grep -E '^API_KEY=' .env | head -n1 | cut -d= -f2- || true)"
if [[ -z "$CURRENT_KEY" || "$CURRENT_KEY" == "CHANGE_ME" ]]; then
  GENERATED_KEY="$(openssl rand -hex 32)"
  if grep -q '^API_KEY=' .env; then sed -i "s/^API_KEY=.*/API_KEY=${GENERATED_KEY}/" .env; else printf '\nAPI_KEY=%s\n' "$GENERATED_KEY" >> .env; fi
  log "API key segura gerada automaticamente."
fi
chmod 600 .env; chown "$OWNER_USER:$OWNER_GROUP" .env
[[ "$OWNER_USER" == "root" ]] || usermod -aG docker "$OWNER_USER" || true
chmod 0755 "$ROOT_DIR/info"; ln -sfn "$ROOT_DIR/info" /usr/local/bin/glm-info

set -a
# shellcheck disable=SC1091
source .env
set +a
HF_CACHE_PATH="${HF_CACHE_DIR:-/var/lib/glm53-full/huggingface}"
VLLM_CACHE_PATH="${VLLM_CACHE_DIR:-/var/lib/glm53-full/vllm-cache}"
mkdir -p "$HF_CACHE_PATH" "$VLLM_CACHE_PATH"
chown "$OWNER_USER:$OWNER_GROUP" "$HF_CACHE_PATH" "$VLLM_CACHE_PATH"
chmod 700 "$HF_CACHE_PATH" "$VLLM_CACHE_PATH"

"$ROOT_DIR/scripts/preflight.sh"
docker compose --env-file .env config >/dev/null

log "Garantindo a imagem do gateway sem trocar tags já instaladas..."
docker compose --env-file .env pull --policy missing gateway

if ! docker image inspect "${VLLM_IMAGE}" >/dev/null 2>&1; then
  log "Construindo runtime GLM-5.3 com DeepGEMM fixado..."
  docker build \
    --build-arg "VLLM_BASE_IMAGE=${VLLM_BASE_IMAGE}" \
    --build-arg "VLLM_SOURCE_REF=${VLLM_SOURCE_REF}" \
    --build-arg "DEEPGEMM_REF=${DEEPGEMM_REF}" \
    -t "${VLLM_IMAGE}" \
    "$ROOT_DIR"
else
  log "Runtime ${VLLM_IMAGE} já existe; preservando a imagem validada. Use ./manage.sh update para reconstruir deliberadamente."
fi

log "Validando CUDA, vLLM, Transformers e DeepGEMM com a imagem de inferência..."
docker run --rm --gpus all \
  -e "VLLM_ENABLE_CUDA_COMPATIBILITY=${VLLM_ENABLE_CUDA_COMPATIBILITY:-1}" \
  --entrypoint python3 "${VLLM_IMAGE}" \
  -c "import sys, vllm; import torch, deep_gemm; from importlib.metadata import version; from packaging.version import Version; n=torch.cuda.device_count(); vv=Version(vllm.__version__.split('+')[0]); tv=Version(version('transformers')); print(f'vLLM {vv}; Transformers {tv}; DeepGEMM OK; CUDA GPUs={n}; {torch.cuda.get_device_name(0) if n else \"none\"}'); sys.exit(0 if n >= ${TENSOR_PARALLEL_SIZE:-8} and vv >= Version('0.28.0') and tv >= Version('5.15.0') else 1)"

log "Subindo GLM-5.3 completo..."
docker compose --env-file .env up -d --pull never

cat <<MSG

Instalação iniciada com sucesso.
O primeiro boot precisa baixar aproximadamente 893 GB de pesos FP8 para:
  ${HF_CACHE_PATH}

A carga do modelo continua em segundo plano. Para acompanhar:
  ./manage.sh logs
  ./manage.sh wait
  ./manage.sh test

O comando global abaixo pode ser usado de qualquer pasta:
  glm-info

O painel completo da API será exibido agora. Como o modelo ainda pode estar baixando/carregando, o Status pode aparecer como OFFLINE até a inicialização terminar.
MSG

"$ROOT_DIR/manage.sh" info
