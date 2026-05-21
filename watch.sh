#!/bin/sh

set -eu

echo "Starting docker-send..."

# Validate DISCORD_WEBHOOK on startup
if [ -z "${DISCORD_WEBHOOK:-}" ]; then
  echo "ERROR: DISCORD_WEBHOOK environment variable is not set!"
  exit 1
fi

# Trap for graceful shutdown
trap 'echo "Shutting down..."; exit 0' SIGTERM SIGINT

send_notification() {
  local name="$1"
  local action="$2"
  local message="🐳 ${name} → ${action}"
  
  local payload
  payload=$(jq -n --arg content "$message" '{content: $content}')
  
  if ! curl -sS \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "$DISCORD_WEBHOOK" \
    -m 5 \
    -w "\n%{http_code}" 2>/dev/null; then
    echo "WARNING: Failed to send notification for $name ($action)"
    return 1
  fi
  return 0
}

# Main reconnect loop
while true; do
  echo "Connecting to Docker daemon..."
  
  # Use timeout to prevent hanging
  # Reconnect after 5 minutes (300s) of inactivity
  if timeout 300 docker events \
    --filter type=container \
    --filter event=start \
    --filter event=stop \
    --filter event=die \
    --filter event=restart \
    --format '{{json .}}' 2>/dev/null | while IFS= read -r line; do
    
    # Validate JSON
    if ! jq empty <<< "$line" 2>/dev/null; then
      echo "WARNING: Received invalid JSON from docker events"
      continue
    fi
    
    NAME=$(echo "$line" | jq -r '.Actor.Attributes.name // "unknown"')
    ACTION=$(echo "$line" | jq -r '.Action // "unknown"')
    
    # Ignore self
    [ "$NAME" = "docker-send" ] && continue
    
    echo "Event: $NAME → $ACTION"
    send_notification "$NAME" "$ACTION"
    
  then
    # If timeout or normal exit
    echo "Docker event stream disconnected (timeout after 5 minutes)."
  else
    # If docker events command failed
    echo "Docker event stream disconnected (error or Docker daemon unavailable)."
  fi
  
  echo "Reconnecting in 2 seconds..."
  sleep 2
  
done
