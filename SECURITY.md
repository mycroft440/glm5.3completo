# Segurança da implantação

## Rede

`BIND_ADDRESS=127.0.0.1` continua sendo o padrão. Apenas o Nginx publica a porta e o gateway encaminha somente `/v1/`. Para acesso remoto, prefira VNet/IP privado ou VPN. Não exponha HTTP/8000 para `0.0.0.0/0`.

## Credenciais

A API key é gerada aleatoriamente. O `.env` operacional fica em `/opt/glm53-complete/.env` com modo `600`. `glm-info` mostra a chave por conveniência; não compartilhe essa saída.

## Imagens e checkpoint

O checkpoint, Nginx e as duas bases vLLM são fixados por commit/digest. O preflight rejeita `MODEL_REVISION=main` e `VLLM_BASE_IMAGE` sem digest após o perfil ser resolvido.

## Containers

Nenhum perfil usa `privileged: true`.

No NVIDIA, o runtime usa GPU reservation + `ipc: host`.

No ROCm, o vLLM exige `/dev/kfd`, `/dev/dri`, `SYS_PTRACE`, `seccomp=unconfined` e grupo `video`, conforme a documentação oficial do container ROCm. Esses privilégios são mais amplos que um container comum, portanto o host deve ser dedicado ao serviço e não deve executar workloads não confiáveis no mesmo daemon Docker.

## Mídia remota / SSRF

Defaults:

```text
ALLOWED_MEDIA_DOMAIN=media.invalid
VLLM_MEDIA_URL_ALLOW_REDIRECTS=0
```

## Operações

Instalação e comandos mutáveis usam `flock`. `glm-manage update` constrói e valida uma candidata antes da troca e tenta rollback com healthcheck profundo se algo falhar.

## Snapshot

Após instalar, scripts/configuração operacionais ficam em `/opt/glm53-complete`, reduzindo dependência do clone Git.

## Spot e persistência

Em VM Spot, não trate o NVMe temporário como armazenamento durável. `HF_CACHE_DIR` deve apontar para disco persistente se a intenção é evitar novo download de ~893 GB após interrupção/desalocação.

## GitHub

Proteção da branch `main` continua sendo configuração administrativa externa ao código.
