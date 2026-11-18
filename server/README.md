# Podenco B站反代

给播客/音乐客户端用的哔哩哔哩网关。**存在的唯一理由**：浏览器做不到的事，服务端可以做。

## 为什么需要它

网页版的 Podenco Music 直连 B站时，会连着撞三堵墙，每一堵单独都能让功能不可用：

| 墙 | 现象 | 原因 |
|---|---|---|
| 接口 | 搜索一律 412 / 403 | B站风控见到 `Origin` 头就拒；浏览器跨域 `fetch` **必然**带 Origin |
| 媒体 | 音频/视频 403 | CDN 要求 `Referer: https://www.bilibili.com/video/BV…/`，而 `Referer` 是浏览器禁止 JS 修改的头 |
| 登录 | 二维码都生成不出来 | `passport.bilibili.com` 同样拦 Origin；`Cookie` 也是禁止头，跨域 `Set-Cookie` 会被直接丢弃 |

这三件事在服务端视角下都不存在 —— `Cookie`、`Referer`、`Origin` 只是普通字符串。
所以把请求搬到服务端，前端只跟自己域名说话，三堵墙一起消失。

## 快速开始

```bash
cd server
go build -o biliproxy .
./biliproxy                    # 默认监听 :8787
```

要部署到 ARM 机器（树莓派、Oracle 免费 ARM 实例、鲲鹏等）就交叉编译，
纯 Go + `CGO_ENABLED=0`，不需要目标机工具链：

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o biliproxy-linux-arm64 .
```

Release 页里 `biliproxy-linux-amd64` 和 `biliproxy-linux-arm64` 都有。

浏览器打开 `http://127.0.0.1:8787/healthz` 应返回：

```json
{"ok":true,"service":"podenco-bili-proxy","uptime_s":3,"version":"1.0.0"}
```

命令行参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-addr` | `:8787` | 监听地址。只给自己用可以写 `127.0.0.1:8787` |
| `-state` | `state.json` | 会话与访客凭证的落盘文件。留空则不落盘（重启即掉登录） |
| `-token` | 空 | 共享密钥。设置后客户端须带 `X-Token` 头。**公网部署务必设置** |
| `-rate` | 240 | 每 IP 每分钟 API 请求上限，0 为不限 |
| `-media-rate` | 900 | 每 IP 每分钟媒体请求上限，0 为不限 |

## 前端怎么接

在应用的「设置 → 哔哩哔哩数据源 → 接口反代」里填入地址即可，例如 `https://bili.example.com`。
配置存在本地，点「测试」会先探一次 `/healthz`，连不通就不会写入 —— 不会因为填错一个字把数据源弄坏。

不填就是直连 B站，行为和以前完全一致。

### 媒体流只有 Web 需要反代

B站视频/音频 CDN 会校验 `Referer`，所以「音源地址」是否需要过反代，取决于
播放器能不能自己带请求头：

| 平台 | 播放器 | 媒体流 |
|---|---|---|
| Web | `<video>` / `<audio>` | **必须**过反代（浏览器设不了请求头） |
| Windows / Linux / Android | libmpv（media_kit） | 直连，Referer / UA 由 mpv 自己带 |

也就是说，桌面和手机端即使填了反代，也只有 API 请求会走这里，媒体流仍走直连 ——
既省反代带宽，也少一跳。

## 接口

### 透明反代

把上游域名换成路径前缀，**其余一个字节都不改**：

| 本地 | 上游 |
|---|---|
| `/bili/api/*` | `https://api.bilibili.com/*` |
| `/bili/passport/*` | `https://passport.bilibili.com/*` |
| `/bili/app/*` | `https://app.bilibili.com/*` |
| `/bili/www/*` | `https://www.bilibili.com/*` |
| `/bili/search/*` | `https://search.bilibili.com/*` |

请求头由服务端统一设置（UA、Referer、Origin、`sec-ch-ua`）。Referer 会按上下文推断：
query 里有 `bvid` 就拼成该视频页，搜索接口用 `search.bilibili.com`，其余用根域名。
这不是讲究，是必需 —— 给错了一律 403 或返回风控页。

### 媒体流

```
GET /bili/media/<bvid>?u=<urlencoded>&u=<urlencoded>&kind=audio|video
```

- `u` 可以重复。`playurl` 会同时给主站 CDN 和几个 PCDN 备用地址，都是同一份资源的镜像；
  服务端按顺序试，谁通用谁。某个节点抽风不会变成「这首放不了」。
- 透传 `Range`，回 `Content-Range` / `Accept-Ranges`，所以进度条能拖。
- `Content-Type` 从上游的 `application/octet-stream` 明确成 `audio/mp4` / `video/mp4`，
  否则 Media Foundation、ExoPlayer 会靠嗅探去猜，猜错就是静默失败。
- **`u` 有 HTTPS + 域名白名单双重校验**，只放行 `*.bilivideo.com`、`*.hdslb.com` 这类 CDN。
  否则这个接口就成了「以服务器身份访问任意内网地址」的跳板。

### 会话

会话是「谁用哪个 Cookie」的唯一依据 —— 服务端**不认识用户**，只认这张随机票。
同一台机器重装应用就会拿到一张全新的票，旧的那张 30 天后回收。

