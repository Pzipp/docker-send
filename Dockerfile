FROM alpine:3.22

RUN apk add --no-cache \
    docker-cli \
    curl \
    jq

COPY watch.sh /watch.sh

RUN chmod +x /watch.sh

# Ensure script receives signals properly
STOPSIGNAL SIGTERM

CMD ["/watch.sh"]

# Health check to ensure process is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD pgrep -f "watch.sh" || exit 1
