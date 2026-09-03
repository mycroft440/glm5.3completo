# Plano de implantação — GLM-5.3 completo

## Objetivo

Entregar somente o servidor de inferência do `zai-org/GLM-5.3`, acessível por API OpenAI. Agentes, memória e orquestração ficam fora deste repositório.

## Decisões

- base oficial: `vllm/vllm-openai:v0.28.0`;
- runtime local derivado com DeepGEMM fixado por commit;
- checkpoint nativo FP8 `zai-org/GLM-5.3`;
- Azure de referência: `Standard_ND96isr_H200_v5`, 8× H200 141 GB;
- TP=8, KV FP8, MTP=5;
- contexto inicial: 131.072 tokens;
- concorrência inicial: 8 sequências;
- lote inicial: 8.192 tokens para limitar workspace do sparse-decode;
- CUDA forward compatibility escolhida automaticamente conforme o driver;
- container NVIDIA sem modo `privileged`;
- bind local e Nginx expondo apenas `/v1`;
- caches persistentes e 2 TiB de disco recomendado;
- atualizações por imagem candidata, validação e rollback.

## Fases

- [x] Pesquisa do modelo/runtime/hardware oficial.
- [x] Arquitetura mínima de API.
- [x] Preflight de GPU, VRAM, driver, parâmetros e armazenamento.
- [x] Instalador idempotente Ubuntu/NVIDIA/Docker.
- [x] Runtime derivado com DeepGEMM instalado e pinado.
- [x] Compatibilidade CUDA automática para driver antigo de datacenter.
- [x] Compose vLLM + gateway sem `privileged`.
- [x] Limite conservador de batch para reduzir risco de OOM do sparse-decode.
- [x] `glm-info`, healthcheck e diagnóstico/topologia.
- [x] Smoke test com autenticação, chat e tool calling.
- [x] Update transacional com imagem candidata e rollback verificado.
- [x] Migração de `.env` criado por versões anteriores.
- [x] CI estática e regressão do symlink global.
- [x] Segunda auditoria completa de código e pesquisa.
- [ ] Build real do runtime DeepGEMM na VM H200.
- [ ] Teste real com checkpoint em 8× H200.
- [ ] Teste progressivo de contexto, lote e concorrência.
- [ ] Teste de carga prolongada para detectar OOM tardio.
- [ ] Reboot/Spot com reaproveitamento dos caches.
- [ ] Fixar revisão do checkpoint e registrar IDs/digests após validação real.

## Critérios na VM real

1. 8 GPUs H200 visíveis no host e container.
2. Fabric Manager/topologia multi-GPU sem erro relevante.
3. vLLM >=0.28.0, Transformers >=5.15.0 e `import deep_gemm` válidos.
4. CUDA compatibility selecionada corretamente para o driver instalado.
5. Checkpoint FP8 carrega integralmente.
6. KV FP8 e MTP=5 inicializam sem OOM.
7. `/v1/models` exige API key e responde autenticado.
8. Chat responde corretamente.
9. Tool calling retorna schema OpenAI válido.
10. `/invocations` fica bloqueado no gateway.
11. `glm-info` funciona globalmente.
12. Lote/contexto/concorrência padrão sobrevivem a carga progressiva.
13. Update aceita uma imagem somente após runtime validation + health + smoke test.
14. Rollback realmente recupera a API quando uma atualização candidata falha.
15. Reboot retorna os containers e reutiliza caches/pesos.
16. Configuração validada fica registrada e reproduzível.
