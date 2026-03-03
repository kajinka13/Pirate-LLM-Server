#!/bin/bash
# Simple chat client for LLM Server
SERVER="${LLM_SERVER:-http://192.168.1.54:8080}"

if [ -z "$1" ]; then
    echo "Usage: ./chat.sh \"your question here\""
    exit 1
fi

PROMPT="$1"
echo -e "\033[1;34mYou:\033[0m $PROMPT"
echo -e "\033[1;32mAI:\033[0m \c"

# Build JSON with python to handle special chars safely
JSON=$(python3 -c "
import json, sys
print(json.dumps({
    'model': 'qwen3.5-2b',
    'messages': [{'role': 'user', 'content': sys.argv[1]}],
    'max_tokens': 500,
    'stream': True
}))
" "$PROMPT")

curl -sN "$SERVER/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$JSON" \
  | while IFS= read -r line; do
    line="${line#data: }"
    [ -z "$line" ] && continue
    [ "$line" = "[DONE]" ] && echo && break
    printf '%s' "$(echo "$line" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['delta'].get('content', ''), end='')
except: pass
" 2>/dev/null)"
  done
