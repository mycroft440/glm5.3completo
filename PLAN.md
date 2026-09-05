# Plano de implantação — GLM-5.3 completo

## Objetivo atual

Priorizar o menor custo no Azure usando **`Standard_ND96isr_MI300X_v5` Spot**, sem remover o perfil H200 já auditado.

## Baseline MI300X

- 8× MI300X 192 GB, TP=8.
- Azure image: `microsoft-dsvm:ubuntu-hpc:2404-rocm:24.04.2026072801`.
- vLLM 0.28.0 ROCm oficial fixado por digest.
- AITER habilitado para linear + MoE.
- KV `fp8_e4m3`, MTP=5.
- contexto 524.288; 32 sequências; GPU utilization 0.80.
- checkpoint fixado.
- API local por padrão, Nginx apenas `/v1/`.
- caches persistentes e snapshot `/opt/glm53-complete`.

## Concluído no código

- [x] detecção automática ROCm/NVIDIA;
- [x] Compose base + overrides isolados;
- [x] Dockerfile ROCm;
- [x] preflight MI300X/gfx942;
- [x] validação container ROCm/AITER;
- [x] status/diagnose/info profile-aware;
- [x] update/rollback usando o Compose do perfil correto;
- [x] perfil H200 preservado;
- [x] documentação Azure MI300X atualizada;
- [x] CI cobrindo os dois perfis.

## Pendente em MI300X real

- [ ] criar `Standard_ND96isr_MI300X_v5` Spot;
- [ ] usar Ubuntu HPC ROCm 24.04 recomendado;
- [ ] montar disco persistente de pelo menos 2 TiB;
- [ ] executar `sudo ./install.sh`;
- [ ] confirmar 8× gfx942 e AITER dentro do container;
- [ ] carregar ~893 GB;
- [ ] executar `glm-manage wait` e `glm-manage test`;
- [ ] testar 524k de contexto e MTP=5;
- [ ] stress de concorrência/throughput;
- [ ] simular reboot/interrupção Spot e confirmar cache persistente.

## Critério de aprovação

Produção só depois de a bateria real acima passar sem OOM, erro ROCm/RCCL/AITER, vazamento de reasoning ou quebra em tools/streaming.
