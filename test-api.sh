#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_env
ORIGIN="$(api_origin)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

assert_clean_content() {
  local response="$1" required_token="$2" label="$3"
  printf '%s\n' "$response" | jq -e --arg token "$required_token" \
    '.choices[0].message.content | select(type=="string" and contains($token))' >/dev/null \
    || die "${label}: resposta não contém o token obrigatório ${required_token}."
  printf '%s\n' "$response" | jq -e \
    '(.choices[0].message.content // "") | (contains("<think") or contains("</think>")) | not' >/dev/null \
    || die "${label}: raciocínio bruto vazou para message.content."
}

status="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "${ORIGIN}/v1/models")"
[[ "$status" == "401" || "$status" == "403" ]] || die "A API deveria rejeitar /v1/models sem chave; HTTP: $status."
status="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "${ORIGIN}/invocations")"
[[ "$status" == "404" ]] || die "Gateway deveria bloquear /invocations; HTTP: $status."
curl --fail-with-body -sS --max-time 30 -H "Authorization: Bearer ${API_KEY}" "${ORIGIN}/v1/models" >/dev/null

log "Testando chat com reasoning_effort=low..."
LOW_RESPONSE="$(curl --fail-with-body -sS --max-time 600 "${ORIGIN}/v1/chat/completions" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${API_KEY}" \
  -d "$(jq -nc --arg model "${SERVED_MODEL_NAME:-glm-5.3}" '{model:$model,messages:[{role:"user",content:"Responda de forma curta e inclua exatamente a expressão GLM MAX OK."}],temperature:1.0,top_p:0.95,max_tokens:256,chat_template_kwargs:{reasoning_effort:"low",clear_thinking:true}}')")"
printf '%s\n' "$LOW_RESPONSE" | jq .
assert_clean_content "$LOW_RESPONSE" "GLM MAX OK" "Chat low"

log "Testando chat com reasoning_effort=max..."
MAX_RESPONSE="$(curl --fail-with-body -sS --max-time 900 "${ORIGIN}/v1/chat/completions" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${API_KEY}" \
  -d "$(jq -nc --arg model "${SERVED_MODEL_NAME:-glm-5.3}" '{model:$model,messages:[{role:"user",content:"Calcule 17 + 25 e termine a resposta incluindo exatamente GLM_MAX_REASONING_OK."}],temperature:1.0,top_p:0.95,max_tokens:512,chat_template_kwargs:{reasoning_effort:"max",clear_thinking:true}}')")"
printf '%s\n' "$MAX_RESPONSE" | jq .
assert_clean_content "$MAX_RESPONSE" "GLM_MAX_REASONING_OK" "Chat max"

log "Testando OpenAI Responses API..."
RESPONSES_RESPONSE="$(curl --fail-with-body -sS --max-time 600 "${ORIGIN}/v1/responses" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${API_KEY}" \
  -d "$(jq -nc --arg model "${SERVED_MODEL_NAME:-glm-5.3}" '{model:$model,input:[{role:"user",content:"Responda de forma curta e inclua exatamente RESPONSES_OK."}],max_output_tokens:256,reasoning:{effort:"low"}}')")"
printf '%s\n' "$RESPONSES_RESPONSE" | jq .
RESPONSES_TEXT="$(printf '%s\n' "$RESPONSES_RESPONSE" | jq -r '[.output[]? | select(.type=="message") | .content[]? | select(.type=="output_text") | .text] | join("")')"
[[ "$RESPONSES_TEXT" == *"RESPONSES_OK"* ]] || die "Responses API não retornou RESPONSES_OK."
[[ "$RESPONSES_TEXT" != *"<think"* && "$RESPONSES_TEXT" != *"</think>"* ]] || die "Responses API vazou tags de raciocínio."

log "Confirmando rejeição das flags antigas de thinking..."
LEGACY_BODY="$TMPDIR_TEST/legacy.json"
status="$(curl -sS --max-time 60 -o "$LEGACY_BODY" -w '%{http_code}' "${ORIGIN}/v1/chat/completions" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${API_KEY}" \
  -d "$(jq -nc --arg model "${SERVED_MODEL_NAME:-glm-5.3}" '{model:$model,messages:[{role:"user",content:"teste"}],max_tokens:16,chat_template_kwargs:{enable_thinking:false}}')")"
[[ "$status" == "400" || "$status" == "422" ]] || {
  cat "$LEGACY_BODY" >&2 || true
  die "Flags antigas de thinking deveriam ser rejeitadas pelo runtime GLM-5.3; HTTP: $status."
}

