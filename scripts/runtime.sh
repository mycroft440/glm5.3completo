#!/usr/bin/env bash
set -Eeuo pipefail

build_runtime_image() {
  local target="$1" pull_base="${2:-0}"
  local -a build_args=()
  [[ "$pull_base" == "1" ]] && build_args+=(--pull)

  case "${ACCELERATOR_PROFILE:-}" in
    rocm)
      docker build "${build_args[@]}" \
        -f "${VLLM_DOCKERFILE:-Dockerfile.rocm}" \
        --build-arg "VLLM_BASE_IMAGE=${VLLM_BASE_IMAGE}" \
        -t "$target" \
        "$(project_dir)"
      ;;
    nvidia)
      docker build "${build_args[@]}" \
        -f "${VLLM_DOCKERFILE:-Dockerfile}" \
        --build-arg "VLLM_BASE_IMAGE=${VLLM_BASE_IMAGE}" \
        --build-arg "VLLM_SOURCE_REF=${VLLM_SOURCE_REF}" \
        --build-arg "DEEPGEMM_REF=${DEEPGEMM_REF}" \
        -t "$target" \
        "$(project_dir)"
      ;;
    *)
      die "Perfil não resolvido para build: ${ACCELERATOR_PROFILE:-vazio}."
      ;;
  esac
}

validate_runtime_image() {
  local image="${1:-${VLLM_IMAGE}}"
  local py_common
  py_common="import sys,pathlib,vllm,torch; from importlib.metadata import version; from packaging.version import Version; import vllm.entrypoints.chat_utils as cu; vv=Version(vllm.__version__.split('+')[0]); tv=Version(version('transformers')); src=pathlib.Path(cu.__file__).read_text(); msgs=[{'role':'assistant','content':None,'tool_calls':[{'type':'function','function':{'name':'x','arguments':'{}'}}]}]; cu._postprocess_messages(msgs); patched='GLM53_NULL_TOOL_CONTENT_PATCH' in src and msgs[0]['content']==''; n=torch.cuda.device_count();"

  case "${ACCELERATOR_PROFILE:-}" in
    rocm)
      docker run --rm \
        --device /dev/kfd \
        --device /dev/dri \
        --group-add video \
        --cap-add SYS_PTRACE \
        --security-opt seccomp=unconfined \
        --entrypoint python3 "$image" \
        -c "${py_common} import aiter; hip=torch.version.hip; names=[torch.cuda.get_device_name(i) for i in range(n)]; print(f'vLLM {vv}; Transformers {tv}; ROCm {hip}; AITER OK; frontend_patch={patched}; GPUs={n}; names={names}'); sys.exit(0 if hip and n >= ${TENSOR_PARALLEL_SIZE:-8} and vv >= Version('0.28.0') and tv >= Version('5.15.0') and patched else 1)"
      ;;
    nvidia)
      docker run --rm --gpus all \
        -e "VLLM_ENABLE_CUDA_COMPATIBILITY=${VLLM_ENABLE_CUDA_COMPATIBILITY:-0}" \
        --entrypoint python3 "$image" \
        -c "${py_common} import deep_gemm; print(f'vLLM {vv}; Transformers {tv}; DeepGEMM OK; frontend_patch={patched}; CUDA GPUs={n}'); sys.exit(0 if n >= ${TENSOR_PARALLEL_SIZE:-8} and vv >= Version('0.28.0') and tv >= Version('5.15.0') and patched else 1)"
      ;;
    *)
      die "Perfil não resolvido para validação: ${ACCELERATOR_PROFILE:-vazio}."
      ;;
  esac
}
