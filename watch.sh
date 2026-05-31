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
WINDOW_SECONDS=300
LAST_CLEANUP=0

# Initialize database if it doesn't exist
if [ ! -f "$DB_FILE" ]; then
  echo "{}" > "$DB_FILE"
fi

# Format timestamp as HH:MM:SS DD/MM-YYYY
format_timestamp() {
  date -d "@$1" "+%H:%M:%S %d/%m-%Y" 2>/dev/null || date -r "$1" "+%H:%M:%S %d/%m-%Y" 2>/dev/null || echo "Unknown"
}

# Get current Unix timestamp
get_timestamp() {
  date +%s
}

# Single unified Discord message sender
send_discord_message() {
  payload="$1"

  if ! curl -sS \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "$DISCORD_WEBHOOK" \
    -m 5 2>/dev/null; then
    echo "WARNING: Failed to send Discord message"
    return 1
  fi
  return 0
}

# Build and send container event notification
send_event_notification() {
  name="$1"
  action="$2"
  image="$3"
  exit_code="$4"
  timestamp="$5"

  # Map action to emoji and color
  case "$action" in
    start)   emoji="▶️"; color="65280";    description="$action" ;;
    stop)    emoji="⏹️"; color="16776960"; description="$action" ;;
    restart) emoji="🔄"; color="16711680"; description="$action" ;;
    die)     emoji="💀"; color="16711680"; description="$action" ;;
    *)       emoji="📦"; color="9807270";  description="$action" ;;
  esac

  # Add exit code to description if present
  if [ -n "$exit_code" ] && [ "$exit_code" != "null" ]; then
    description="$action (exit code: $exit_code)"
  fi

  formatted_time=$(format_timestamp "$timestamp")

  payload=$(jq -n \
    --arg emoji "$emoji" \
    --arg container "$name" \
    --arg image "$image" \
    --arg action "$action" \
    --arg description "$description" \
    --arg time "$formatted_time" \
    --argjson color "$color" \
    '{embeds:[{title:"\($emoji) \($container)",description:$description,color:$color,fields:[{name:"Image",value:$image,inline:true},{name:"Action",value:$action,inline:true}],footer:{text:$time}}]}')

  send_discord_message "$payload"
}

# Send restart loop warning
send_restart_loop_warning() {
  name="$1"
  timestamp="$2"
  formatted_time=$(format_timestamp "$timestamp")

  payload=$(jq -n \
    --arg container "$name" \
    --arg time "$formatted_time" \
    '{embeds:[{title:"🔴 RESTART LOOP DETECTED",description:"Container \($container) is in a restart loop",color:16711680,fields:[{name:"Container",value:$container,inline:true},{name:"Status",value:"Suppressing notifications",inline:true},{name:"Details",value:"More than 3 restarts in 5 minutes detected. Further notifications suppressed.",inline:false}],footer:{text:$time}}]}')

  send_discord_message "$payload"
}

# Send shutdown message
send_shutdown_message() {
  current_time=$(get_timestamp)
  formatted_time=$(format_timestamp "$current_time")

  payload=$(jq -n \
    --arg time "$formatted_time" \
    '{embeds:[{title:"🛑 docker-send is shutting down",description:"The docker-send event monitor has been stopped",color:9807270,fields:[{name:"Status",value:"Offline",inline:true},{name:"Note",value:"Will auto-restart if enabled",inline:true}],footer:{text:$time}}]}')

  send_discord_message "$payload"
}

# Parse single docker event with one jq call
parse_event() {
  line="$1"
  echo "$line" | jq -r '[.Actor.Attributes.name // "unknown", .Action // "unknown", .Actor.Attributes.image // "unknown", .Actor.Attributes.exitCode // "", .time // 0] | @csv'
}

# Clean up old entries from database
cleanup_database() {
  current_time=$(get_timestamp)
  cutoff_time=$((current_time - 300))

  db_content=$(cat "$DB_FILE")

  cleaned_db=$(echo "$db_content" | jq \
    --argjson cutoff "$cutoff_time" \
    'to_entries | map(select(.value.last_time > $cutoff)) | from_entries')

  echo "$cleaned_db" > "$DB_FILE"
}

