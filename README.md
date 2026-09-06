# GLM-5.3 Completo — Azure Server

Servidor pronto para instalar o **GLM-5.3 completo (743B / 39B ativos)** em uma única VM Azure com API compatível com OpenAI. O mesmo instalador detecta automaticamente **8× AMD MI300X (ROCm/AITER)** ou **8× NVIDIA H200 (CUDA/DeepGEMM)** e aplica o perfil correto.

## Pré-requisito obrigatório: disco persistente

O checkpoint é enorme. **Antes de executar o instalador**, anexe um **Azure Managed Disk persistente de pelo menos 2 TiB** e monte-o em:

```text
/var/lib/glm53-full
```

Verifique antes de continuar:

```bash
findmnt /var/lib/glm53-full
lsblk -o NAME,TYPE,SIZE,MODEL,MOUNTPOINT
```

O instalador agora falha antes de baixar pesos se o cache estiver no mesmo filesystem do `/` ou em um disco Azure local/resource conhecido. Isso é proposital: a `Standard_ND96isr_MI300X_v5` possui NVMe local muito grande, mas esse armazenamento é temporário e pode desaparecer em Spot/deallocate. O script **não formata discos automaticamente**, para não correr risco de apagar o dispositivo errado.

## Instalação

```bash
git clone https://github.com/mycroft440/glm5.3completo.git
cd glm5.3completo
sudo ./install.sh
```

Ao executar `sudo ./install.sh`, o instalador:

1. identifica automaticamente o acelerador;
2. MI300X/gfx942 → `rocm`, vLLM ROCm + AITER, TP=8, KV `fp8_e4m3`, MTP=5, contexto inicial 524.288;
3. H200 → `nvidia`, CUDA + DeepGEMM, TP=8, KV FP8, MTP=5, contexto inicial 131.072;
4. valida GPUs, VRAM, RAM, armazenamento, drivers e topologia;
5. no MI300X, exige que as GPUs pertençam ao mesmo XGMI hive e que a topologia reporte XGMI/Infinity Fabric;
6. gera uma API key;
7. baixa/carrega o checkpoint fixado do GLM-5.3;
8. sobe vLLM atrás do Nginx, expondo somente `/v1`;
9. instala `glm-info` e `glm-manage`;
10. se a VM for Spot, habilita automaticamente um watcher de Azure Scheduled Events para reagir a `Preempt`.

Depois:

```bash
glm-info
glm-manage logs
glm-manage wait
glm-manage test
```

## Perfil recomendado para menor custo: MI300X Spot

- VM: `Standard_ND96isr_MI300X_v5`
- 8× AMD Instinct MI300X 192 GB (~1,5 TiB HBM total)
- RAM: 1.850 GiB
- imagem recomendada: `microsoft-dsvm:ubuntu-hpc:2404-rocm:24.04.2026072801`
- vLLM 0.28.0 ROCm + AITER
- TP=8
- KV `fp8_e4m3`
- MTP=5
- contexto inicial 524.288
- 32 sequências iniciais
- `--linear-backend aiter`
- `--moe-backend aiter`

O perfil segue o recipe atual do vLLM para GLM-5.3 em MI300X/MI355X.

## Perfil alternativo: H200

- VM: `Standard_ND96isr_H200_v5`
- 8× H200 141 GB
- vLLM 0.28.0 CUDA + DeepGEMM
- TP=8, KV FP8, MTP=5
- contexto inicial 131.072
- lote conservador 8.192 tokens

## Tuning é preservado

Reexecutar `sudo ./install.sh` no **mesmo perfil** não volta mais automaticamente seus valores de tuning aos defaults. Por exemplo, se depois de testes você configurar:

```text
MAX_MODEL_LEN=400000
MAX_NUM_SEQS=20
GPU_MEMORY_UTILIZATION=0.76
```

esses valores permanecem. Os defaults são reaplicados apenas quando o valor ainda está `auto`/vazio ou quando o acelerador muda de ROCm para NVIDIA ou vice-versa.

## Modelo fixado

O checkpoint/chat template está fixado em:

```text
MODEL_REVISION=aca966e4e02791568aa6a4ced368624b3d897f42
```

Esse commit oficial corrige o `chat_template.jinja`, incluindo o tratamento/reordenação de resultados de ferramentas e conteúdo `None`. O instalador migra automaticamente apenas o pin antigo que era default deste repositório; pins personalizados continuam intactos.

## API

Base local:

```text
http://127.0.0.1:8000/v1
```

Modelo servido: `glm-5.3`.

A API permanece local por padrão. Para acesso remoto, prefira VNet/IP privado ou VPN; veja `SECURITY.md`.

## Spot eviction

Em VM Spot, o instalador consulta o Azure Instance Metadata Service. Quando `evictionPolicy` indica Spot, instala e habilita:

```text
glm53-spot-watch.service
```

O watcher consulta Scheduled Events a cada 5 segundos. Ao receber `Preempt`, grava um marcador no armazenamento do modelo, fecha primeiro o gateway e então tenta parar o vLLM. O Azure oferece pelo menos ~30 segundos de aviso para `Preempt`; isso **não torna Spot não-interrompível**, mas evita continuar aceitando novas requisições até o último segundo.

## Testes

`glm-manage test` cobre:

- autenticação e gateway;
- `/v1/models`;
- Chat Completions com reasoning `low` e `max`;
- **Responses API `/v1/responses`**;
- ausência de `<think>` vazando;
- tool calling multi-turn;
- regressão `assistant.content=null`;
- streaming SSE até `[DONE]`.

A CI também renderiza os dois perfis, testa preservação de tuning, valida os guards de armazenamento/XGMI e, em push para `main`, faz uma **build real da imagem ROCm derivada** e importa `torch`, `vllm` e `aiter` dentro dela.

## Reprodutibilidade

- modelo: `aca966e4e02791568aa6a4ced368624b3d897f42`
- NVIDIA base: `vllm/vllm-openai@sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635`
- ROCm base: `vllm/vllm-openai-rocm@sha256:e0a3b2bd3fe7ec563916c3a5d949898d133458c18d6b2f460c906885cfb32032`
- Nginx: `nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de`

## Armazenamento e timeout

O preflight reserva 1.200 GiB para pesos/Hugging Face, 100 GiB para Docker e 30 GiB para cache vLLM; H200 adiciona 20 GiB para DeepGEMM JIT. A recomendação continua **2 TiB persistentes**. Novas instalações usam timeout de prontidão de **14.400 s (4 h)** para não marcar o primeiro carregamento do modelo como falha prematuramente.

## Referências

- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://huggingface.co/zai-org/GLM-5.3/commit/aca966e4e02791568aa6a4ced368624b3d897f42
- https://docs.vllm.ai/en/v0.28.0/deployment/docker/
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/ndmi300xv5-series
- https://learn.microsoft.com/azure/architecture/guide/spot/spot-eviction
- https://learn.microsoft.com/azure/virtual-machines/linux/azure-virtual-machine-utilities
- https://rocm.docs.amd.com/projects/rocm_smi_lib/en/latest/how-to/use-python.html

A CI não substitui o teste real do checkpoint completo em 8× MI300X/H200.
