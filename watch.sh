#!/bin/sh

set -eu

echo "Starting docker-send..."

while true; do

  docker events \
    --filter type=container \
    --filter event=start \
    --filter event=stop \
    --filter event=die \
    --filter event=restart \
    --format '{{json .}}' |
  while read -r line
  do
    NAME=$(echo "$line" | jq -r '.Actor.Attributes.name // "unknown"')
    ACTION=$(echo "$line" | jq -r '.Action // "unknown"')

    # Ignore self
    [ "$NAME" = "docker-send" ] && continue

    MESSAGE="🐳 ${NAME} → ${ACTION}"

    PAYLOAD=$(jq -n \
      --arg content "$MESSAGE" \
      '{content: $content}')

    curl -sS \
      -H "Content-Type: application/json" \
      -X POST \
      -d "$PAYLOAD" \
      "$DISCORD_WEBHOOK" \
      > /dev/null || true

  done

  echo "Docker event stream disconnected. Reconnecting in 2 seconds..."
  sleep 2

done
