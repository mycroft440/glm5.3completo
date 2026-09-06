# Plano de implantação — GLM-5.3 completo

## Objetivo

Servidor de inferência `zai-org/GLM-5.3` por API OpenAI, com dois perfis suportados: MI300X/ROCm como opção econômica e H200/CUDA como fallback.

## Antes de criar a VM

- escolher `Standard_ND96isr_MI300X_v5` Spot para menor custo, quando houver quota/capacidade;
- usar a imagem Azure HPC ROCm recomendada;
- anexar **Managed Disk persistente >=2 TiB**;
- montar esse disco em `/var/lib/glm53-full` antes de executar `install.sh`;
- não usar o NVMe local como única cópia dos pesos.

## Concluído no código

- [x] Detecção automática MI300X/H200.
- [x] ROCm + AITER / CUDA + DeepGEMM em perfis separados.
- [x] Modelo fixado em `aca966e4e02791568aa6a4ced368624b3d897f42`.
- [x] Preservação de tuning em reinstalações no mesmo perfil.
- [x] Preflight de RAM, VRAM, drivers e storage.
- [x] Rejeição do root filesystem e Azure local/resource disk para pesos.
- [x] Validação MI300X por gfx942 + VRAM + XGMI hive comum + topologia XGMI.
- [x] Tool calling multi-turn e regressão `content=null`.
- [x] Chat low/max e streaming.
- [x] Smoke test `/v1/responses`.
- [x] Build real da imagem ROCm em CI para push em `main`.
- [x] Azure Spot watcher via Scheduled Events/`Preempt`.
- [x] Snapshot operacional em `/opt/glm53-complete`.
- [x] Update com candidata e rollback.
- [x] Timeout inicial de 4 h para novas instalações.

## Validação em MI300X real

- [ ] confirmar 8× gfx942 e um único XGMI hive;
- [ ] confirmar `Dockerfile.rocm`/AITER no host Azure real;
- [ ] baixar e carregar o checkpoint sem OOM;
- [ ] `glm-manage wait`;
- [ ] `glm-manage test` completo, incluindo `/v1/responses`;
- [ ] stress prolongado em TP8/XGMI;
- [ ] medir memória e ajustar contexto/sequências sem que reinstalação apague tuning;
- [ ] reboot com Managed Disk montado por UUID/fstab;
- [ ] eviction Spot real e confirmação do `spot-preempt.log`;
- [ ] confirmar retomada sem novo download integral dos pesos.

## Validação H200

- [ ] repetir smoke/stress no perfil NVIDIA;
- [ ] observar o risco conhecido de sparse-decode/FlashMLA do vLLM 0.28.0;
- [ ] manter `MAX_NUM_BATCHED_TOKENS=8192` até runtime estável com fix compilado.

## GitHub

Fora do código: habilitar branch protection na `main` e tornar `GLM 5.3 complete server CI` obrigatório.
