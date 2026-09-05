# Auditoria técnica — GLM-5.3 completo

Última rodada: 2026-09-05.

## Mudança principal

O repositório deixou de ser exclusivamente H200 e passou a suportar **dois perfis isolados**:

1. `rocm` — Azure `Standard_ND96isr_MI300X_v5`, recomendado para reduzir custo;
2. `nvidia` — `Standard_ND96isr_H200_v5`, preservando o baseline anterior.

`install.sh` detecta o hardware e grava um perfil concreto no `.env`; os comandos posteriores recusam `ACCELERATOR_PROFILE=auto`.

## Controles adicionados para MI300X

- base oficial `vllm/vllm-openai-rocm:v0.28.0` fixada por digest;
- Dockerfile ROCm separado;
- validação de `torch.version.hip`, AITER e 8 GPUs dentro do container;
- preflight de `/dev/kfd`, `/dev/dri`, `rocminfo`, `rocm-smi`, 8 agentes `gfx942`, RAM e disco;
- topologia consultável via `rocm-smi --showtopo`;
- Compose ROCm seguindo os device/capability flags oficiais do vLLM;
- AITER nos backends linear e MoE;
- KV `fp8_e4m3`, 0.80 de utilização, contexto 524.288 e 32 sequências;
- MTP=5 mantido porque o recipe do GLM-5.3 completo publica esse caminho para MI300X/MI355X;
- diagnose/status/info agora são profile-aware.

## H200 preservado

DeepGEMM, Fabric Manager, NVLink/NVSwitch, CUDA compatibility e mitigação de lote 8192 continuam somente no perfil NVIDIA.

## Pontos ainda dependentes de hardware

A CI pode validar shell, Compose, Dockerfiles, pins e wiring, mas não prova ROCm/AITER em MI300X real. A aprovação final exige uma execução real do instalador e do `glm-manage test` na VM alvo, seguida de stress prolongado e teste de interrupção Spot.
