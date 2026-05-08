FROM golang:1.22-alpine AS build
WORKDIR /build
RUN apk add --no-cache git protobuf protobuf-dev
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.34.2 && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.4.0
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN protoc -I . --go_out=. --go_opt=module=im --go-grpc_out=. --go-grpc_opt=module=im \
    ./proto/common.proto ./proto/im.proto ./proto/action.proto ./proto/push.proto
RUN CGO_ENABLED=0 go build -o /im-server .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=build /im-server /usr/local/bin/im-server

EXPOSE 3004

ENTRYPOINT ["im-server"]