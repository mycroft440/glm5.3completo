# Segurança da implantação

## Rede

O padrão é `BIND_ADDRESS=127.0.0.1`. O vLLM não publica diretamente sua porta no host; Nginx encaminha somente `/v1/`. Para acesso remoto, prefira VNet/IP privado ou VPN. Não exponha TCP/8000 em HTTP para `0.0.0.0/0`.

## Credenciais

A API key é gerada aleatoriamente. O `.env` operacional fica em `/opt/glm53-complete/.env` com modo `600`. `glm-info` mostra a chave deliberadamente; não compartilhe essa saída.

## Pins

Entradas principais permanecem fixadas:

```text
MODEL_REVISION=aca966e4e02791568aa6a4ced368624b3d897f42
NVIDIA_VLLM_BASE_IMAGE=vllm/vllm-openai@sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635
ROCM_VLLM_BASE_IMAGE=vllm/vllm-openai-rocm@sha256:e0a3b2bd3fe7ec563916c3a5d949898d133458c18d6b2f460c906885cfb32032
NGINX_IMAGE=nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de
```

O instalador só migra automaticamente o antigo pin oficial que era default do próprio repositório; um `MODEL_REVISION` personalizado permanece intacto.

## Armazenamento do modelo

Por padrão o preflight exige filesystem separado do `/` e rejeita discos Azure local/resource conhecidos para `HF_CACHE_DIR`. Isso reduz o risco de perder ~893 GB de cache em eviction/deallocate.

Use Managed Disk persistente >=2 TiB montado em `/var/lib/glm53-full`. O instalador não formata ou particiona discos automaticamente.

## Containers

O runtime não usa `privileged: true`.

ROCm recebe somente os requisitos do vLLM (`/dev/kfd`, `/dev/dri`, grupo video, `SYS_PTRACE`, `seccomp=unconfined`). NVIDIA usa a reserva de GPU do Docker e `ipc: host`. DeepGEMM possui cache JIT persistente no perfil H200.

## Mídia remota / SSRF

Defaults:

```text
ALLOWED_MEDIA_DOMAIN=media.invalid
VLLM_MEDIA_URL_ALLOW_REDIRECTS=0
```

URLs remotas permanecem efetivamente bloqueadas até configuração deliberada.

## Compatibilidade de agentes

O runtime derivado normaliza `assistant.content=null + tool_calls` antes do template e rejeita flags legadas `enable_thinking`/`thinking`. O smoke test verifica Chat Completions, Responses API, tools multi-turn e streaming.

## Azure Spot

Quando o IMDS informa uma política de eviction, `install.sh` habilita `glm53-spot-watch.service`. Ele consulta Azure Scheduled Events e, ao detectar `Preempt`, fecha primeiro o gateway e depois tenta parar o runtime. Um marcador também é escrito em `MODEL_STORAGE_ROOT`.

O watcher melhora o encerramento, mas não transforma Spot em infraestrutura confiável: Azure Spot não possui SLA e pode ser removido a qualquer momento.

## Operações e update

Instalação e comandos mutáveis usam `/var/lock/glm53-complete.lock` com `flock`. Updates constroem imagem candidata, validam antes da promoção e tentam rollback confirmado por inferência real se a troca falhar.

## Snapshot operacional

Após instalar, configuração e scripts ficam em `/opt/glm53-complete`; apagar o clone não deve quebrar o serviço.

## Branch principal

Proteção da `main` é configuração externa do GitHub. Recomenda-se tornar o workflow `GLM 5.3 complete server CI` obrigatório antes de aceitar mudanças.
