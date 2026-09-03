# Segurança da implantação

## Superfície de rede

O padrão continua `BIND_ADDRESS=127.0.0.1`. O vLLM não publica sua porta diretamente no host; Nginx encaminha somente `/v1/` e caminhos auxiliares como `/invocations` ficam bloqueados no gateway.

Para acesso remoto, a ordem preferida é VNet/IP privado ou VPN, depois NSG/allowlist. Exposição à internet deve adicionar HTTPS/TLS e restrição de origem; não abra TCP/8000 para `0.0.0.0/0` em HTTP simples.

## Credenciais

A API key é gerada aleatoriamente e o `.env` operacional fica em:

```text
/opt/glm53-complete/.env
```

com modo `600`. `glm-info` mostra a chave deliberadamente por conveniência; não compartilhe a saída. `glm-manage diagnose` não deve imprimir a API key nem o HF token.

## Imagens e modelo

Entradas principais são fixadas para impedir mudanças silenciosas:

```text
MODEL_REVISION=187fb9fff6319062325ff825627ef6db084d9bc6
VLLM_BASE_IMAGE=vllm/vllm-openai@sha256:2286e8533ca8b6bc777594bae30524f1426ba46ca21797524e06df6a94b06635
NGINX_IMAGE=nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de
VLLM_SOURCE_REF=2cf0a6915ce544dc493a0990f2ea38d81601128a
DEEPGEMM_REF=8b1392b978f5a03c828dd1711090d7fb50958b8a
```

O preflight rejeita `MODEL_REVISION=main` e imagens base sem digest neste perfil.

## Container

O vLLM usa GPUs e `ipc: host`, porém não `privileged: true`. Os caches persistentes são montados explicitamente. O DeepGEMM tem cache JIT próprio em `/var/lib/glm53-full/deepgemm-cache`.

## Mídia remota / SSRF

Defaults:

```text
ALLOWED_MEDIA_DOMAIN=media.invalid
VLLM_MEDIA_URL_ALLOW_REDIRECTS=0
```

Isso mantém URLs remotas efetivamente bloqueadas. Só libere um domínio quando a aplicação realmente precisar de mídia remota e preserve redirects desativados sempre que possível.

## Compatibilidade de agentes

O runtime derivado normaliza `assistant.content=null + tool_calls` antes do template. Também rejeita as flags legadas `enable_thinking` e `thinking`, que podem provocar vazamento de reasoning no GLM-5.3. O smoke test falha se detectar tags `<think>` em conteúdo normal ou streaming.

## Operações concorrentes

Instalação e comandos mutáveis usam `/var/lock/glm53-complete.lock` com `flock`. O objetivo é impedir updates/restarts concorrentes sobre a mesma imagem e o mesmo conjunto de containers.

## Update / rollback

`start`, `restart` e `apply` não puxam imagens. `glm-manage update` constrói uma candidata, valida-a e só então promove. Falha durante `docker compose up`, healthcheck ou smoke test entra no caminho de rollback quando existe imagem anterior. O rollback é confirmado por inferência real (`healthcheck --deep`), não apenas por `/v1/models`.

## Snapshot operacional

Depois da instalação, scripts/configuração ficam em `/opt/glm53-complete`. Isso remove a dependência operacional do clone Git e evita que apagar/mover a pasta original quebre o bind mount do Nginx ou os comandos globais.

## Branch principal

A proteção da branch é uma configuração do próprio GitHub, não do código dentro do repositório. Recomenda-se exigir o workflow `GLM 5.3 complete server CI` antes de aceitar alterações em `main`. O código não deve afirmar que essa proteção está ativa sem verificação na configuração do repositório.
