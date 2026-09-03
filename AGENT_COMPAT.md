# Compatibilidade com agentes

O servidor expõe o GLM-5.3 completo no formato OpenAI.

## Raciocínio

O GLM-5.3 mantém thinking ativo e oferece níveis via `reasoning_effort`: `low`, `high` e `max`. Para históricos reenviados, use `chat_template_kwargs.clear_thinking=true`.

Evite flags antigas `enable_thinking=false` / `thinking=false` até validar a versão instalada, pois houve incompatibilidades upstream entre template e reasoning parser na família GLM-5.3.

## `content=null` + tool calls

Clientes OpenAI podem armazenar uma mensagem de ferramenta com `assistant.content=null`. Para evitar templates que renderizem `None` literalmente em versões não corrigidas, normalize esse caso para string vazia no cliente:

```python
def normalize_glm_messages(messages):
    out = []
    for msg in messages:
        msg = dict(msg)
        if msg.get("role") == "assistant" and msg.get("tool_calls") and msg.get("content") is None:
            msg["content"] = ""
        out.append(msg)
    return out
```

## Tool calling

O servidor usa:

- `--tool-call-parser glm47`
- `--enable-auto-tool-choice`
- `--reasoning-parser glm45`

`./manage.sh test` força uma função nomeada e valida `tool_calls` + `arguments` JSON. Execute esse teste sempre após atualizar o runtime.

## MTP

O perfil padrão usa 5 draft tokens conforme o recipe atual do GLM-5.3. Se houver instabilidade específica de speculative decoding na VM real, a primeira comparação diagnóstica deve ser desligar MTP temporariamente e repetir chat/tool calling, sem alterar outros parâmetros ao mesmo tempo.
