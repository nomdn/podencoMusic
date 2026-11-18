# 多阶段构建：编译环境有 Go，运行镜像里只有二进制和证书。
# 用 distroless 的 static 镜像，体积约 3MB，也没有 shell 可以给攻击者用。
FROM golang:1.26-alpine AS build

WORKDIR /src

# CI 在海外跑时可覆盖为 https://proxy.golang.org,direct
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=${GOPROXY}

# 先只拷依赖清单，让 go mod download 这一层能被缓存住
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO_ENABLED=0：全部用 netgo，静态链接后不依赖目标机的 glibc
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/biliproxy .

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/biliproxy /biliproxy

# 会话和访客凭证落在这里，挂个卷才有意义
VOLUME ["/data"]
WORKDIR /data

EXPOSE 8787

ENTRYPOINT ["/biliproxy"]
CMD ["-addr", ":8787", "-state", "/data/state.json"]
