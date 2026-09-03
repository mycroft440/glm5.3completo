# Pesquisa técnica — GLM-5.3 completo

Data da revisão: 2026-09-03.

## Modelo e perfil oficial

O GLM-5.3 completo é um MoE de aproximadamente **743B parâmetros totais / 39B ativos**, com janela nativa de **1.048.576 tokens**. O checkpoint padrão `zai-org/GLM-5.3` é FP8 e o recipe oficial atual exige **vLLM 0.28.0+**.

Para NVIDIA, o caminho FP8 single-node documentado é:

- 8× H200/H20 de 141 GB;
- `zai-org/GLM-5.3` FP8;
- Tensor Parallel 8;
- KV cache FP8;
- MTP com 5 draft tokens;
- parser de tools `glm47`;
- parser de reasoning `glm45`.

O projeto verifica vLLM >=0.28.0 e Transformers >=5.15.0.

Fonte principal: https://recipes.vllm.ai/zai-org/GLM-5.3

## Contexto e concorrência

Embora o modelo declare até 1M tokens, a capacidade prática é limitada por pesos, KV cache, workspaces e concorrência. O recipe associa explicitamente **8×B200** ao perfil de contexto integral de 1M. Por isso o perfil H200 deste projeto começa em:

```text
MAX_MODEL_LEN=131072
MAX_NUM_SEQS=8
MAX_NUM_BATCHED_TOKENS=8192
```

O `max-num-batched-tokens=8192` também coincide com o valor apresentado pelo recipe como um ponto de partida comum. Existe ainda um motivo de estabilidade: uma issue recente de GLM FP8 em 8×H200 mostrou que o workspace do caminho sparse-decode podia crescer com `max_num_batched_tokens` e provocar OOM tardio. A correção upstream foi incorporada depois do commit do tag vLLM 0.28.0; portanto este projeto mantém um limite explícito e conservador em vez de depender de defaults mutáveis.

Referências:
- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://github.com/vllm-project/vllm/issues/53413
- https://github.com/vllm-project/vllm/pull/53755

## DeepGEMM

A revisão anterior dizia, incorretamente, que bastava depender dos componentes já integrados ao vLLM. O recipe atual é explícito: **DeepGEMM é requerido para o caminho de desempenho FP8 e deve ser instalado via `install_deepgemm.sh`**.

O tag vLLM 0.28.0 aponta para o commit:

```text
2cf0a6915ce544dc493a0990f2ea38d81601128a
```

O instalador oficial `tools/install_deepgemm.sh` desse commit fixa DeepGEMM em:

```text
8b1392b978f5a03c828dd1711090d7fb50958b8a
```

Por isso este repositório agora constrói uma imagem derivada local:

```text
Base:    vllm/vllm-openai:v0.28.0
Runtime: glm53-complete-vllm:0.28.0-deepgemm
```

O `Dockerfile` baixa o instalador do commit exato do vLLM, compila/instala o commit exato do DeepGEMM e falha o build se `import deep_gemm` não funcionar. O `install.sh` e `manage.sh update` validam novamente DeepGEMM com GPU antes de iniciar/trocar o servidor.

## CUDA 13 versus driver da imagem Azure HPC

A imagem oficial vLLM 0.28.0 usa CUDA 13. A documentação da Azure HPC ainda lista, para sua imagem publicada, driver NVIDIA 535.161.08 e CUDA 12.4. Em GPUs datacenter, vLLM oferece CUDA forward compatibility através de `VLLM_ENABLE_CUDA_COMPATIBILITY=1`.

O `.env.example` usa:

```text
VLLM_ENABLE_CUDA_COMPATIBILITY=auto
```

Durante a instalação:

- driver abaixo da série R580 -> `1`;
- R580 ou mais novo -> `0`.

A escolha concreta é salva no `.env` antes do preflight e antes do primeiro import de PyTorch. Isto evita depender da versão atualmente documentada da imagem Azure e também evita carregar compat libraries sem necessidade em drivers futuros.

Referências:
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
- https://docs.vllm.ai/en/v0.28.0/deployment/docker/

## Docker e isolamento

Para NVIDIA, a documentação do vLLM exige acesso às GPUs e recomenda `--ipc=host`; modo `privileged` não é necessário para este caminho. O container vLLM deste projeto **não usa mais `privileged: true`**. A porta do vLLM permanece somente na rede Docker interna e o Nginx publica apenas `/v1/`.

## Armazenamento

O recipe classifica o checkpoint FP8 em aproximadamente **893 GB**. Este projeto exige, por padrão:

- 1.200 GiB livres para pesos/cache Hugging Face;
- 100 GiB para Docker/imagens;
- 30 GiB para cache vLLM/compilação.

Quando os três consumidores compartilham filesystem, o mínimo agregado é **1.330 GiB livres**. A recomendação operacional permanece **2 TiB persistentes** para suportar o checkpoint, a imagem derivada, caches, logs e atualizações com imagem candidata.

## Azure H200 / Fabric Manager

O alvo padrão é `Standard_ND96isr_H200_v5`, com 8×H200. O preflight valida número de GPUs e VRAM. Se o NVIDIA Fabric Manager estiver instalado mas inativo, o instalador emite aviso, pois isso pode afetar comunicação NVSwitch/multi-GPU. `./manage.sh diagnose` também mostra `nvidia-smi topo -m`.

## Quantização NVFP4

O checkpoint `Inferact/GLM-5.3-NVFP4` é uma alternativa Blackwell, com footprint muito menor que FP8. Ele não é o default deste repositório porque o objetivo aqui é manter o caminho single-node FP8 explicitamente documentado para H200. Um perfil GB200/NVFP4 deve ser tratado e testado separadamente.

Referências:
- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://huggingface.co/Inferact/GLM-5.3-NVFP4

## Recursos recentes propositalmente não ativados

A triagem de issues recentes mostrou problemas em caminhos como DCP e KV offloading. O perfil inicial deste projeto não ativa DCP, KV offload nem outras otimizações experimentais. A estratégia é estabelecer primeiro um baseline estável TP=8/H200 e adicionar otimizações apenas depois de medições reais.

## Reprodutibilidade

Antes do primeiro teste H200:

```text
VLLM_BASE_IMAGE=vllm/vllm-openai:v0.28.0
VLLM_SOURCE_REF=2cf0a6915ce544dc493a0990f2ea38d81601128a
DEEPGEMM_REF=8b1392b978f5a03c828dd1711090d7fb50958b8a
VLLM_IMAGE=glm53-complete-vllm:0.28.0-deepgemm
MODEL_REVISION=main
```

Depois do primeiro carregamento + chat + tool calling bem-sucedidos, registrar e congelar:

- digest/ID da imagem base e ID da imagem derivada;
- commit exato do checkpoint em `MODEL_REVISION`;
- driver NVIDIA;
- vLLM/Transformers/DeepGEMM;
- contexto, lote e concorrência efetivamente validados.

O único teste que documentação, CI e análise estática não substituem é a execução real em 8×H200 com o checkpoint completo carregado.
