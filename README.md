# GLM-5.3 Completo — Azure Server

Servidor para hospedar o **GLM-5.3 completo** e expor uma **API compatível com OpenAI**. Este projeto não inclui agentes nem orquestração.

## Perfil padrão

- Modelo: `zai-org/GLM-5.3` — checkpoint nativo FP8
- Arquitetura: ~743B parâmetros totais / 39B ativos
- Azure: `Standard_ND96isr_H200_v5`
- GPU: 8× NVIDIA H200 141 GB
- Base: `vllm/vllm-openai:v0.28.0`
- Runtime local: `glm53-complete-vllm:0.28.0-deepgemm`
- Tensor Parallel: 8
- KV cache: FP8
- MTP: 5 draft tokens
- Contexto inicial: 131.072 tokens
- Lote máximo inicial: 8.192 tokens
- Máximo inicial de sequências: 8
- Contexto nativo do modelo: até 1.048.576 tokens
- Armazenamento recomendado: **2 TiB persistentes**

O recipe atual do vLLM identifica 8×H200/H20 como o caminho FP8 single-node para o GLM-5.3. O projeto começa com contexto/concorrência conservadores para reduzir risco de OOM até existir medição real na VM.

## Instalação

```bash
git clone https://github.com/mycroft440/glm5.3completo.git
cd glm5.3completo
sudo ./install.sh
```

O instalador:

1. valida Ubuntu, driver, Docker, Compose, GPUs, VRAM e armazenamento;
2. instala/configura NVIDIA Container Toolkit quando necessário;
3. gera API key e migra `.env` de versões anteriores sem apagar preferências;
4. escolhe automaticamente CUDA forward compatibility de acordo com o driver;
5. constrói uma imagem local baseada em vLLM 0.28.0 com **DeepGEMM fixado por commit**;
6. valida CUDA, vLLM, Transformers e DeepGEMM com as GPUs;
7. sobe vLLM + Nginx;
8. mostra automaticamente o painel completo da API.

A primeira inicialização precisa baixar aproximadamente **893 GB** de pesos FP8.

Acompanhe com:

```bash
./manage.sh logs
./manage.sh wait
./manage.sh test
```

## `glm-info`

Depois da instalação, de qualquer pasta:

```bash
glm-info
```

O painel mostra status, URL, API key, checkpoint/revisão, contexto, TP, KV FP8, MTP, sequências, lote máximo, imagem base/runtime, DeepGEMM, CUDA compatibility, GPUs, caches, mídia remota e comandos operacionais. A chave é exibida deliberadamente; trate a saída como segredo.

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
        "reasoning_effort": "max",
        "chat_template_kwargs": {"clear_thinking": True},
    },
)
print(response.choices[0].message.content)
```

## Segurança

O vLLM não publica sua porta diretamente no host. Nginx encaminha somente `/v1/`; o bind padrão é `127.0.0.1`. O container NVIDIA usa acesso às GPUs + `ipc: host`, mas **não roda em modo privileged**.

A API key é gerada automaticamente e salva em `.env` com permissão `600`. URLs de mídia remota ficam bloqueadas por padrão. Para agentes remotos, prefira VNet/IP privado ou VPN; internet pública exige HTTPS/TLS, API key e restrição de rede. Veja `SECURITY.md`.

## DeepGEMM

O recipe oficial atual do GLM-5.3 informa que **DeepGEMM é requerido para o caminho de desempenho FP8**. Por isso o projeto não depende de ele aparecer casualmente na imagem base.

O `Dockerfile` usa:

```text
VLLM_SOURCE_REF=2cf0a6915ce544dc493a0990f2ea38d81601128a
DEEPGEMM_REF=8b1392b978f5a03c828dd1711090d7fb50958b8a
```

O build falha se `import deep_gemm` não funcionar, e o runtime é validado outra vez antes de subir.

## CUDA / Azure HPC

A documentação atual da Azure HPC ainda lista driver R535/CUDA 12.4, enquanto vLLM 0.28.0 usa CUDA 13. O instalador resolve `VLLM_ENABLE_CUDA_COMPATIBILITY=auto` assim:

- driver < R580: ativa forward compatibility;
- driver >= R580: desativa a camada extra.

A escolha fica gravada no `.env`.

## Estabilidade de memória

Defaults:

```text
MAX_MODEL_LEN=131072
MAX_NUM_SEQS=8
MAX_NUM_BATCHED_TOKENS=8192
GPU_MEMORY_UTILIZATION=0.90
KV_CACHE_DTYPE=fp8
MTP_SPECULATIVE_TOKENS=5
```

O limite explícito de 8.192 tokens por lote reduz o workspace máximo do sparse-decode e evita depender de defaults. Ele é especialmente prudente porque houve um bug recente de OOM tardio nesse caminho em GLM FP8/H200; a correção upstream foi incorporada depois do commit do tag vLLM 0.28.0.

## Armazenamento

O preflight reserva por padrão:

- 1.200 GiB para pesos/cache Hugging Face;
- 100 GiB para Docker/imagens;
- 30 GiB para cache vLLM/compilação.

Se compartilharem o mesmo filesystem, exige **1.330 GiB livres**. Recomendamos **2 TiB persistentes**, inclusive para permitir build/atualização de uma imagem candidata sem falta de espaço.

## Atualização segura

`start`, `restart` e `apply` usam `--pull never` e exigem que a imagem runtime local já exista.

`./manage.sh update` agora é transacional:

1. valida configuração, GPUs e disco;
2. constrói uma imagem candidata a partir da base configurada;
3. valida CUDA, vLLM, Transformers e DeepGEMM sem tocar no servidor atual;
4. só então troca o runtime;
5. espera health e executa chat + tool calling;
6. se falhar, restaura a imagem anterior e confirma a recuperação da API quando possível.

## Diagnóstico

```bash
glm-info
./manage.sh status
./manage.sh logs
./manage.sh wait
./manage.sh test
./manage.sh diagnose
./manage.sh restart
./manage.sh update
./manage.sh key
```

`diagnose` mostra também topologia `nvidia-smi topo -m`, estado do Fabric Manager quando disponível, IDs/digests de imagem e versões do runtime sem mostrar a API key.

## Sobre NVFP4

Existe `Inferact/GLM-5.3-NVFP4`, voltado a Blackwell. Este repositório mantém como padrão o FP8/H200 documentado oficialmente. NVFP4/GB200 deve ser implementado como perfil separado e validado em hardware próprio.

## Limite de validação

A CI valida Bash, ShellCheck, Compose, pins do Dockerfile/DeepGEMM, configuração GLM/MTP/KV/lote/CUDA, ausência de `privileged: true`, Nginx e o launcher global `glm-info`.

Ainda não é possível afirmar “produção comprovada” sem executar o fluxo completo em uma VM real 8×H200: build da imagem derivada, download/carregamento dos ~893 GB, alocação de KV/workspaces, MTP, chat/tools, carga crescente e reboot/Spot.

Depois do primeiro teste real bem-sucedido, fixe `MODEL_REVISION` no commit exato do checkpoint e registre os IDs/digests das imagens e versões do runtime.

## Referências

- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://docs.vllm.ai/en/v0.28.0/deployment/docker/
- https://github.com/vllm-project/vllm/issues/53413
- https://github.com/vllm-project/vllm/pull/53755
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
