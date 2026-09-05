#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/runtime.sh
source "$ROOT_DIR/scripts/runtime.sh"

if [[ "${EUID}" -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi
cd "$ROOT_DIR"

OWNER_USER="${SUDO_USER:-root}"
OWNER_GROUP="$(id -gn "$OWNER_USER")"
COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-v5.5.0}"
INSTALL_DIR="${GLM_INSTALL_DIR:-/opt/glm53-complete}"
LOCK_FILE="/var/lock/glm53-complete.lock"

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg jq openssl rsync util-linux pciutils
touch "$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
exec 9>"$LOCK_FILE"
flock -n 9 || die "Outra instalação/atualização GLM-5.3 já está em execução."

[[ -r /etc/os-release ]] || die "Não foi possível identificar o sistema operacional."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "O instalador automático suporta Ubuntu."

if [[ ! -f .env ]]; then
  cp .env.example .env
  log "Arquivo .env criado."
fi

CURRENT_KEY="$(grep -E '^API_KEY=' .env | head -n1 | cut -d= -f2- || true)"
if [[ -z "$CURRENT_KEY" || "$CURRENT_KEY" == "CHANGE_ME" ]]; then
  GENERATED_KEY="$(openssl rand -hex 32)"
  if grep -q '^API_KEY=' .env; then
    sed -i "s/^API_KEY=.*/API_KEY=${GENERATED_KEY}/" .env
  else
    printf '\nAPI_KEY=%s\n' "$GENERATED_KEY" >> .env
  fi
  log "API key segura gerada automaticamente."
fi

if ! grep -q '^ACCELERATOR_PROFILE=' .env; then
  printf 'ACCELERATOR_PROFILE=auto\n' >> .env
fi

PROFILE="$("$ROOT_DIR/scripts/apply-profile.sh")"
log "Perfil detectado/selecionado: ${PROFILE}."

chmod 600 .env
chown "$OWNER_USER:$OWNER_GROUP" .env

set -a
# shellcheck disable=SC1091
source .env
set +a
require_resolved_profile

install_docker_ce() {
  local pkg
  log "Docker não encontrado; instalando Docker Engine oficial..."
  for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    apt-get remove -y "$pkg" >/dev/null 2>&1 || true
  done
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
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "Arquitetura não suportada: $(uname -m)" ;;
  esac
  asset="docker-compose-linux-${arch}"
  base="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' RETURN
  curl -fsSL "${base}/${asset}" -o "${tmpdir}/${asset}"
  curl -fsSL "${base}/${asset}.sha256" -o "${tmpdir}/${asset}.sha256"
  expected="$(awk '{print $1}' "${tmpdir}/${asset}.sha256")"
  actual="$(sha256sum "${tmpdir}/${asset}" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || die "Checksum do Docker Compose não confere."
  install -m 0755 -d /usr/local/lib/docker/cli-plugins
  install -m 0755 "${tmpdir}/${asset}" /usr/local/lib/docker/cli-plugins/docker-compose
  rm -rf "$tmpdir"
  trap - RETURN
}

if ! command -v docker >/dev/null 2>&1; then install_docker_ce; fi
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-v2 >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || install_compose_fallback
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose não está funcional."
systemctl enable --now docker

if [[ "$ACCELERATOR_PROFILE" == "nvidia" ]]; then
  command -v nvidia-smi >/dev/null 2>&1 || die "Driver NVIDIA ausente."
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    log "Instalando NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
  fi
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
else
  [[ -e /dev/kfd && -d /dev/dri ]] || die "Dispositivos ROCm ausentes. Use a imagem Azure HPC MI300X ROCm."
  command -v rocminfo >/dev/null 2>&1 || die "rocminfo ausente. Use microsoft-dsvm:ubuntu-hpc:2404-rocm."
fi

[[ "$OWNER_USER" == "root" ]] || usermod -aG docker "$OWNER_USER" || true
if getent group docker >/dev/null 2>&1; then
  chown root:docker "$LOCK_FILE"
  chmod 0660 "$LOCK_FILE"
fi

HF_CACHE_PATH="${HF_CACHE_DIR:-/var/lib/glm53-full/huggingface}"
VLLM_CACHE_PATH="${VLLM_CACHE_DIR:-/var/lib/glm53-full/vllm-cache}"
mkdir -p "$HF_CACHE_PATH" "$VLLM_CACHE_PATH"
chown "$OWNER_USER:$OWNER_GROUP" "$HF_CACHE_PATH" "$VLLM_CACHE_PATH"
chmod 700 "$HF_CACHE_PATH" "$VLLM_CACHE_PATH"

if [[ "$ACCELERATOR_PROFILE" == "nvidia" ]]; then
  DG_CACHE_PATH="${DEEPGEMM_CACHE_DIR:-/var/lib/glm53-full/deepgemm-cache}"
  mkdir -p "$DG_CACHE_PATH"
  chown "$OWNER_USER:$OWNER_GROUP" "$DG_CACHE_PATH"
  chmod 700 "$DG_CACHE_PATH"
fi

"$ROOT_DIR/scripts/preflight.sh"
compose config >/dev/null

log "Garantindo a imagem do gateway fixada por digest..."
compose pull --policy missing gateway

if ! docker image inspect "${VLLM_IMAGE}" >/dev/null 2>&1; then
  log "Construindo runtime ${ACCELERATOR_PROFILE} do GLM-5.3..."
  build_runtime_image "${VLLM_IMAGE}" 1
else
  log "Runtime ${VLLM_IMAGE} já existe; use glm-manage update para reconstruir deliberadamente."
fi

log "Validando o runtime e acesso às ${EXPECTED_GPUS:-8} GPUs..."
validate_runtime_image "${VLLM_IMAGE}"

log "Subindo GLM-5.3 completo (${ACCELERATOR_PROFILE})..."
compose up -d --pull never

if [[ "$ROOT_DIR" != "$INSTALL_DIR" ]]; then
  log "Instalando snapshot operacional em ${INSTALL_DIR}..."
  mkdir -p "$INSTALL_DIR"
  rsync -a --delete --exclude '.git/' --exclude '.github/' --exclude '.env' "$ROOT_DIR/" "$INSTALL_DIR/"
  install -m 0600 -o "$OWNER_USER" -g "$OWNER_GROUP" .env "$INSTALL_DIR/.env"
  chmod 0755 "$INSTALL_DIR"/install.sh "$INSTALL_DIR"/manage.sh "$INSTALL_DIR"/healthcheck.sh \
    "$INSTALL_DIR"/test-api.sh "$INSTALL_DIR"/info "$INSTALL_DIR"/scripts/*.sh
  ln -sfn "$INSTALL_DIR/info" /usr/local/bin/glm-info
  cat >/usr/local/bin/glm-manage <<MANAGE_WRAPPER
#!/usr/bin/env bash
exec "$INSTALL_DIR/manage.sh" "\$@"
MANAGE_WRAPPER
  chmod 0755 /usr/local/bin/glm-manage

  rm -f "$ROOT_DIR/.env"
  ln -s "$INSTALL_DIR/.env" "$ROOT_DIR/.env"
  chown -h "$OWNER_USER:$OWNER_GROUP" "$ROOT_DIR/.env"

  (
    cd "$INSTALL_DIR"
    # shellcheck source=scripts/lib.sh
    source "$INSTALL_DIR/scripts/lib.sh"
    load_env
    compose up -d --no-deps --force-recreate --pull never gateway
  )
else
  ln -sfn "$ROOT_DIR/info" /usr/local/bin/glm-info
  cat >/usr/local/bin/glm-manage <<MANAGE_WRAPPER
#!/usr/bin/env bash
exec "$ROOT_DIR/manage.sh" "\$@"
MANAGE_WRAPPER
  chmod 0755 /usr/local/bin/glm-manage
fi

cat <<MSG

Instalação iniciada com sucesso.
Perfil: ${ACCELERATOR_PROFILE}
VM recomendada para menor custo: Standard_ND96isr_MI300X_v5 (Spot)
Imagem Azure recomendada: microsoft-dsvm:ubuntu-hpc:2404-rocm:24.04.2026072801

O primeiro boot precisa baixar aproximadamente 893 GB de pesos FP8.
A carga do modelo continua em segundo plano. Comandos:
  glm-manage logs
  glm-manage wait
  glm-manage test
  glm-info

Arquivos operacionais persistentes:
  ${INSTALL_DIR}

O painel completo será exibido agora. Status pode aparecer OFFLINE enquanto os pesos carregam.
MSG

"$INSTALL_DIR/manage.sh" info
