# docker-send

Simple Event Notifications for Docker.

## Features

- Lightweight Docker event monitoring
- Discord webhook notifications
- No UI
- No database
- Low CPU and memory usage
- Automatic reconnect handling
- Event-driven architecture

## Supported Events

- start
- stop
- die
- restart

## Planned Features

- Additional notification targets
- Filtering
- Improved formatting
- Exit code reporting

## Example Usage

```yaml
services:
  docker-send:
    image: ghcr.io/pzipp/docker-send:latest

    container_name: docker-send

    restart: unless-stopped

    env_file:
      - .env

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

## Environment Variables

```env
DISCORD_WEBHOOK=https://discord.com/api/webhooks/XXXX/YYYY
```

## Security Notes

This project requires access to the Docker socket.

Use only trusted images and mount the socket as read-only:

```yaml
/var/run/docker.sock:/var/run/docker.sock:ro
```
