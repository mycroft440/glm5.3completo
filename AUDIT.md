# Auditoria técnica — GLM-5.3 completo

Última revisão: 2026-09-03.

## Escopo

Bootstrap Azure, Ubuntu HPC, Docker/Compose, NVIDIA Container Toolkit, driver/CUDA, Fabric Manager, vLLM 0.28.0, DeepGEMM, GLM-5.3 FP8, MTP, KV cache, batching, Nginx, API OpenAI, tool calling, segurança, persistência, atualização/rollback, `glm-info`, CI e documentação técnica.

## Base técnica confirmada

- `zai-org/GLM-5.3`: ~743B parâmetros totais / 39B ativos.
- checkpoint padrão FP8, ~893 GB na classificação do recipe.
- vLLM >=0.28.0 e Transformers >=5.15.0.
- perfil NVIDIA single-node: 8×H200/H20, TP=8.
- KV cache FP8 e MTP de 5 draft tokens.
- `glm47` para tools e `glm45` para reasoning.
- contexto nativo até 1.048.576, mas 1M é associado pelo recipe ao perfil 8×B200; H200 começa conservador neste projeto.

## Problemas encontrados e corrigidos

1. A documentação anterior tratava DeepGEMM como suficientemente integrado ao stack; o recipe oficial atual diz explicitamente que **DeepGEMM é requerido para FP8** e deve ser instalado com `install_deepgemm.sh`.
2. Foi criado um `Dockerfile` derivado da imagem vLLM 0.28.0, com source ref do vLLM e commit do DeepGEMM fixados.
3. O build falha se `import deep_gemm` não funcionar; instalação e update também validam DeepGEMM com GPU antes de trocar/subir o servidor.
4. O container NVIDIA usava `privileged: true`, permissão desnecessária para o caminho oficial NVIDIA. Foi removida; permanecem GPU reservation e `ipc: host`.
5. A imagem vLLM 0.28.0 usa CUDA 13, enquanto a documentação da Azure HPC ainda lista driver R535/CUDA 12.4. O instalador agora escolhe CUDA forward compatibility automaticamente: driver <R580 liga; R580+ desliga.
6. O import de validação preserva a ordem necessária para o vLLM configurar compat libraries antes da inicialização CUDA do PyTorch.
7. Foi adicionado `MAX_NUM_BATCHED_TOKENS=8192` para limitar explicitamente workspace/batch e mitigar risco de OOM tardio do sparse-decode observado em GLM FP8/8×H200.
8. O preflight avisa caso o operador aumente o lote acima de 8192.
9. O preflight agora valida `VLLM_BASE_IMAGE`, `VLLM_IMAGE`, source ref, DeepGEMM ref, CUDA compatibility e impede que a imagem runtime use a mesma tag da imagem base.
10. Instalações com `.env` antigo são migradas automaticamente para as novas chaves sem apagar preferências existentes; o antigo runtime oficial direto é migrado para a tag local com DeepGEMM.
11. `update` não tenta mais fazer pull de uma imagem runtime local inexistente no registry. Ele constrói uma imagem candidata, valida e só depois troca o servidor.
12. O update preserva a imagem em execução enquanto constrói/testa o candidato.
13. Se health/chat/tools falharem depois da troca, o update restaura a imagem anterior e tenta confirmar que a API voltou saudável.
14. Os checks negativos do smoke test (`/v1/models` sem chave e `/invocations`) ganharam timeout explícito para não travarem indefinidamente.
15. `diagnose` ganhou topologia `nvidia-smi topo -m`, estado do Fabric Manager quando disponível e informações de base/runtime/DeepGEMM/CUDA sem revelar API key.
16. O preflight avisa quando Fabric Manager está instalado mas inativo em um nó multi-GPU.
17. `glm-info` mostra lote máximo, base/runtime, DeepGEMM ref e estado de CUDA compatibility além das informações já existentes.
18. A CI passou a verificar pins do Dockerfile, wiring de lote/CUDA, configuração GLM/MTP/KV e ausência de `privileged: true`.

## Hardening que já existia e foi preservado

- Nginx publica somente `/v1/`; `/invocations` é bloqueado.
- bind `127.0.0.1` por padrão.
- API key aleatória em `.env` modo 600.
- URLs remotas bloqueadas por allowlist inválida + redirects desligados.
- caches HF/vLLM persistentes.
- logs Docker com rotação.
- `MODEL_REVISION` configurável para pin do checkpoint.
- `start/restart/apply` não fazem pull silencioso.
- smoke test cobre autenticação, gateway, `/v1/models`, chat e tool calling nomeado.
- `glm-info` funciona por symlink global.

## Issues upstream triadas

- OOM de sparse decode em GLM FP8/H200: issue `vllm#53413`; correção `#53755` foi mesclada depois do commit do tag v0.28.0. O limite explícito de 8192 tokens/lote é uma mitigação conservadora adicional.
- Issues recentes de DCP: não afetam o perfil padrão porque DCP não está ativado.
- Issues de KV offloading: não afetam o perfil padrão porque KV offload não está ativado.
- Problemas de clientes com reasoning/tool history continuam documentados em `AGENT_COMPAT.md`.

## Pontos deliberadamente conservadores

```text
MAX_MODEL_LEN=131072
MAX_NUM_SEQS=8
MAX_NUM_BATCHED_TOKENS=8192
GPU_MEMORY_UTILIZATION=0.90
KV_CACHE_DTYPE=fp8
MTP_SPECULATIVE_TOKENS=5
```

Não foram habilitados DCP, KV offload ou outras otimizações experimentais antes do baseline real em H200.

## Riscos que permanecem dependentes de hardware

Não há análise estática que possa provar:

- que o build DeepGEMM derivado terminará corretamente com a imagem Docker efetivamente baixada na VM;
- que os ~893 GB do checkpoint carregarão sem mudança upstream incompatível;
- o headroom real de VRAM/KV/workspaces em 8×H200;
- estabilidade de MTP sob carga prolongada;
- throughput/concorrência reais;
- comportamento após reboot ou substituição de VM Spot;
- integridade/velocidade do caminho NVLink/NVSwitch/Fabric Manager da VM concreta.

Por isso o estado correto é **implantação fortemente revisada e CI-validada, mas ainda não comprovada em produção até o primeiro teste 8×H200**.

## Estratégia pós-primeiro boot

1. executar `./manage.sh diagnose`;
2. executar `./manage.sh test`;
3. aumentar carga gradualmente mantendo telemetria de VRAM;
4. testar reboot e reaproveitamento dos caches;
5. fixar `MODEL_REVISION` no commit exato do checkpoint que funcionou;
6. registrar ID/digest da base, ID da imagem derivada, driver, vLLM, Transformers e DeepGEMM;
7. só depois experimentar contexto/concorrência maiores ou otimizações adicionais.

## Fontes principais

- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://docs.vllm.ai/en/v0.28.0/deployment/docker/
- https://github.com/vllm-project/vllm/tree/v0.28.0
- https://github.com/vllm-project/vllm/issues/53413
- https://github.com/vllm-project/vllm/pull/53755
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
