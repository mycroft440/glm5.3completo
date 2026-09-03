# Plano de implantação — GLM-5.3 completo

## Objetivo

Entregar somente o servidor de inferência `zai-org/GLM-5.3`, acessível por API OpenAI, com baseline conservador e reproduzível em uma única Azure `Standard_ND96isr_H200_v5`. Agentes, memória e orquestração ficam fora deste repositório.

## Baseline

- 8× H200 141 GB homogêneas, TP=8.
- Checkpoint FP8 fixado por commit.
- vLLM 0.28.0 base e Nginx fixados por digest.
- DeepGEMM fixado por commit e submódulos ressincronizados.
- KV FP8, MTP=5, contexto 131.072, sequências 8, lote 8.192.
- Bind local; gateway publica somente `/v1/`.
- Caches persistentes HF, vLLM e DeepGEMM JIT.
- Snapshot operacional `/opt/glm53-complete`.
- Atualizações serializadas por lock e com rollback validado por inferência.

## Concluído no código

- [x] Pesquisa modelo/runtime/hardware.
- [x] Instalador Ubuntu/Docker/NVIDIA idempotente.
- [x] Preflight fail-closed para H200, RAM, topologia, Fabric Manager e disco.
- [x] API key automática e `.env` modo 600.
- [x] Imagens/modelo fixados por digest/commit.
- [x] DeepGEMM reproduzível e cache JIT persistente.
- [x] Normalização server-side de `assistant.content=null + tool_calls`.
- [x] Rejeição de flags legadas de thinking no perfil GLM-5.3.
- [x] Smoke test low/max reasoning.
- [x] Smoke test multi-turn de tool calling.
- [x] Smoke test de streaming SSE.
- [x] Healthcheck profundo por inferência real.
- [x] Update transacional inclusive quando `docker compose up` falha.
- [x] Lock de operações mutáveis.
- [x] Snapshot em `/opt` independente do clone.
- [x] CI ampliada com self-test do patch, pins, build check, Compose e Nginx.
- [x] Risco FlashMLA/vLLM 0.28.0 documentado sem pseudo-backport.

## Pendente em hardware real

- [ ] Subir VM `Standard_ND96isr_H200_v5` com imagem HPC A100+ recomendada.
- [ ] Executar `sudo ./install.sh` do zero.
- [ ] Confirmar build DeepGEMM e patches no runtime.
- [ ] Baixar/carregar os ~893 GB sem OOM.
- [ ] Confirmar `glm-manage wait` e `glm-manage test` completos.
- [ ] Rodar stress prolongado para sparse-decode/workspaces.
- [ ] Medir headroom e aumentar contexto/concorrência um parâmetro por vez.
- [ ] Reboot e validação do reaproveitamento dos três caches.
- [ ] Testar interrupção/retomada em cenário Spot, se Spot for utilizado.
- [ ] Registrar IDs/digests/runtime/driver da execução aprovada.

## Critérios de aprovação na VM

1. Exatamente 8 H200 visíveis, NVLink/NVSwitch e Fabric Manager saudáveis.
2. vLLM >=0.28.0, Transformers >=5.15.0 e DeepGEMM importável.
3. Patch server-side `content=null` presente e validado.
4. Checkpoint fixado carrega integralmente.
5. `/v1/models` exige autenticação e `/invocations` retorna 404 no gateway.
6. Chat low/max retorna sentinelas corretas sem `<think>` em content.
7. Flags antigas de thinking são rejeitadas.
8. Tool call + tool result + resposta final funcionam com `assistant.content=null`.
9. Streaming retorna SSE completo até `[DONE]` sem vazamento de reasoning.
10. MTP=5 inicializa e permanece estável.
11. Stress prolongado não apresenta OOM tardio no perfil de lote 8192.
12. Reboot retorna o serviço sem novo download dos pesos e reutiliza caches.

## Configuração GitHub

Fora do código: habilitar proteção da `main` e tornar o workflow `GLM 5.3 complete server CI` obrigatório antes de merge/push aceito. Esse item deve ser confirmado nas configurações do repositório.
