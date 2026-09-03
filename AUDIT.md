# Auditoria técnica inicial — 2026-09-03

## Escopo

Bootstrap Azure, Docker/Compose, NVIDIA Container Toolkit, vLLM 0.28.0, GLM-5.3 completo FP8, MTP, Nginx, API OpenAI, tool calling, segurança, persistência, atualização/rollback, `glm-info` e CI.

## Base confirmada

- `zai-org/GLM-5.3`: ~743B total / 39B ativos, FP8 por padrão.
- vLLM 0.28.0+.
- Perfil oficial padrão: 8× H200/H20, TP=8.
- KV cache FP8 e MTP de 5 draft tokens.
- `glm47` para tools e `glm45` para reasoning.

## Hardening incorporado desde a primeira versão

1. API atrás de Nginx e somente `/v1` exposto.
2. Bind local por padrão.
3. API key gerada automaticamente e `.env` modo 600.
4. Docker existente é reutilizado para evitar conflito com imagens Azure HPC.
5. NVIDIA Container Toolkit instalado/configurado de forma idempotente.
6. Preflight valida número de GPUs, VRAM mínima, parâmetros e espaço agregado por filesystem.
7. Requisito de armazenamento ampliado para o checkpoint de ~893 GB.
8. Caches HF e vLLM persistentes.
9. Imagem vLLM fixada em `v0.28.0` inicialmente, não `latest`.
10. Runtime testado antes do boot: CUDA, vLLM >=0.28.0 e Transformers >=5.15.0.
11. Operações normais usam `--pull never`.
12. Update faz pull deliberado, valida runtime, health, chat e tool calling e tenta rollback.
13. `MODEL_REVISION` permite pin do checkpoint depois da primeira validação real.
14. MTP é configurável e começa em 5 tokens.
15. Contexto começa em 131k, não 1M, para reduzir risco de OOM em H200.
16. `glm-info` usa resolução de symlink real e funciona globalmente.
17. Smoke test valida autenticação, `/invocations`, `/v1/models`, chat e tool calling.
18. Logs Docker têm rotação.
19. URLs remotas permanecem bloqueadas por allowlist inválida/redirect off.

## Riscos ainda dependentes de hardware

- carregamento integral dos ~893 GB FP8;
- compatibilidade real de MTP em 8×H200 com o checkpoint/revisão do dia;
- headroom de KV cache para 131k e expansão posterior;
- performance/seleção efetiva de kernels FP8/DeepGEMM;
- comportamento após reboot/Spot;
- throughput e concorrência reais.

## Estratégia pós-primeiro boot

Executar `./manage.sh diagnose`, `./manage.sh test`, registrar digest da imagem, commit do modelo, driver, vLLM/Transformers e somente então ampliar contexto/concorrência um parâmetro por vez.
