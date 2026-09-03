#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_env

if ! docker info >/dev/null 2>&1 && [[ "${EUID}" -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi
ORIGIN="$(api_origin)"
RUNNING_SERVICES="$(docker compose --env-file "$ROOT_DIR/.env" -f "$ROOT_DIR/docker-compose.yml" ps --services --status running)"
grep -qx 'vllm' <<<"$RUNNING_SERVICES" || die "Container vllm não está em execução."
grep -qx 'gateway' <<<"$RUNNING_SERVICES" || die "Container gateway não está em execução."
curl --fail-with-body -sS --max-time 15 -H "Authorization: Bearer ${API_KEY}" "${ORIGIN}/v1/models" >/dev/null || die "API ainda não respondeu em ${ORIGIN}/v1/models."

if [[ "${1:-}" == "--deep" ]]; then
  RESPONSE="$(curl --fail-with-body -sS --max-time 600 "${ORIGIN}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$(jq -nc --arg model "${SERVED_MODEL_NAME:-glm-5.3}" '{model:$model,messages:[{role:"user",content:"Responda incluindo exatamente HEALTH_OK."}],max_tokens:128,temperature:1.0,chat_template_kwargs:{reasoning_effort:"low",clear_thinking:true}}')")")"
  printf '%s\n' "$RESPONSE" | jq -e '.choices[0].message.content | strings | contains("HEALTH_OK")' >/dev/null || die "API respondeu /v1/models, mas a inferência real falhou no healthcheck profundo."
  printf '%s\n' "$RESPONSE" | jq -e '(.choices[0].message.content // "") | (contains("<think") or contains("</think>")) | not' >/dev/null || die "Raciocínio bruto vazou para message.content."
  log "API + inferência saudáveis em ${ORIGIN}/v1"
else
  log "API pronta em ${ORIGIN}/v1 (healthcheck superficial)."
fi
