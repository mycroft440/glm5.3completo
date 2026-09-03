# Segurança da API

## Padrão

`BIND_ADDRESS=127.0.0.1` por padrão. O vLLM não publica porta diretamente no host; Nginx encaminha somente `/v1/` e bloqueia caminhos auxiliares como `/invocations`.

A API key é gerada aleatoriamente, salva em `.env` com modo `600` e não é commitada.

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

## Atualizações

`start`, `restart` e `apply` usam `--pull never`. `update` valida a nova imagem antes de recriar e só aceita a atualização após health + smoke test de chat/tools. Se falhar, tenta restaurar a imagem anterior.

Depois do primeiro H200 bem-sucedido, fixe o digest da imagem e `MODEL_REVISION` para evitar mudanças silenciosas.
