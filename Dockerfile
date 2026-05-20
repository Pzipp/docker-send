FROM alpine:3.22

RUN apk add --no-cache \
    docker-cli \
    curl \
    jq

COPY watch.sh /watch.sh

RUN chmod +x /watch.sh

CMD ["/watch.sh"]
