# Auditoria técnica — GLM-5.3 completo

Última rodada: 2026-09-03. Esta revisão foi feita deliberadamente como auditoria de código de terceiros, procurando motivos para rejeitar a implantação.

## Base confirmada

- GLM-5.3: ~743B parâmetros totais / 39B ativos, checkpoint FP8 ~893 GB.
- Perfil single-node: 8× H200/H20, TP=8.
- KV FP8, MTP=5, `glm47` para tools, `glm45` para reasoning.
- DeepGEMM requerido para o caminho FP8 de desempenho.
- Contexto inicial deste projeto: 131.072 tokens; lote inicial 8.192.

## Problemas encontrados e corrigidos nesta rodada

1. **Rollback não era realmente transacional.** Sob `set -e`, falha no `docker compose up` encerrava `safe_update` antes do rollback. O `up` agora está dentro do fluxo controlado e falha entra explicitamente no rollback.
2. **Checkpoint mutável (`MODEL_REVISION=main`).** Fixado em `187fb9fff6319062325ff825627ef6db084d9bc6`; preflight rejeita revisão não-SHA.
3. **Tags mutáveis de vLLM/Nginx.** Bases fixadas por digest SHA256.
4. **Workaround `content=null` dependia do cliente.** Runtime derivado agora normaliza no servidor `assistant.content=None + tool_calls` para `""`.
5. **Flags antigas de thinking podiam contaminar `content`.** Runtime GLM-only rejeita `enable_thinking`/`thinking`; smoke test também detecta `<think>` vazando.
6. **Tool smoke test parava na primeira chamada.** Agora executa ciclo completo `tool_calls -> role=tool -> resposta final` e envia deliberadamente `assistant.content=null` no segundo turno.
7. **Chat smoke test aceitava qualquer string.** Agora exige tokens sentinela exatos e testa `reasoning_effort=low` e `max`.
8. **Streaming não era testado.** Agora exige SSE `data:`, `[DONE]`, token esperado e ausência de tags de reasoning em `delta.content`.
9. **Healthcheck só provava `/v1/models`.** `--deep` faz inferência real; `glm-manage wait` e rollback usam essa verificação profunda.
10. **Cache JIT DeepGEMM era efêmero.** Persistido em volume próprio.
11. **Instalador DeepGEMM podia misturar submódulos.** Depois do checkout fixado executa `git submodule sync/update --recursive --force`.
12. **Clone Git era dependência de produção.** Instalador cria snapshot operacional em `/opt/glm53-complete`, recria o gateway a partir dali e cria launchers globais independentes do clone.
13. **Operações concorrentes não tinham lock.** Instalação e comandos mutáveis usam `flock` em `/var/lock/glm53-complete.lock`.
14. **Preflight aceitava hardware apenas por VRAM.** Agora exige exatamente 8 H200 homogêneas por default, RAM mínima, NVLink/NVSwitch e Fabric Manager ativo.
15. **Estudo da imagem Azure estava desatualizado.** Perfil recomendado atualizado para `microsoft-dsvm:ubuntu-hpc:2404:24.04.2026072901` (R580/CUDA13).
16. **Imagens antigas podiam se acumular em updates.** Após update validado, o fluxo tenta liberar a imagem anterior sem remover imagens ainda referenciadas.
17. **CI era majoritariamente estática.** Passou a incluir self-test do patch GLM, verificação de pins, `docker buildx build --check`, snapshot/launchers, Compose, cobertura dos novos smoke tests e Nginx por digest.
18. **Reserva de disco não incluía DeepGEMM JIT.** Mínimo agregado padrão no mesmo filesystem passou de 1.330 para 1.350 GiB.

## Decisão consciente: OOM FlashMLA

A correção upstream vLLM #53755 troca a revisão do FlashMLA usada **durante a compilação**. A imagem vLLM 0.28.0 já contém os binários/extensões compilados. Portanto não foi aplicado um “backport” superficial por arquivo, pois isso criaria falsa segurança.

Até usar uma imagem/release estável que contenha a correção compilada, o projeto conserva `MAX_NUM_BATCHED_TOKENS=8192` e exige teste prolongado em H200. Esse risco é conhecido, documentado e não escondido.

## Pontos que a CI consegue provar

- sintaxe Bash e ShellCheck;
- self-test determinístico do patch de compatibilidade GLM;
- wiring/pins do Dockerfile, modelo e Compose;
- `buildx --check` do Dockerfile;
- ausência de `privileged: true`;
- persistência de cache DeepGEMM;
- estrutura de snapshot/launchers;
- presença dos casos críticos no smoke test;
- sintaxe Nginx usando imagem fixada.

## Pontos que continuam dependendo de 8×H200 real

- build completo do DeepGEMM/CUDA no host alvo;
- download/carregamento integral do checkpoint;
- estabilidade de KV/workspaces e MTP;
- stress prolongado do sparse-decode em vLLM 0.28.0;
- throughput/latência/concorrência;
- execução real de low/max reasoning, multi-turn tools e streaming;
- reboot/Spot e reaproveitamento dos três caches.

## Configuração administrativa ainda externa ao código

A branch `main` deve ter proteção/status check obrigatório no GitHub. Isso não pode ser garantido por um arquivo dentro do repositório e deve ser verificado nas configurações do próprio GitHub. Não classificar o repositório como protegido sem confirmar esse estado.

## Critério de aprovação

O repositório está apto para **primeira validação séria em 8×H200** quando a CI final estiver verde. “Produção comprovada” continua condicionado ao teste real de hardware e stress, especialmente pelo risco upstream FlashMLA ainda não compilado no vLLM 0.28.0.
