# Pesquisa técnica — GLM-5.3 completo

Data da revisão: 2026-09-06.

## Modelo

O `zai-org/GLM-5.3` é um MoE de aproximadamente **743B parâmetros totais / 39B ativos**, checkpoint FP8 de grande porte e contexto nativo de até 1.048.576 tokens.

O projeto fixa agora o commit oficial:

```text
aca966e4e02791568aa6a4ced368624b3d897f42
```

Esse commit alterou `chat_template.jinja`: além de interromper mais cedo verificações de reordenação de tool results, deixou de renderizar conteúdo `None` em um caminho do template. Isso é relevante para um servidor voltado a agentes/tools.

Fontes:
- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://huggingface.co/zai-org/GLM-5.3/commit/aca966e4e02791568aa6a4ced368624b3d897f42

## AMD MI300X

O recipe atual do vLLM publica perfil FP8 para **MI300X/MI355X** com AITER, KV `fp8_e4m3`, TP=8, MTP=5, GPU utilization 0.80, contexto 524.288, 32 sequências, `--linear-backend aiter` e `--moe-backend aiter`.

VM alvo econômica: `Standard_ND96isr_MI300X_v5`, 8× MI300X e 1.850 GiB de RAM.

Imagem Azure HPC ROCm recomendada:

```text
microsoft-dsvm:ubuntu-hpc:2404-rocm:24.04.2026072801
```

A base oficial do vLLM permanece fixada em:

```text
vllm/vllm-openai-rocm@sha256:e0a3b2bd3fe7ec563916c3a5d949898d133458c18d6b2f460c906885cfb32032
```

O userspace ROCm do container é mais novo que o host da imagem HPC, mas a matriz AMD de compatibilidade user/kernel cobre essa combinação. A validação dentro do container continua obrigatória.

## XGMI / Infinity Fabric

Apenas executar `rocm-smi --showtopo` não prova uma topologia válida. O preflight agora exige, para as 8 GPUs AMD selecionadas:

- `xgmi_hive_id` legível em sysfs;
- hive id não-zero;
- todas as GPUs no mesmo hive;
- `rocm-smi --showtopotype` reportando XGMI;
- consulta geral de topologia funcionando.

A AMD documenta `xgmi_hive_id` e as opções de topologia/XGMI como meios de identificar GPUs no mesmo XGMI hive.

## Armazenamento Azure

A `Standard_ND96isr_MI300X_v5` possui grande armazenamento NVMe **local/temporário**. Isso não é equivalente a Managed Disk persistente. Azure VM utilities expõe links distintos para discos de dados (`/dev/disk/azure/data/by-lun`) e NVMe local (`/dev/disk/azure/local/...`).

Por isso o baseline passou a exigir que o cache de pesos esteja em filesystem separado do `/` e rejeita:

- `/dev/disk/azure/resource`;
- dispositivos identificados em `/dev/disk/azure/local/...`;
- modelo de bloco `Microsoft NVMe Direct Disk`.

O instalador não formata discos automaticamente. A implantação deve montar um **Managed Disk persistente >=2 TiB** em `/var/lib/glm53-full` antes do primeiro `install.sh`.

Fontes:
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/ndmi300xv5-series
- https://learn.microsoft.com/azure/virtual-machines/linux/azure-virtual-machine-utilities

## Spot

Azure Scheduled Events envia `Preempt` com aviso mínimo de cerca de 30 segundos para Spot. O projeto instala um watcher quando o IMDS informa `evictionPolicy`: ele consulta Scheduled Events, deixa de aceitar novas requisições parando o gateway e então tenta parar o runtime.

Isso não garante continuidade — Spot continua sem SLA — mas melhora o encerramento e combina com a exigência de cache em disco persistente.

Fontes:
- https://learn.microsoft.com/azure/architecture/guide/spot/spot-eviction
- https://learn.microsoft.com/azure/virtual-machines/linux/scheduled-events

## CI ROCm

A CI anterior usava apenas `docker buildx build --check`, que valida o Dockerfile mas não executa seus `RUN`. Em pushes para `main`, a CI agora faz uma build real de `Dockerfile.rocm` e executa dentro da imagem:

```python
import torch, vllm, aiter
assert torch.version.hip
```

Isso ainda não substitui uma MI300X real, mas passa a detectar quebra de imagem, dependências, patch e importações antes de gastar crédito de GPU.

## Tuning e reinstalação

`apply-profile.sh` passou a preservar `MAX_MODEL_LEN`, `MAX_NUM_SEQS`, `MAX_NUM_BATCHED_TOKENS`, `GPU_MEMORY_UTILIZATION` e `KV_CACHE_DTYPE` quando a instalação é repetida no mesmo perfil. Defaults só são escritos se o valor está `auto`/vazio ou se o acelerador mudou.

## APIs e agentes

Os testes continuam cobrindo Chat Completions, tools multi-turn, `assistant.content=null`, reasoning e streaming, e agora também testam `/v1/responses`.

## H200

O fallback NVIDIA continua usando 8× H200, CUDA + DeepGEMM, TP=8, KV FP8, MTP=5, contexto inicial 131.072 e lote conservador 8.192.

## Limite da pesquisa estática

Ainda falta provar em hardware real: acesso às 8 MI300X, AITER, carregamento integral, 524k, MTP, pressão de memória, throughput, XGMI sob carga, Spot eviction real, reboot e reutilização de cache persistente.
