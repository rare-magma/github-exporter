FROM docker.io/library/golang:alpine AS builder
WORKDIR /app
ENV CGO_ENABLED=0
COPY main.go go.mod ./
RUN go build -ldflags "-s -w" -trimpath -o app main.go

FROM cgr.dev/chainguard/static:latest
COPY --from=builder /app/app /usr/bin/app
ENTRYPOINT ["/usr/bin/app"]