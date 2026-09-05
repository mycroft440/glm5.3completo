# Pesquisa técnica — GLM-5.3 completo

Data da revisão: 2026-09-05.

## Modelo

O `zai-org/GLM-5.3` completo é um MoE de aproximadamente **743B parâmetros totais / 39B ativos**, com checkpoint FP8 em torno de **893 GB** e contexto nativo de até 1.048.576 tokens.

Fonte principal: https://recipes.vllm.ai/zai-org/GLM-5.3

## AMD MI300X: perfil econômico recomendado

O recipe atual do vLLM publica explicitamente um perfil FP8 para **AMD MI300X/MI355X** com AITER, KV `fp8_e4m3`, TP=8, MTP=5, GPU utilization 0.80, contexto 524.288, 32 sequências, `--linear-backend aiter` e `--moe-backend aiter`.

O repositório reproduz esse perfil e deixa `MAX_NUM_BATCHED_TOKENS` no default do vLLM no ROCm, em vez de carregar para a AMD a mitigação específica usada no H200.

## Azure MI300X

VM alvo: `Standard_ND96isr_MI300X_v5`.

Microsoft publica 96 vCPUs, 1.850 GiB de RAM e 8× MI300X com aproximadamente 1.535 GB de memória aceleradora total.

Fonte: https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/ndmi300xv5-series

Imagem Azure HPC ROCm recomendada nesta revisão:

```text
microsoft-dsvm:ubuntu-hpc:2404-rocm:24.04.2026072801
```

A release informa ROCm 6.4.4 e RCCL 2.22.3 no host. O container oficial vLLM 0.28.0 ROCm usa ROCm 7.2.3; a matriz ROCm 7.2 lista drivers 6.4.x entre os suportados. A validação dentro do container continua obrigatória antes de subir o modelo.

Fontes:
- https://github.com/Azure/azhpc-images/releases
- https://rocm.docs.amd.com/en/docs-7.2.0/compatibility/compatibility-matrix.html

## vLLM ROCm

Imagem oficial fixada:

```text
vllm/vllm-openai-rocm@sha256:e0a3b2bd3fe7ec563916c3a5d949898d133458c18d6b2f460c906885cfb32032
```

O manifest corresponde ao tag `v0.28.0`, linux/amd64. O Dockerfile ROCm do vLLM 0.28.0 fixa AITER `v0.1.19` e inclui arquitetura `gfx942`, correspondente ao MI300X.

Fontes:
- https://hub.docker.com/r/vllm/vllm-openai-rocm/tags
- https://github.com/vllm-project/vllm/blob/v0.28.0/docker/Dockerfile.rocm_base

## Docker ROCm

A documentação oficial do vLLM usa `--group-add=video`, `--cap-add=SYS_PTRACE`, `--security-opt seccomp=unconfined`, `/dev/kfd`, `/dev/dri` e `--ipc=host`. O override ROCm replica esses requisitos sem `privileged: true`.

## NVIDIA H200 preservado

O perfil H200 continua disponível como fallback e mantém DeepGEMM, KV FP8, MTP=5, contexto 131.072 e `MAX_NUM_BATCHED_TOKENS=8192`.

## Compatibilidade de agentes

O patch server-side continua normalizando `assistant.content=null + tool_calls` e rejeitando flags legadas de thinking. Os smoke tests cobrem tool loop completo e streaming.

## Limite da pesquisa

Antes de declarar produção comprovada ainda é necessário testar em MI300X real: acesso `/dev/kfd`, 8 agentes gfx942, AITER, carregamento dos ~893 GB, MTP, 524k de contexto, tool loops, streaming, carga prolongada, Spot/restart e cache persistente.
