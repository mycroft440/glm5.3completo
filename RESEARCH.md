# Pesquisa técnica — GLM-5.3 completo

Data da revisão: 2026-09-03.

## Modelo

O GLM-5.3 completo é um MoE de aproximadamente 743B parâmetros totais / 39B ativos, com janela nativa de 1.048.576 tokens. O checkpoint padrão `zai-org/GLM-5.3` é FP8; BF16 fica em repositório separado.

Fonte: https://recipes.vllm.ai/zai-org/GLM-5.3

## Perfil escolhido

O recipe atual do vLLM marca o caminho padrão single-node como:

- 8× H200/H20 de 141 GB;
- `zai-org/GLM-5.3` FP8;
- Tensor Parallel 8;
- KV cache FP8;
- MTP com 5 tokens;
- parser de tools `glm47`;
- parser de reasoning `glm45`.

O projeto usa vLLM 0.28.0, requisito mínimo atual do recipe, e verifica Transformers >=5.15.0.

## Contexto

Embora o modelo declare até 1M tokens, a capacidade prática depende do KV cache. Para a primeira subida em H200 usamos 131.072 tokens e `MAX_NUM_SEQS=8`. Depois do primeiro boot, aumente gradualmente e observe VRAM/OOM.

O recipe indica 8×B200 para alcançar o contexto integral de 1M com KV FP8; por isso não configuramos 1M como default em H200.

## Armazenamento

O recipe classifica o checkpoint FP8 em aproximadamente 893 GB. Este projeto exige 1.200 GiB livres para cache HF/pesos, mais 100 GiB de Docker e 30 GiB de cache vLLM quando esses consumidores usam o mesmo filesystem. Recomendação: disco persistente de 2 TiB.

## DeepGEMM

O recipe recomenda DeepGEMM para desempenho FP8. vLLM atual integra/bundla componentes DeepGEMM no próprio stack; `./manage.sh diagnose` registra se o módulo Python está visível, mas o bootstrap não instala um fork externo automaticamente.

## Quantização NVFP4

O checkpoint `Inferact/GLM-5.3-NVFP4` é uma alternativa Blackwell. O recipe descreve os experts MoE em NVFP4, mantendo partes do modelo em BF16, com footprint bem menor que FP8.

Não o colocamos como default porque:

1. é Blackwell-only;
2. o recipe oficial exemplifica a variante com uma topologia diferente do H200 padrão;
3. a Azure `Standard_ND128isr_NDR_GB200_v6` fornece 4 GPUs GB200 e CPU NVIDIA Grace/ARM64;
4. queremos que o instalador padrão use o caminho single-node explicitamente documentado para o modelo completo antes de adicionar um segundo perfil.

A imagem oficial vLLM 0.28.0 é multi-platform, inclusive ARM64, portanto um perfil GB200/NVFP4 pode ser acrescentado depois de um teste real separado.

Referências:
- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://huggingface.co/Inferact/GLM-5.3-NVFP4
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-gb200-v6-series
- https://hub.docker.com/r/vllm/vllm-openai/tags

## Reprodutibilidade

Antes do primeiro teste:

- `VLLM_IMAGE=vllm/vllm-openai:v0.28.0`
- `MODEL_REVISION=main`

Depois do primeiro teste bem-sucedido, fixe:

- digest da imagem;
- commit do checkpoint;
- driver NVIDIA;
- vLLM/Transformers;
- parâmetros de contexto e concorrência validados.
