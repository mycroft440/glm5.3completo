#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
[[ -f "$ENV_FILE" ]] || die "Arquivo .env ausente: ${ENV_FILE}"

env_get() {
  local key="$1"
  grep -E "^${key}=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true
}

env_set() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

requested="${1:-$(env_get ACCELERATOR_PROFILE)}"
requested="${requested:-auto}"
if [[ "$requested" == "auto" ]]; then
  requested="$(detect_accelerator_profile)" || die "Nenhuma GPU suportada detectada. Esperado MI300X/gfx942 ou NVIDIA H200."
fi

case "$requested" in
  rocm)
    env_set ACCELERATOR_PROFILE rocm
    env_set VLLM_BASE_IMAGE "vllm/vllm-openai-rocm@sha256:e0a3b2bd3fe7ec563916c3a5d949898d133458c18d6b2f460c906885cfb32032"
    env_set VLLM_IMAGE "glm53-complete-vllm:0.28.0-rocm-aiter"
    env_set VLLM_DOCKERFILE "Dockerfile.rocm"
    env_set EXPECTED_GPU_NAME_REGEX "MI300X"
    env_set EXPECTED_GPU_ARCH "gfx942"
    env_set MIN_GPU_MEMORY_MIB "180000"
    env_set REQUIRE_FABRIC_MANAGER "0"
    env_set VLLM_ENABLE_CUDA_COMPATIBILITY "0"
    env_set MAX_MODEL_LEN "524288"
    env_set MAX_NUM_SEQS "32"
    env_set MAX_NUM_BATCHED_TOKENS "0"
    env_set GPU_MEMORY_UTILIZATION "0.80"
    env_set KV_CACHE_DTYPE "fp8_e4m3"
    ;;
  nvidia)
    env_set ACCELERATOR_PROFILE nvidia
    env_set VLLM_BASE_IMAGE "vllm/vllm-openai@sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635"
    env_set VLLM_IMAGE "glm53-complete-vllm:0.28.0-deepgemm"
    env_set VLLM_DOCKERFILE "Dockerfile"
    env_set EXPECTED_GPU_NAME_REGEX "H200"
    env_set EXPECTED_GPU_ARCH "hopper"
    env_set MIN_GPU_MEMORY_MIB "130000"
    env_set REQUIRE_FABRIC_MANAGER "1"
    env_set MAX_MODEL_LEN "131072"
    env_set MAX_NUM_SEQS "8"
    env_set MAX_NUM_BATCHED_TOKENS "8192"
    env_set GPU_MEMORY_UTILIZATION "0.90"
    env_set KV_CACHE_DTYPE "fp8"

    cuda_mode="$(env_get VLLM_ENABLE_CUDA_COMPATIBILITY)"
    if [[ -z "$cuda_mode" || "$cuda_mode" == "auto" ]]; then
      if command -v nvidia-smi >/dev/null 2>&1; then
        driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')"
        driver_major="${driver_version%%.*}"
        if [[ "$driver_major" =~ ^[0-9]+$ ]] && (( driver_major < 580 )); then
          env_set VLLM_ENABLE_CUDA_COMPATIBILITY "1"
        else
          env_set VLLM_ENABLE_CUDA_COMPATIBILITY "0"
        fi
      else
        env_set VLLM_ENABLE_CUDA_COMPATIBILITY "0"
      fi
    fi
    ;;
  *)
    die "Perfil inválido: ${requested}. Use auto, rocm ou nvidia."
    ;;
esac

printf '%s\n' "$requested"
