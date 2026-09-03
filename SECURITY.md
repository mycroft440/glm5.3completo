# Segurança da API

## Padrão

`BIND_ADDRESS=127.0.0.1` por padrão. O vLLM não publica porta diretamente no host; Nginx encaminha somente `/v1/` e bloqueia caminhos auxiliares como `/invocations`.

A API key é gerada aleatoriamente, salva em `.env` com modo `600` e não é commitada.

## Privilégios do container

O serviço NVIDIA usa acesso às GPUs e `ipc: host`, mas **não usa `privileged: true`**. O modo privileged foi removido porque não é necessário para o caminho NVIDIA documentado pelo vLLM e ampliaria desnecessariamente a superfície de acesso ao host.

A imagem runtime é derivada localmente da imagem oficial vLLM e inclui DeepGEMM fixado por commit. `VLLM_IMAGE` deve ser uma tag local diferente de `VLLM_BASE_IMAGE`; o preflight bloqueia configurações que poderiam sobrescrever a tag da imagem base.

## `glm-info`

`glm-info` mostra a API key por conveniência operacional. Não compartilhe prints ou logs desse painel. Para diagnóstico sem segredo, use:

```bash
./manage.sh diagnose
```

## Acesso remoto

Preferência:

1. Azure VNet / IP privado;
2. VPN/Tailscale/WireGuard;
3. NSG com allowlist de IP;
4. internet pública somente com HTTPS/TLS + API key.

Não abra TCP/8000 para `0.0.0.0/0` sem TLS e controles adicionais. Restrinja SSH/22 ao seu IP ou use Bastion.

## URLs de mídia / SSRF

Mesmo sendo um perfil de texto, o servidor mantém a superfície do vLLM endurecida:

```bash
ALLOWED_MEDIA_DOMAIN=media.invalid
VLLM_MEDIA_URL_ALLOW_REDIRECTS=0
```

Só libere um domínio remoto se houver necessidade concreta.

## CUDA compatibility

O instalador usa `VLLM_ENABLE_CUDA_COMPATIBILITY=auto` no template e grava `0` ou `1` no `.env` conforme o driver detectado. A compatibilidade é ligada para drivers anteriores à série R580 no perfil CUDA 13 e desligada quando não é necessária. Essa camada existe para GPUs datacenter; não copie essa configuração para hardware consumidor sem revisar a compatibilidade.

## Atualizações

`start`, `restart` e `apply` usam `--pull never` e não substituem a imagem runtime.

`update` é transacional: constrói uma imagem candidata separada, valida CUDA/vLLM/Transformers/DeepGEMM com GPU e só então recria o servidor. Depois exige health + chat + tool calling. Se falhar, restaura a imagem anterior e tenta confirmar a recuperação da API.

Depois do primeiro H200 bem-sucedido, fixe `MODEL_REVISION` no commit exato validado e registre IDs/digests das imagens e versões do runtime para evitar mudanças silenciosas.

## Segredos e logs

- `.env` está no `.gitignore`;
- não envie `API_KEY` ou `HF_TOKEN` para commits/issues/logs;
- `diagnose` foi projetado para não imprimir a API key;
- logs Docker têm rotação para limitar crescimento;
- os caches persistentes devem ser protegidos por permissões do host e não compartilhados com usuários não confiáveis.
