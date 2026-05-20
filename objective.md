# Docker Event Notifications

## Purpose

Monitor Docker container events and send notifications to external services.

The first supported notification target is Discord webhooks.

The project is designed to be extremely lightweight, simple, and suitable for homelab environments.

---

## Functional Requirements

- Listen to Docker container events
- Detect the following events:
  - start
  - stop
  - die
  - restart
- Send notifications to Discord webhook
- Ignore unrelated Docker events
- Run continuously without manual intervention
- Automatically reconnect if the Docker event stream is interrupted

---

## Architecture Requirements

- Run as its own Docker container
- Build as a custom Docker image
- Be compatible with GitHub Container Registry (GHCR)
- Use `.env` for configuration
- Never store secrets directly in code

---

## Security & Design Requirements

- No web UI
- No database
- No API server
- Minimal attack surface
- Docker socket mounted read-only
- Stable during Docker daemon reconnects

---

## Allowed Dependencies

Allowed:
- docker-cli
- curl
- jq
- sh / alpine

Not allowed:
- Heavy frameworks
- Node.js applications
- Python services
- Dashboards
- External SaaS dependencies

---

## Performance Requirements

- Very low CPU usage
- Event-driven architecture
- Minimal RAM usage
- Fast startup
- Stable for 24/7 runtime

---

## Notifications

- First notification target: Discord webhook
- Design should allow future support for additional notification channels

---

## Logging

- Simple console logging only
- No historical storage
- No metrics system

---

## Project Identity

- Project name: Docker Event Notifications
- Repository name: docker-send
- Container name: docker-send
- Description: Simple Event Notifications for Docker
