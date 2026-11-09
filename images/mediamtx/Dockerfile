# Drop this image once a MediaMTX release ships go-astits v1.17.0 or later.
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine AS build
RUN apk add --no-cache git
ARG MEDIAMTX_VERSION=v1.21.3
ARG MEDIAMTX_COMMIT=9540cb6c1d9f1e9351fcc4ded3afc249ffff22bc
ARG ASTITS_VERSION=v1.17.0
RUN git clone --depth 1 --branch "$MEDIAMTX_VERSION" https://github.com/bluenviron/mediamtx /src \
  && test "$(git -C /src rev-parse HEAD)" = "$MEDIAMTX_COMMIT"
WORKDIR /src
# generate first, so the version is read from a clean tree (no -dirty suffix)
RUN go generate ./... && go get "github.com/asticode/go-astits@$ASTITS_VERSION"
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags "-s -w" -o /out/mediamtx . \
  && cp mediamtx.yml LICENSE /out/

FROM scratch
COPY --from=build /out/ /
ENTRYPOINT ["/mediamtx"]
