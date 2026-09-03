# Plano de implantação — GLM-5.3 completo

## Objetivo

Entregar somente o servidor de inferência do `zai-org/GLM-5.3`, acessível por API OpenAI. Agentes, memória e orquestração ficam fora deste repositório.

## Decisões

- vLLM 0.28.0 em Docker.
- Checkpoint nativo FP8 `zai-org/GLM-5.3`.
- Azure de referência: `Standard_ND96isr_H200_v5`, 8× H200 141 GB.
- TP=8, KV FP8, MTP=5.
- Contexto inicial: 131.072 tokens; aumentar somente após medir headroom.
- Bind local e Nginx expondo apenas `/v1`.
- Caches persistentes e 2 TiB de disco recomendado.
- Atualizações somente por fluxo deliberado com smoke test e rollback.

## Fases

- [x] Pesquisa do modelo/runtime/hardware oficial.
- [x] Arquitetura mínima de API.
- [x] Preflight de GPU, VRAM, parâmetros e armazenamento.
- [x] Instalador idempotente Ubuntu/NVIDIA/Docker.
- [x] Compose vLLM + gateway.
- [x] `glm-info`, healthcheck e diagnóstico.
- [x] Smoke test com autenticação, chat e tool calling.
- [x] Update controlado com rollback.
- [x] CI estática e regressão do symlink global.
- [ ] Teste real em 8× H200.
- [ ] Teste progressivo de contexto e concorrência.
- [ ] Reboot/Spot com reaproveitamento dos caches.
- [ ] Fixar digest da imagem e revisão do checkpoint após validação real.

## Critérios na VM real

1. 8 GPUs visíveis no host e container.
2. vLLM >=0.28.0 e Transformers >=5.15.0.
3. Checkpoint FP8 carrega integralmente.
4. `/v1/models` exige API key.
5. Chat responde corretamente.
6. Tool calling retorna schema OpenAI válido.
7. MTP inicializa com 5 draft tokens.
8. `/invocations` fica bloqueado no gateway.
9. `glm-info` funciona globalmente.
10. Reboot retorna os containers sem novo download dos pesos.
