FROM golang:1.22-alpine AS build

ENV GOPROXY=https://goproxy.cn,direct
ENV GOSUMDB=sum.golang.google.cn
ENV GO111MODULE=on

WORKDIR /build

RUN apk add --no-cache git protobuf protobuf-dev

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.34.2 && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.4.0

COPY go.mod go.sum ./

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

COPY . .

RUN protoc -I . \
    --go_out=. --go_opt=module=im \
    --go-grpc_out=. --go-grpc_opt=module=im \
    ./proto/common.proto \
    ./proto/im.proto \
    ./proto/action.proto \
    ./proto/push.proto

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -o /im-server .

FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

COPY --from=build /im-server /usr/local/bin/im-server

EXPOSE 3004

ENTRYPOINT ["im-server"]