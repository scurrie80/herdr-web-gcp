# herdr-iap-proxy: tsnet + reverse proxy, built static and shipped on distroless.
# Build:  docker build --platform linux/amd64 -t herdr-iap-proxy .
#
# Both base images are pinned by digest (multi-arch index digest, so
# --platform still selects linux/amd64) so a rebuild of the same commit gives the
# same image. To take an update, resolve the new digest and change it here:
#   docker buildx imagetools inspect golang:1.27.2 --format '{{.Manifest.Digest}}'
#   docker buildx imagetools inspect gcr.io/distroless/static-debian12:nonroot --format '{{.Manifest.Digest}}'
FROM golang:1.27.2@sha256:820153096fda4de6ac1b7194d12e416b7dd8f4e9a33d17e0345b111b945162d8 AS build
ENV GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN go vet ./... && go build -trimpath -ldflags="-s -w" -o /herdr-iap-proxy .

# static-debian12 carries CA roots (needed for the Let's Encrypt cert on the
# Tailscale Serve endpoint) and nothing else. /tmp is writable at runtime on
# Cloud Run; tsnet state lives there and is disposable.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /herdr-iap-proxy /herdr-iap-proxy
USER nonroot:nonroot
ENTRYPOINT ["/herdr-iap-proxy"]
