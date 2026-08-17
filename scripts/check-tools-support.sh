#!/usr/bin/env bash
#
# Проверяет, поддерживает ли OpenAI-совместимый endpoint tool-calling.
#
# Запускать ДО установки агента. Агент без tools не может ни писать файлы,
# ни выполнять команды — но об этом не знает и будет уверенно рапортовать
# об успехе. Десять секунд здесь экономят полдня отладки.
#
# Использование:
#   ./check-tools-support.sh <base_url> <model> <api_key>
#
# Примеры:
#   ./check-tools-support.sh https://api.deepseek.com deepseek-chat sk-...
#   ./check-tools-support.sh https://openrouter.ai/api/v1 anthropic/claude-sonnet-5 sk-or-...
#   ./check-tools-support.sh https://api.closerouter.dev/v1 google/gemini-3-flash-preview sk-...
#
set -euo pipefail

BASE_URL="${1:-}"
MODEL="${2:-}"
API_KEY="${3:-}"

if [ -z "$BASE_URL" ] || [ -z "$MODEL" ] || [ -z "$API_KEY" ]; then
  echo "Usage: $0 <base_url> <model> <api_key>" >&2
  exit 1
fi

BASE_URL="${BASE_URL%/}"

read -r -d '' PAYLOAD <<EOF || true
{
  "model": "${MODEL}",
  "messages": [{"role": "user", "content": "What is the weather in Paris? Use the tool."}],
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get the current weather in a location",
      "parameters": {
        "type": "object",
        "properties": {"location": {"type": "string"}},
        "required": ["location"]
      }
    }
  }]
}
EOF

echo "Endpoint: ${BASE_URL}/chat/completions"
echo "Model:    ${MODEL}"
echo

RESPONSE=$(curl -sS -w $'\n%{http_code}' "${BASE_URL}/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

HTTP_CODE=$(printf '%s' "$RESPONSE" | tail -n1)
BODY=$(printf '%s' "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL — HTTP ${HTTP_CODE}"
  echo
  echo "$BODY"
  echo
  echo "Endpoint не принял запрос с 'tools'. Агент на нём работать не будет."
  echo "Ищите другого провайдера или другой endpoint у этого же."
  exit 1
fi

# 200 — но надо убедиться, что модель реально вызвала инструмент, а не
# отписалась текстом. Провайдер может принять параметр и молча его выбросить.
if printf '%s' "$BODY" | grep -q '"tool_calls"'; then
  echo "OK — endpoint принял 'tools' и модель вызвала инструмент."
  echo "Можно ставить агента."
  exit 0
fi

echo "WARNING — HTTP 200, но в ответе нет 'tool_calls'."
echo
echo "$BODY"
echo
echo "Возможно, провайдер принимает параметр 'tools', но игнорирует его."
echo "Это худший случай: ошибки не будет, а агент останется без рук."
echo "Проверьте ответ вручную перед установкой."
exit 2
