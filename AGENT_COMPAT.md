# Compatibilidade com agentes

O servidor expõe o GLM-5.3 completo em formato OpenAI e incorpora proteções específicas para históricos de agentes.

## Raciocínio

Use:

```json
{
  "chat_template_kwargs": {
    "reasoning_effort": "low",
    "clear_thinking": true
  }
}
```

Valores recomendados do GLM-5.3: `low`, `high` e `max`.

Este runtime rejeita `chat_template_kwargs.enable_thinking` e `chat_template_kwargs.thinking`. Essas flags pertencem a fluxos/template antigos e, na família GLM-5.3, podem fazer o parser deixar de separar reasoning embora o modelo continue raciocinando. Isso pode contaminar `message.content` com scratchpad.

## `content=null` + tool calls

Clientes OpenAI costumam reenviar o turno do assistente assim:

```json
{
  "role": "assistant",
  "content": null,
  "tool_calls": [...]
}
```

Enquanto a correção upstream não estiver incorporada ao runtime usado, o servidor derivado normaliza esse `content` para `""` antes do chat template. Portanto os clientes não precisam implementar obrigatoriamente o workaround por conta própria; normalizar também no cliente continua inofensivo.

## Tool calling

O servidor usa:

```text
--tool-call-parser glm47
--enable-auto-tool-choice
--reasoning-parser glm45
```

`glm-manage test` valida duas etapas, não apenas a criação do tool call:

1. o modelo emite `tool_calls` + arguments JSON válidos;
2. o histórico é reenviado com `assistant.content=null`, recebe uma mensagem `role=tool` e precisa produzir uma resposta final correta.

Isso cobre o fluxo real de agentes que faltava no smoke test antigo.

## Streaming

O smoke test também usa `stream:true`, exige eventos SSE `data:`, marcador `[DONE]`, conteúdo esperado e ausência de tags `<think>` em `delta.content`.

## MTP

O perfil padrão mantém 5 draft tokens conforme o recipe atual. Se a VM real apresentar instabilidade específica de speculative decoding, o diagnóstico deve comparar MTP ligado/desligado alterando somente esse parâmetro e repetindo a mesma bateria de chat/tools/streaming.

## Atualizações

Depois de qualquer `glm-manage update`, a atualização só é aceita se o smoke test completo passar. Isso reduz o risco de uma mudança de runtime quebrar agentes silenciosamente.

Referências upstream:
- https://github.com/vllm-project/vllm/pull/54368
- https://github.com/vllm-project/vllm/pull/54825
