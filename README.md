# GLM-5.3 Completo — Azure Server

Servidor mínimo para hospedar o **GLM-5.3 completo** e expor uma **API compatível com OpenAI**. Este projeto não inclui agentes nem orquestração.

## Perfil padrão

- Modelo: `zai-org/GLM-5.3` — checkpoint nativo FP8
- Arquitetura: ~743B parâmetros totais / 39B ativos
- Azure: `Standard_ND96isr_H200_v5`
- GPU: 8× NVIDIA H200 141 GB
- Runtime: `vllm/vllm-openai:v0.28.0`
- Tensor Parallel: 8
- KV cache: FP8
- MTP: 5 draft tokens
- Contexto inicial deste projeto: 131.072 tokens
- Contexto nativo do modelo: até 1.048.576 tokens
- Armazenamento recomendado: **2 TiB persistentes**

O recipe atual do vLLM identifica 8×H200/8×H20 como o caminho padrão single-node para o GLM-5.3 FP8. O contexto deste projeto começa deliberadamente menor para reduzir risco de OOM no primeiro boot; ele pode ser ampliado depois de medir headroom real de KV cache.

## Instalação

```bash
git clone https://github.com/mycroft440/glm5.3completo.git
cd glm5.3completo
sudo ./install.sh
```

Depois:

```bash
./manage.sh logs
./manage.sh wait
./manage.sh test
glm-info
```

A primeira inicialização precisa baixar aproximadamente **893 GB** de pesos FP8, então o primeiro boot pode ser demorado mesmo em rede rápida.

## `glm-info`

Após a instalação, de qualquer pasta:

```bash
glm-info
```

O painel mostra status, URL, API key, modelo, revisão, contexto, KV cache, MTP, GPUs, caches e comandos operacionais. A chave é exibida deliberadamente; trate a saída como segredo.

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

O vLLM não publica sua porta diretamente. Nginx encaminha somente `/v1/`; o bind padrão é `127.0.0.1`. Para agentes remotos, prefira VNet/IP privado ou VPN. Se expuser pela internet, use HTTPS/TLS, API key e allowlist de rede.

A API key é gerada automaticamente e salva em `.env` com permissão `600`. O arquivo `.env` não é versionado.

## Armazenamento

Defaults:

```text
HF_CACHE_DIR=/var/lib/glm53-full/huggingface
VLLM_CACHE_DIR=/var/lib/glm53-full/vllm-cache
```

O preflight reserva por padrão:

- 1.200 GiB livres para pesos/cache Hugging Face;
- 100 GiB para Docker;
- 30 GiB para cache vLLM/compilação.

Se todos estiverem no mesmo filesystem, o mínimo agregado é **1.330 GiB livres**. Recomendamos **2 TiB persistentes** para margem, atualizações e cache.

## Atualização segura

`start`, `restart` e `apply` usam `--pull never`. Eles não trocam a imagem vLLM sem você pedir.

`./manage.sh update`:

1. valida configuração, GPUs e disco;
2. baixa somente a imagem vLLM;
3. confere vLLM >= 0.28.0, Transformers >= 5.15.0 e CUDA/GPU;
4. recria o servidor;
5. espera a API;
6. roda smoke test com chat e tool calling;
7. tenta restaurar a imagem anterior em caso de falha.

Depois do primeiro teste real bem-sucedido, fixe o digest da imagem e o commit exato de `MODEL_REVISION`.

## Comandos

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

## Sobre NVFP4 / quantização

Existe o checkpoint `Inferact/GLM-5.3-NVFP4`, voltado a NVIDIA Blackwell. O recipe atual do vLLM o lista como alternativa de aproximadamente 465–558 GB, mas a configuração oficial mostrada é diferente do perfil H200 padrão e a Azure GB200 é uma VM 4-GPU baseada em Grace/ARM64. Para não misturar uma rota ainda menos validada com a instalação principal, este repositório começa no caminho oficial FP8 em 8×H200. Veja `RESEARCH.md`.

## Limite de validação

A CI valida Bash, ShellCheck, Docker Compose, MTP/revision wiring, Nginx e o launcher global `glm-info`. O teste decisivo que ainda depende de hardware é o carregamento completo do checkpoint em 8×H200, alocação do KV cache, MTP, chat, tools e reboot.

## Referências

- https://recipes.vllm.ai/zai-org/GLM-5.3
- https://docs.vllm.ai/en/latest/cli/serve/
- https://docs.vllm.ai/en/latest/deployment/docker/
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
