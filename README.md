# GLM-5.3 Completo — Azure Server

Servidor single-node para hospedar o **GLM-5.3 completo** e expor uma **API compatível com OpenAI**. Este repositório contém somente a camada de inferência; agentes e orquestração ficam fora dele.

## Perfil padrão auditado

- Modelo: `zai-org/GLM-5.3` FP8 — ~743B parâmetros totais / 39B ativos
- Azure: `Standard_ND96isr_H200_v5`
- GPU: exatamente 8× NVIDIA H200 141 GB, TP=8
- Checkpoint fixado: `187fb9fff6319062325ff825627ef6db084d9bc6`
- vLLM 0.28.0 base fixada por digest: `sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635`
- Runtime local derivado: `glm53-complete-vllm:0.28.0-deepgemm`
- Nginx fixado por digest: `sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de`
- KV cache FP8, MTP=5, contexto inicial 131.072, `MAX_NUM_BATCHED_TOKENS=8192`, `MAX_NUM_SEQS=8`
- Armazenamento recomendado: **2 TiB persistentes**

O recipe atual do vLLM usa 8×H200/H20 como perfil FP8 single-node e associa o contexto integral de 1M ao perfil 8×B200. Por isso este projeto começa deliberadamente em 131k e aumenta contexto/concorrência somente depois de medir headroom real.

## VM / imagem Azure recomendada

Para uma implantação nova, prefira a imagem Azure HPC A100+ atual validada no estudo:

```text
microsoft-dsvm:ubuntu-hpc:2404:24.04.2026072901
```

Essa release inclui NVIDIA driver 580.173.02, Fabric Manager 580.173.02, CUDA 13.0.88, NCCL 2.30.4-1 e Docker/Moby 29.6.2. O instalador ainda suporta `VLLM_ENABLE_CUDA_COMPATIBILITY=auto`: driver anterior a R580 ativa a camada de forward compatibility; R580+ a mantém desligada.

## Instalação

```bash
git clone https://github.com/mycroft440/glm5.3completo.git
cd glm5.3completo
sudo ./install.sh
```

O instalador valida Ubuntu, RAM, exatamente 8 H200 homogêneas, VRAM, topologia NVLink/NVSwitch, Fabric Manager, Docker, Compose e espaço em disco. Ele gera a API key, migra configurações antigas conhecidas, constrói o runtime derivado com DeepGEMM, valida CUDA/vLLM/Transformers/DeepGEMM e os patches de compatibilidade de agentes, sobe vLLM + Nginx e cria um snapshot operacional em:

```text
/opt/glm53-complete
```

Depois de uma instalação concluída, o serviço e os comandos globais não dependem mais da pasta clonada. O clone pode ser movido/removido sem quebrar o runtime instalado.

A primeira inicialização precisa baixar aproximadamente **893 GB** de pesos FP8. Use de qualquer pasta:

```bash
glm-info
glm-manage logs
glm-manage wait
glm-manage test
glm-manage diagnose
```

`glm-info` mostra status, URL, API key, revisão exata, imagens, contexto, TP, KV, MTP, GPUs e caches. A saída contém a API key e deve ser tratada como segredo.

## API OpenAI

Base URL local padrão:

```text
http://127.0.0.1:8000/v1
```

Exemplo Python:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8000/v1",
    api_key="SUA_CHAVE",
)