```bash
# 新建
curl -X POST http://127.0.0.1:8787/bili/session
# {"sid":"4f525ae1…","expires":2592000}

# 查状态
curl -H "X-Session: <sid>" http://127.0.0.1:8787/bili/session
# {"known":true,"logged_in":false,"uid":""}

# 登出（只清凭证，会话本身保留）
curl -X DELETE -H "X-Session: <sid>" http://127.0.0.1:8787/bili/session

# 把客户端本地存的凭证补回会话
curl -X POST -H "X-Session: <sid>" -H "Content-Type: application/json" \
     -d '{"cookie":"SESSDATA=…; bili_jct=…","mid":"12345"}' \
     http://127.0.0.1:8787/bili/session/import
# {"imported":4,"logged_in":true}
```

之后所有请求带上 `X-Session` 头，服务端就会用这个会话的 Cookie 访问 B站。
用头而不是 Cookie 传递，是因为跨域场景下第三方 Cookie 基本已被浏览器禁掉。

#### `X-Session-Known`

只要请求带了 sid，响应就会多一个头：

| 值 | 含义 |
|---|---|
| `1` | 服务端认识这张票 |
| `0` | **服务端不认识** —— 通常是重启后 state 没落盘，或者换了一台反代 |

`0` 必须处理。不处理的话请求照样 200，只是被降级成匿名：用户看到「收藏空了、
字幕没了」，设置页却还写着「已登录」，几乎没法自己查出原因。客户端应该重建会话、
把本地凭证经 `/bili/session/import` 推回去，然后重试原请求。

这个接口**只写不读** —— 只能往自己的会话里投凭证，不能读别人的。
响应里也只返回条数和登录态，不回显任何 cookie 内容。

#### 登录流程

和原生完全一样：`/bili/passport/x/passport-login/web/qrcode/generate` 拿二维码，
轮询 `.../poll`。服务端会在 poll 的响应体里顺手把 `SESSDATA` 抠出来存进会话 ——
B站的扫码结果把 cookie 放在 `data.url` 的查询串里，响应头并没有 `Set-Cookie`。

扫码这一步**不经过本服务**：二维码指向 B站自己的域名，手机 App 直接和 B站通信。
所以账号密码从未离开 B站，这里拿到的只是它签发的会话凭证。

## 部署

公网使用时**必须**套一层 HTTPS，否则浏览器会拦混合内容。
最小配置（Nginx + systemd）：

```nginx
server {
    listen 443 ssl http2;
    server_name bili.example.com;

    ssl_certificate     /etc/letsencrypt/live/bili.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bili.example.com/privkey.pem;

    # 媒体流是长连接，别让 Nginx 提前掐断
    proxy_read_timeout 300s;
    proxy_http_version 1.1;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        # 限流按真实 IP 算，不传这个所有用户会共用一个桶
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

```ini
# /etc/systemd/system/biliproxy.service
[Unit]
Description=Podenco Bilibili Proxy
After=network-online.target

[Service]
User=biliproxy
WorkingDirectory=/opt/biliproxy
ExecStart=/opt/biliproxy/biliproxy -addr 127.0.0.1:8787 -state /var/lib/biliproxy/state.json -token 换成你的长随机串
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Docker

每次推送 `v*` 标签时，GitHub Actions 会把镜像发布到 GitHub Container Registry：

```bash
# 私有仓库需先登录：docker login ghcr.io（PAT 需要 read:packages 权限）
docker pull ghcr.io/nomdn/podenco-music-proxy:latest
docker run -d -p 8787:8787 \
  -e BILI_TOKEN=你的长随机串 \
  -v biliproxy-data:/data \
  --name biliproxy ghcr.io/nomdn/podenco-music-proxy:latest
```

镜像是多架构清单（`linux/amd64` + `linux/arm64`），`docker pull` 会按机器架构自动挑，
ARM 服务器上不用加 `--platform`。

也可本地构建：

```bash
docker build -t biliproxy .
docker run -d -p 8787:8787 \
  -e BILI_TOKEN=你的长随机串 \
  -v biliproxy-data:/data \
  --name biliproxy biliproxy
```

## 安全提醒

这是**你自己的**出口 IP 在替所有人访问 B站。一旦被判定为滥用，你的 IP 会被风控，
正常使用也会受影响。所以：

- 公网部署一定加 `-token`，别让人随手扫到就能白用；
- 限流参数按实际用户数调，不要图省事关掉；
- `state.json` 里存着明文的 `SESSDATA`，权限设成 `600`（程序自己会这么创建）；
- 只反代 B站，`u` 参数的白名单不要为了「兼容某个新 CDN」就放宽成任意域名。

## 已知边界

- **不做字节缓存**。每次 seek 都回源，靠 B站 CDN 自己的缓存扛。
  做本地缓存要处理分片、淘汰和签名过期三者的关系，收益不匹配复杂度。
- **签名地址约 2 小时过期**。播放器长时间挂着后重新播放，会重新取一次地址。
- **登录态存在内存 + 落盘**。多副本部署需要共享存储，否则每个实例各存各的。
  客户端会收到 `X-Session-Known: 0` 并自动重建会话、把本地凭证补回来，
  所以不会掉登录，但服务端那份要等下一次请求才回到手边。
- **只支持单段 Range**。播放器实际只发单段请求，多段（`bytes=0-100,200-300`）没做解析。