log "Testando tool calling nomeado..."
TOOL_DEF='[{"type":"function","function":{"name":"get_test_value","description":"Ferramenta de smoke test.","parameters":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}}}]'
TOOL_RESPONSE="$(curl --fail-with-body -sS --max-time 600 "${ORIGIN}/v1/chat/completions" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${API_KEY}" \
  -d "$(jq -nc --arg model "${SERVED_MODEL_NAME:-glm-5.3}" --argjson tools "$TOOL_DEF" '{model:$model,messages:[{role:"user",content:"Chame get_test_value. Depois do resultado da ferramenta, repita exatamente o token recebido."}],tools:$tools,tool_choice:{type:"function",function:{name:"get_test_value"}},max_tokens:256,chat_template_kwargs:{reasoning_effort:"low",clear_thinking:true}}')")"
printf '%s\n' "$TOOL_RESPONSE" | jq .
printf '%s\n' "$TOOL_RESPONSE" | jq -e '.choices[0].message.tool_calls[0].function | (.name == "get_test_value") and (.arguments | type == "string" and length > 0)' >/dev/null \
  || die "Tool calling não retornou a função no formato OpenAI esperado."
TOOL_ARGUMENTS="$(printf '%s\n' "$TOOL_RESPONSE" | jq -r '.choices[0].message.tool_calls[0].function.arguments')"
printf '%s' "$TOOL_ARGUMENTS" | jq -e 'type == "object" and has("value")' >/dev/null || die "Tool calling retornou arguments inválidos."
TOOL_CALLS="$(printf '%s\n' "$TOOL_RESPONSE" | jq -c '.choices[0].message.tool_calls')"
TOOL_CALL_ID="$(printf '%s\n' "$TOOL_RESPONSE" | jq -r '.choices[0].message.tool_calls[0].id')"
[[ -n "$TOOL_CALL_ID" && "$TOOL_CALL_ID" != "null" ]] || die "Tool call não retornou id válido."

log "Testando ciclo completo tool_calls -> tool result -> resposta final com content=null..."
TOOL_LOOP_PAYLOAD="$(jq -nc \
  --arg model "${SERVED_MODEL_NAME:-glm-5.3}" \
  --arg tool_call_id "$TOOL_CALL_ID" \
  --argjson tool_calls "$TOOL_CALLS" \
  --argjson tools "$TOOL_DEF" \
  '{model:$model,messages:[
    {role:"user",content:"Chame get_test_value. Depois do resultado da ferramenta, repita exatamente o token recebido."},
    {role:"assistant",content:null,tool_calls:$tool_calls},
    {role:"tool",tool_call_id:$tool_call_id,content:"TOOL_LOOP_OK"}
  ],tools:$tools,tool_choice:"none",max_tokens:256,chat_template_kwargs:{reasoning_effort:"low",clear_thinking:true}}')"
TOOL_LOOP_RESPONSE="$(curl --fail-with-body -sS --max-time 600 "${ORIGIN}/v1/chat/completions" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${API_KEY}" \
  -d "$TOOL_LOOP_PAYLOAD")"
printf '%s\n' "$TOOL_LOOP_RESPONSE" | jq .
assert_clean_content "$TOOL_LOOP_RESPONSE" "TOOL_LOOP_OK" "Ciclo completo de tools"

log "Testando streaming SSE..."
STREAM_FILE="$TMPDIR_TEST/stream.txt"
curl --fail-with-body -sS -N --max-time 600 "${ORIGIN}/v1/chat/completions" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${API_KEY}" \
  -d "$(jq -nc --arg model "${SERVED_MODEL_NAME:-glm-5.3}" '{model:$model,messages:[{role:"user",content:"Responda somente STREAM_OK."}],stream:true,max_tokens:128,chat_template_kwargs:{reasoning_effort:"low",clear_thinking:true}}')" \
  >"$STREAM_FILE"
grep -q '^data:' "$STREAM_FILE" || die "Streaming não retornou eventos SSE data:."
grep -q '\[DONE\]' "$STREAM_FILE" || die "Streaming não terminou com [DONE]."
STREAM_CONTENT="$(grep '^data: ' "$STREAM_FILE" | sed 's/^data: //' | grep -v '^\[DONE\]$' | jq -r '.choices[0].delta.content // empty' | tr -d '\n')"
[[ "$STREAM_CONTENT" == *"STREAM_OK"* ]] || die "Streaming não retornou o conteúdo esperado STREAM_OK."
[[ "$STREAM_CONTENT" != *"<think"* && "$STREAM_CONTENT" != *"</think>"* ]] || die "Streaming vazou tags de raciocínio no conteúdo."

log "Smoke test completo OK: auth, gateway, models, Chat low/max, Responses API, guard de thinking, tools multi-turn e streaming."
