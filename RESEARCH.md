# Pesquisa técnica — GLM-5.3 completo

Data da revisão: 2026-09-03.

## Modelo e perfil

O GLM-5.3 completo é um MoE de aproximadamente **743B parâmetros totais / 39B ativos**, checkpoint padrão FP8 com footprint publicado em torno de **893 GB** e contexto declarado de até 1.048.576 tokens.

O recipe atual do vLLM usa como perfil FP8 single-node:

- 8× NVIDIA H200/H20;
- Tensor Parallel 8;
- KV cache FP8;
- MTP com 5 tokens;
- `--tool-call-parser glm47`;
- `--reasoning-parser glm45`;
- DeepGEMM no caminho FP8 de desempenho.

Este projeto fixa o checkpoint em `187fb9fff6319062325ff825627ef6db084d9bc6` e começa com 131.072 tokens, 8 sequências e 8.192 tokens por lote.

Fonte principal: https://recipes.vllm.ai/zai-org/GLM-5.3

## Runtime e reprodutibilidade

Base x86_64 do vLLM 0.28.0:

```text
vllm/vllm-openai@sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635
```

Gateway:

```text
nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de
```

DeepGEMM:

```text
VLLM_SOURCE_REF=2cf0a6915ce544dc493a0990f2ea38d81601128a
DEEPGEMM_REF=8b1392b978f5a03c828dd1711090d7fb50958b8a
```

Esses pins eliminam mudanças silenciosas nas entradas principais do runtime. Pacotes APT usados apenas no build ainda vêm do snapshot do repositório Ubuntu disponível no momento da construção; portanto o build não é declarado bit-a-bit hermético.

## DeepGEMM e submódulos

O instalador de DeepGEMM do vLLM 0.28.0 clona `--recursive` antes de fazer checkout do commit escolhido. Sem uma segunda sincronização, submódulos podem refletir o estado inicialmente clonado em vez dos SHAs gravados no commit alvo.

O Dockerfile deste projeto insere após o checkout:

```bash
git submodule sync --recursive
git submodule update --init --recursive --force
```

O cache JIT também é persistido via `DG_JIT_CACHE_DIR=/root/.cache/deepgemm` para `/var/lib/glm53-full/deepgemm-cache`.

## OOM sparse-decode / FlashMLA

O bug vLLM #53413 afetou o workspace do caminho sparse-decode. A correção PR #53755, incorporada depois do tag 0.28.0, troca no build do vLLM o FlashMLA:

```text
a8f794d1251cbfd88a5011445dd5582289c727e4
→
0397728d511c4e3d94ea3a01d8dda8654525a611
```

Como a imagem 0.28.0 já possui extensões compiladas, editar apenas a referência de fonte numa imagem derivada **não** seria um backport verdadeiro. O projeto mantém 0.28.0 como base estável do recipe e limita `MAX_NUM_BATCHED_TOKENS=8192` como mitigação conservadora até validar um release/imagem estável que já contenha a correção compilada. Teste de stress prolongado na H200 continua obrigatório.

Referências:
- https://github.com/vllm-project/vllm/issues/53413
- https://github.com/vllm-project/vllm/pull/53755

## Compatibilidade de agentes

Dois problemas upstream foram considerados:

1. `assistant.content=null + tool_calls` pode chegar ao chat template e renderizar `None`. PR upstream: #54368.
2. `enable_thinking=false` / `thinking=false` podem desarmar a extração do parser enquanto GLM-5.3 continua emitindo thinking, causando vazamento do scratchpad. PR upstream: #54825.

O runtime derivado normaliza o primeiro caso no servidor. Para o segundo, este perfil GLM-only rejeita essas flags antigas com erro de validação e exige `reasoning_effort`.

O smoke test envia deliberadamente um histórico `assistant.content=null`, executa o resultado da ferramenta e valida a resposta final. Também testa streaming e rejeita tags `<think>` no conteúdo final.

Referências:
- https://github.com/vllm-project/vllm/pull/54368
- https://github.com/vllm-project/vllm/pull/54825

## Azure H200

VM de referência: `Standard_ND96isr_H200_v5`, 8× H200 de 141 GB.

A imagem Azure HPC A100+ mais recente encontrada nesta revisão é:

```text
microsoft-dsvm:ubuntu-hpc:2404:24.04.2026072901
```

Release 2026072901 (06/08/2026): driver NVIDIA 580.173.02, Fabric Manager 580.173.02, CUDA 13.0.88, NCCL 2.30.4-1 e Docker/Moby 29.6.2.

Fonte: https://github.com/Azure/azhpc-images/releases

O instalador conserva lógica de forward compatibility para VMs antigas: driver < R580 ativa `VLLM_ENABLE_CUDA_COMPATIBILITY=1`; R580+ usa 0.

## Hardware fail-closed

O baseline valida exatamente 8 GPUs H200 homogêneas, >=130000 MiB por GPU, >=1400 GiB de RAM do host, NVLink/NVSwitch visível e Fabric Manager ativo. Essa rigidez é proposital para não transformar um instalador H200 em um “tentar rodar em qualquer GPU”.

## Armazenamento

Reservas padrão se todos os consumidores estiverem no mesmo filesystem:

```text
Hugging Face / pesos     1200 GiB
Docker / imagens          100 GiB
cache vLLM                 30 GiB
cache DeepGEMM JIT         20 GiB
-------------------------------
total mínimo             1350 GiB
```

Recomendação operacional: **2 TiB persistentes**.

## Limite da pesquisa estática

A configuração está alinhada às fontes atuais, mas ainda falta evidência de hardware real para: build DeepGEMM no host alvo, carregamento dos ~893 GB, MTP, headroom de KV/workspaces, comportamento prolongado do sparse-decode, tool loops, streaming, throughput, reboot e Spot. A implantação não deve ser chamada de “produção comprovada” antes dessa bateria.
