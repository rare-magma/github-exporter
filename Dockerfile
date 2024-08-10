FROM docker.io/library/alpine:latest
ENV RUNNING_IN_DOCKER=true
ENTRYPOINT ["/bin/bash"]
CMD ["/app/github_exporter.sh"]
COPY github_exporter.sh /app/github_exporter.sh
RUN addgroup -g 10001 user \
    && adduser -H -D -u 10000 -G user user
RUN apk add --quiet --no-cache bash coreutils curl jq
USER user:user