# Get container state from database
get_container_state() {
  container_name="$1"
  db_content=$(cat "$DB_FILE")
  echo "$db_content" | jq -r ".\"$container_name\" | [.restarts // 0, .last_time // 0, .warned // false] | @csv"
}

# Update database with single write
update_database() {
  container_name="$1"
  restart_count="$2"
  timestamp="$3"
  warned="$4"

  db_content=$(cat "$DB_FILE")

  new_db=$(echo "$db_content" | jq \
    --arg container "$container_name" \
    --argjson count "$restart_count" \
    --argjson ts "$timestamp" \
    --argjson w "$warned" \
    '.[$container] = {restarts: $count, last_time: $ts, warned: $w}')

  echo "$new_db" > "$DB_FILE"
}

# Check if we should rate-limit this restart event
should_rate_limit_restart() {
  container_name="$1"
  current_time="$2"

  state=$(get_container_state "$container_name")

  # Parse CSV output: restart_count,last_time,warned
  restart_count=$(echo "$state" | cut -d',' -f1 | tr -d '"')
  last_time=$(echo "$state"     | cut -d',' -f2 | tr -d '"')
  warned=$(echo "$state"        | cut -d',' -f3 | tr -d '"')

  # Reset counter if outside the time window
  time_diff=$((current_time - last_time))
  if [ "$time_diff" -gt "$WINDOW_SECONDS" ]; then
    restart_count=0
    warned="false"
  fi

  restart_count=$((restart_count + 1))

  update_database "$container_name" "$restart_count" "$current_time" "$warned"

  if [ "$restart_count" -gt "$RESTART_THRESHOLD" ]; then
    if [ "$warned" = "false" ]; then
      echo "RESTART LOOP: $container_name has exceeded threshold"
      send_restart_loop_warning "$container_name" "$current_time"
      update_database "$container_name" "$restart_count" "$current_time" "true"
    fi
    echo "RATE_LIMITED: $container_name restarted $restart_count times in 5 minutes"
    return 0
  fi

  return 1
}

# Trap for graceful shutdown
trap 'echo "Received shutdown signal"; send_shutdown_message; exit 0' SIGTERM SIGINT

# Main event loop
while true; do
  echo "Connecting to Docker daemon..."

  docker events \
    --filter type=container \
    --filter event=start \
    --filter event=stop \
    --filter event=die \
    --filter event=restart \
    --format '{{json .}}' 2>/dev/null | while IFS= read -r line; do

    # Validate JSON
    if ! echo "$line" | jq empty 2>/dev/null; then
      echo "WARNING: Received invalid JSON from docker events"
      continue
    fi

    # Parse all fields
    parsed=$(parse_event "$line" | tr -d '"')

    NAME=$(echo "$parsed"      | cut -d',' -f1)
    ACTION=$(echo "$parsed"    | cut -d',' -f2)
    IMAGE=$(echo "$parsed"     | cut -d',' -f3)
    EXIT_CODE=$(echo "$parsed" | cut -d',' -f4)
    TIMESTAMP=$(echo "$parsed" | cut -d',' -f5)

    # Ignore self
    [ "$NAME" = "docker-send" ] && continue

    echo "Event: $NAME → $ACTION"

    # Rate-limit restart events
    if [ "$ACTION" = "restart" ]; then
      if should_rate_limit_restart "$NAME" "$(get_timestamp)"; then
        echo "Skipping notification (restart spam detected)"
        continue
      fi
    fi

    # Cleanup database periodically (every 50 events)
    LAST_CLEANUP=$((LAST_CLEANUP + 1))
    if [ "$LAST_CLEANUP" -ge 50 ]; then
      cleanup_database
      LAST_CLEANUP=0
    fi

    send_event_notification "$NAME" "$ACTION" "$IMAGE" "$EXIT_CODE" "$TIMESTAMP"

  done

  echo "Docker event stream disconnected. Reconnecting in 2 seconds..."
  sleep 2

done
