# GLM-5.3 Completo — Azure Server

Servidor pronto para instalar o **GLM-5.3 completo (743B / 39B ativos)** em uma única VM Azure com API compatível com OpenAI. O mesmo instalador detecta automaticamente se a máquina usa **8× AMD MI300X (ROCm/AITER)** ou **8× NVIDIA H200 (CUDA/DeepGEMM)** e aplica o perfil correto sem você precisar editar Docker, vLLM ou os parâmetros do modelo manualmente.

## Instale com este script

```bash
git clone https://github.com/mycroft440/glm5.3completo.git
cd glm5.3completo
sudo ./install.sh
```

### Como funciona

Ao executar `sudo ./install.sh`, o instalador:

1. identifica automaticamente o acelerador disponível;
2. se detectar **MI300X / gfx942**, seleciona o perfil `rocm`, vLLM ROCm + AITER, TP=8, KV `fp8_e4m3`, MTP=5 e contexto inicial de 524.288 tokens;
3. se detectar **H200**, seleciona o perfil `nvidia`, vLLM CUDA + DeepGEMM, TP=8, KV FP8, MTP=5 e contexto inicial de 131.072 tokens;
4. valida GPUs, RAM, armazenamento, Docker, drivers e topologia antes de iniciar;
5. gera uma API key automaticamente;
6. baixa/carrega o checkpoint fixado do GLM-5.3;
7. sobe vLLM atrás de um gateway Nginx compatível com `/v1` da API OpenAI;
8. instala os comandos globais `glm-info` e `glm-manage`;
9. ao final, mostra URL da API, chave, modelo, perfil detectado, GPUs, contexto e demais informações de uso.

Depois da instalação:

```bash
glm-info
glm-manage logs
glm-manage wait
glm-manage test
```

`glm-info` mostra rapidamente todas as informações necessárias para conectar outro aplicativo ou agente ao GLM-5.3. `glm-manage test` valida autenticação, chat, reasoning, tool calling multi-turn e streaming.

## Perfil recomendado para menor custo: Azure MI300X Spot

- VM: `Standard_ND96isr_MI300X_v5`
- Azure: **Spot**
- GPU: 8× AMD Instinct MI300X 192 GB (1.535 GB HBM total)
- RAM: 1.850 GiB
- imagem recomendada: `microsoft-dsvm:ubuntu-hpc:2404-rocm:24.04.2026072801`
- runtime: vLLM 0.28.0 ROCm + AITER
- TP=8
- KV cache `fp8_e4m3`
- MTP=5
- contexto inicial: **524.288**
- máximo inicial de sequências: **32**
- `--linear-backend aiter`
- `--moe-backend aiter`
- `VLLM_ROCM_USE_AITER=1`
- `VLLM_ROCM_USE_AITER_FUSION_SHARED_EXPERTS=1`

Esse perfil segue o recipe atual do vLLM para o GLM-5.3 FP8 em MI300X/MI355X.

## Perfil alternativo: NVIDIA H200

O perfil H200 anterior continua suportado:

- VM: `Standard_ND96isr_H200_v5`
- 8× H200 141 GB
- vLLM 0.28.0 CUDA + DeepGEMM
- TP=8, KV FP8, MTP=5
- contexto inicial 131.072
- lote conservador 8.192 tokens

## API

Padrão:

```text
http://127.0.0.1:8000/v1
```

Modelo servido: `glm-5.3`.

A API permanece local por padrão. Para acesso remoto, use VNet/IP privado ou VPN; veja `SECURITY.md`.

## Como o perfil MI300X funciona

O Compose base é comum. O gerenciamento adiciona automaticamente `docker-compose.rocm.yml`.

No ROCm, o container recebe `/dev/kfd` e `/dev/dri`, `SYS_PTRACE` e `seccomp=unconfined`, conforme o padrão documentado pelo vLLM para seu container ROCm. Não usamos `privileged: true`.

A imagem derivada usa a base oficial fixada:

```text
vllm/vllm-openai-rocm@sha256:e0a3b2bd3fe7ec563916c3a5d949898d133458c18d6b2f460c906885cfb32032
```

## Reprodutibilidade

Checkpoint:

```text
MODEL_REVISION=187fb9fff6319062325ff825627ef6db084d9bc6
```

NVIDIA vLLM base:

```text
vllm/vllm-openai@sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635
```

ROCm vLLM base:

```text
vllm/vllm-openai-rocm@sha256:e0a3b2bd3fe7ec563916c3a5d949898d133458c18d6b2f460c906885cfb32032
```

Nginx:

```text
nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de
```

## Armazenamento

O checkpoint FP8 ocupa aproximadamente **893 GB**. O preflight exige por padrão 1.200 GiB livres para pesos/cache HF, 100 GiB para Docker e 30 GiB para cache vLLM. No H200 há mais 20 GiB para DeepGEMM JIT. Recomendação: **2 TiB persistentes**.

Não coloque os pesos somente no NVMe temporário da VM Spot se quiser reaproveitá-los após desalocação/recriação.

## Spot

Spot pode ser interrompido pelo Azure. O serviço usa caches persistentes e snapshot operacional em `/opt/glm53-complete`, mas a persistência real dos ~893 GB depende de você montar `HF_CACHE_DIR` em disco persistente.

## Testes

`glm-manage test` cobre autenticação, gateway, chat low/max, ausência de `<think>`, tool calling multi-turn, regressão `assistant.content=null` e streaming SSE até `[DONE]`.

## Referências

- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://docs.vllm.ai/en/v0.28.0/deployment/docker/
- https://docs.vllm.ai/en/v0.28.0/getting_started/installation/gpu/
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/ndmi300xv5-series
- https://github.com/Azure/azhpc-images/releases

A validação estática/CI não substitui o primeiro teste real em `Standard_ND96isr_MI300X_v5`.
