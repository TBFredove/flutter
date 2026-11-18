FROM golang:1.23-alpine AS builder
WORKDIR /app
ENV GOPROXY=https://goproxy.cn,direct CGO_ENABLED=0
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN go test ./... && go build -ldflags="-s -w" -o hengyang-backend .

FROM alpine:3.20
WORKDIR /app
RUN apk --no-cache add ca-certificates tzdata
ENV TZ=Asia/Shanghai
COPY --from=builder /app/hengyang-backend .
USER 10001:10001
EXPOSE 8000
CMD ["./hengyang-backend"]
