#!/bin/sh

set -eu

echo "Starting docker-send..."

# Validate DISCORD_WEBHOOK on startup
if [ -z "${DISCORD_WEBHOOK:-}" ]; then
  echo "ERROR: DISCORD_WEBHOOK environment variable is not set!"
  exit 1
fi

# Database file for tracking events
DB_FILE=".events.db"
RESTART_THRESHOLD=3
WINDOW_SECONDS=60

# Initialize database if it doesn't exist
if [ ! -f "$DB_FILE" ]; then
  echo "{}" > "$DB_FILE"
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

# Get current Unix timestamp
get_timestamp() {
  date +%s
}

# Check if we should rate-limit this restart event
should_rate_limit_restart() {
  local container_name="$1"
  local current_time
  current_time=$(get_timestamp)
  
  # Read database
  local db_content
  db_content=$(cat "$DB_FILE")
  
  # Get restart count for this container in the window
  local restart_count
  restart_count=$(echo "$db_content" | jq -r ".\"$container_name\".restarts // 0" 2>/dev/null || echo "0")
  
  # Get last restart timestamp
  local last_restart
  last_restart=$(echo "$db_content" | jq -r ".\"$container_name\".last_time // 0" 2>/dev/null || echo "0")
  
  # Calculate time since last restart
  local time_diff=$((current_time - last_restart))
  
  # If more than WINDOW_SECONDS have passed, reset counter
  if [ "$time_diff" -gt "$WINDOW_SECONDS" ]; then
    restart_count=0
  fi
  
  # Increment restart count
  restart_count=$((restart_count + 1))
  
  # Update database with new restart count
  local new_db
  new_db=$(echo "$db_content" | jq \
    --arg container "$container_name" \
    --argjson count "$restart_count" \
    --argjson timestamp "$current_time" \
    '.[$container] = {restarts: $count, last_time: $timestamp}')
  
  echo "$new_db" > "$DB_FILE"
  
  # Return 0 (true) if we should rate-limit (threshold exceeded)
  # Return 1 (false) if we should allow the notification
  if [ "$restart_count" -gt "$RESTART_THRESHOLD" ]; then
    echo "RATE_LIMITED: $container_name has restarted $restart_count times in ${WINDOW_SECONDS}s"
    return 0
  fi
  
  return 1
}

# Clean up old entries from database (keep entries from last 5 minutes)
cleanup_database() {
  local current_time
  current_time=$(get_timestamp)
  local cutoff_time=$((current_time - 300))
  
  local db_content
  db_content=$(cat "$DB_FILE")
  
  local cleaned_db
  cleaned_db=$(echo "$db_content" | jq \
    --argjson cutoff "$cutoff_time" \
    'to_entries | map(select(.value.last_time > $cutoff)) | from_entries')
  
  echo "$cleaned_db" > "$DB_FILE"
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
    
    # Rate-limit restart events
    if [ "$ACTION" = "restart" ]; then
      if should_rate_limit_restart "$NAME"; then
        echo "Skipping notification (restart spam detected)"
        continue
      fi
    fi
    
    # Clean up database every 10th event
    if [ $((RANDOM % 10)) -eq 0 ]; then
      cleanup_database
    fi
    
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
