# MediaMTX built with go-astits v1.17.0. Releases up to v1.21.3 ship v1.16.0, which drops an
# unbounded PES (any frame over 64 KB, so most AMD keyframes) when the next PES fits in one packet.
# Drop this image once a MediaMTX release has go-astits v1.17.0 or later.
FROM golang:1.27.3-alpine AS build
RUN apk add --no-cache git
ARG MEDIAMTX_VERSION=v1.21.3
RUN git clone --depth 1 --branch "$MEDIAMTX_VERSION" https://github.com/bluenviron/mediamtx /src
WORKDIR /src
# generate first, so the version is read from a clean tree (no -dirty suffix)
RUN go generate ./... \
  && go get github.com/asticode/go-astits@v1.17.0 \
  && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/mediamtx . \
  && cp mediamtx.yml LICENSE /out/

FROM scratch
COPY --from=build /out/ /
ENTRYPOINT ["/mediamtx"]
