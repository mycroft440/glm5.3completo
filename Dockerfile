ARG VLLM_BASE_IMAGE=vllm/vllm-openai:v0.28.0
FROM ${VLLM_BASE_IMAGE}

USER root
ARG VLLM_SOURCE_REF=2cf0a6915ce544dc493a0990f2ea38d81601128a
ARG DEEPGEMM_REF=8b1392b978f5a03c828dd1711090d7fb50958b8a

# GLM-5.3 FP8 relies on DeepGEMM for the intended performance path.
# Build it once into a derived image so container restarts stay deterministic.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        build-essential \
        cmake \
        ninja-build \
    && curl -fsSL \
        "https://raw.githubusercontent.com/vllm-project/vllm/${VLLM_SOURCE_REF}/tools/install_deepgemm.sh" \
        -o /tmp/install_deepgemm.sh \
    && chmod 0755 /tmp/install_deepgemm.sh \
    && /tmp/install_deepgemm.sh --ref "${DEEPGEMM_REF}" \
    && python3 -c "import deep_gemm; print('DeepGEMM import OK')" \
    && rm -f /tmp/install_deepgemm.sh \
    && rm -rf /var/lib/apt/lists/*