response = client.chat.completions.create(
    model="glm-5.3",
    messages=[{"role": "user", "content": "Analise este código."}],
    extra_body={
        "chat_template_kwargs": {
            "reasoning_effort": "max",
            "clear_thinking": True,
        }
    },
)
print(response.choices[0].message.content)
```

## Compatibilidade com agentes

O runtime derivado incorpora uma correção estreita para o caso OpenAI `assistant.content=null + tool_calls`, normalizando-o para string vazia antes do chat template. Isso evita que históricos de agentes acumulem o literal `None` enquanto a correção upstream ainda não estiver integrada ao runtime usado.

Flags antigas `chat_template_kwargs.enable_thinking` e `chat_template_kwargs.thinking` são rejeitadas pelo servidor neste perfil GLM-5.3, porque o template pode ignorá-las enquanto o reasoning parser altera o comportamento e deixa scratchpad vazar para `message.content`. Use somente `reasoning_effort=low|high|max` e `clear_thinking=true`.

`glm-manage test` valida chat low/max, ausência de tags `<think>` no conteúdo, rejeição das flags antigas, tool call, ciclo completo `tool_calls -> tool result -> resposta final` com `content:null` e streaming SSE até `[DONE]`.

## DeepGEMM

O recipe do GLM-5.3 requer DeepGEMM para o caminho FP8 de desempenho. O runtime usa:

```text
VLLM_SOURCE_REF=2cf0a6915ce544dc493a0990f2ea38d81601128a
DEEPGEMM_REF=8b1392b978f5a03c828dd1711090d7fb50958b8a
```

Após o checkout do DeepGEMM, o build ressincroniza e atualiza recursivamente os submódulos para os SHAs gravados naquele commit. O build falha se `import deep_gemm` falhar.

O cache JIT do DeepGEMM também é persistente:

```text
/var/lib/glm53-full/deepgemm-cache
```

Assim recriar o container não descarta deliberadamente kernels JIT já compilados.

## Memória e OOM sparse-decode

Defaults conservadores:

```text
MAX_MODEL_LEN=131072
MAX_NUM_SEQS=8
MAX_NUM_BATCHED_TOKENS=8192
GPU_MEMORY_UTILIZATION=0.90
KV_CACHE_DTYPE=fp8
MTP_SPECULATIVE_TOKENS=5
```

O vLLM corrigiu posteriormente um desperdício de workspace do FlashMLA sparse-decode trocando o commit do FlashMLA usado na build. Essa correção foi incorporada upstream **depois** do tag v0.28.0. Como a imagem v0.28.0 já contém os binários compilados, este projeto não finge fazer um backport apenas alterando arquivos de fonte. Até existir um runtime estável validado com a correção incorporada, `8192` continua sendo a mitigação conservadora e deve ser submetida a teste de carga prolongado na H200.

## Preflight fail-closed

O perfil padrão exige:

- exatamente 8 GPUs;
- nome correspondente a `H200` e GPUs homogêneas;
- >=130000 MiB de VRAM em cada GPU;
- >=1400 GiB de RAM do host;
- topologia NVLink/NVSwitch visível;
- NVIDIA Fabric Manager instalado e ativo;
- revisão do modelo com SHA de 40 caracteres;
- imagens base vLLM/Nginx fixadas por digest.

Essas exigências podem ser alteradas no `.env`, mas o default foi intencionalmente feito para a VM H200 alvo e prefere falhar cedo em vez de tentar rodar em hardware inesperado.

## Armazenamento

Por padrão o preflight reserva 1.200 GiB para Hugging Face/pesos, 100 GiB para Docker/imagens, 30 GiB para cache vLLM e 20 GiB para cache JIT DeepGEMM. Se todos compartilharem o mesmo filesystem, são **1.350 GiB livres mínimos**. A recomendação permanece **2 TiB persistentes** para pesos, builds candidatos, caches e margem operacional.

## Atualização e rollback

Operações mutáveis usam um lock com `flock`, impedindo dois `start/restart/update` simultâneos. `start`, `restart` e `apply` usam `--pull never`.

`glm-manage update` constrói uma imagem candidata sem tocar no servidor ativo, valida runtime/GPU/frontend, promove a candidata e somente então recria os containers. Inclusive uma falha no próprio `docker compose up` entra no caminho de rollback. Depois, aguarda API, executa o smoke test completo e, se houver falha, tenta restaurar a imagem anterior e confirmar recuperação por inferência real. Em sucesso, remove imagens antigas não mais necessárias quando possível.

## Segurança

O vLLM não publica porta diretamente no host. Nginx expõe somente `/v1/`; bind padrão `127.0.0.1`. O container recebe GPUs + `ipc: host`, mas não usa `privileged: true`. A API key fica em `/opt/glm53-complete/.env` com modo `600`; mídia remota permanece bloqueada por padrão. Para acesso remoto use preferencialmente VNet/VPN; internet pública exige TLS e allowlist/NSG. Veja `SECURITY.md`.

## CI e limite de validação

A CI valida Bash, ShellCheck, self-test do patch GLM, launchers globais, pins por digest/commit, Dockerfile com `buildx --check`, Compose, wiring do modelo/MTP/KV/cache, cobertura estática dos smoke tests e `nginx -t` usando a imagem fixada.

A CI comum do GitHub **não substitui uma H200** e não constrói/carrega os ~893 GB. O teste decisivo continua sendo uma execução real em 8×H200: build DeepGEMM, download/load completo, KV/workspaces, MTP, multi-turn tools, streaming, stress prolongado, reboot e reaproveitamento dos caches.

## Referências

- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://docs.vllm.ai/en/v0.28.0/deployment/docker/
- https://github.com/vllm-project/vllm/issues/53413
- https://github.com/vllm-project/vllm/pull/53755
- https://github.com/vllm-project/vllm/pull/54368
- https://github.com/vllm-project/vllm/pull/54825
- https://github.com/Azure/azhpc-images/releases
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
