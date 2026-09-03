ARG VLLM_BASE_IMAGE=vllm/vllm-openai@sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635
FROM ${VLLM_BASE_IMAGE}

USER root
ARG VLLM_SOURCE_REF=2cf0a6915ce544dc493a0990f2ea38d81601128a
ARG DEEPGEMM_REF=8b1392b978f5a03c828dd1711090d7fb50958b8a

# Apply narrow server-side guards for known GLM-5.3 agent/frontend issues.
COPY scripts/patch_vllm_agent_compat.py /tmp/patch_vllm_agent_compat.py
RUN python3 /tmp/patch_vllm_agent_compat.py --self-test \
    && python3 /tmp/patch_vllm_agent_compat.py \
    && rm -f /tmp/patch_vllm_agent_compat.py

# GLM-5.3 FP8 relies on DeepGEMM for the intended performance path.
# The upstream installer is fetched from the exact vLLM source commit. We add
# one safety line after checkout so recursive submodules are reset to the SHAs
# recorded by DEEPGEMM_REF rather than whatever branch tip was cloned first.
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
    && sed -i '/git checkout "$DEEPGEMM_GIT_REF"/a git submodule sync --recursive\ngit submodule update --init --recursive --force' /tmp/install_deepgemm.sh \
    && grep -F 'git submodule update --init --recursive --force' /tmp/install_deepgemm.sh \
    && chmod 0755 /tmp/install_deepgemm.sh \
    && /tmp/install_deepgemm.sh --ref "${DEEPGEMM_REF}" \
    && python3 -c "import deep_gemm; print('DeepGEMM import OK')" \
    && rm -f /tmp/install_deepgemm.sh \
    && rm -rf /var/lib/apt/lists/*
