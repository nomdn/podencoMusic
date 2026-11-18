package main

import (
	"context"
	"flag"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
)

const version = "1.0.0"

const (
	// API 请求的总超时。B站偶尔会卡十几秒，超过这个时间就算失败，
	// 让前端拿到明确的错误而不是一直转圈。
	apiTimeout = 20 * time.Second
)

// 进程启动时间，/healthz 用得上
var startedAt = time.Now()

func uptime() time.Duration { return time.Since(startedAt) }

// Proxy 把共享的 HTTP 客户端和会话表收在一起。
//
// 两个客户端是有意分开的：API 请求要短超时、能复用连接即可；
// 媒体流可能连续传几十秒，不能套总超时，但必须限制「等响应头」的时间，
// 否则 CDN 卡住会一直占着 goroutine。
type Proxy struct {
	store       *SessionStore
	apiClient   *http.Client
	mediaClient *http.Client
}

func newProxy(statePath string) *Proxy {
	transport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 20 * time.Second,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   16,
		IdleConnTimeout:       90 * time.Second,
		ForceAttemptHTTP2:     true,
	}

	apiClient := &http.Client{
		Transport: transport,
		Timeout:   apiTimeout,
	}
	mediaClient := &http.Client{
		// 不设 Timeout：媒体要在读到响应头之后持续传下去，
		// 设了会把长音频掐断。卡住的风险由 ResponseHeaderTimeout 兜住。
		Transport: transport,
	}

	return &Proxy{
		store:       NewSessionStore(statePath, apiClient),
		apiClient:   apiClient,
		mediaClient: mediaClient,
	}
}

func main() {
	addr := flag.String("addr", ":8787", "监听地址，例如 :8787 或 127.0.0.1:8787")
	statePath := flag.String("state", "state.json", "会话状态文件，留空则不落盘")
	token := flag.String("token", "", "可选共享密钥；设置后客户端需带 X-Token 头")
	apiRate := flag.Int("rate", 240, "每 IP 每分钟 API 请求上限，0 表示不限")
	mediaRate := flag.Int("media-rate", 900, "每 IP 每分钟媒体请求上限，0 表示不限")
	flag.Parse()

	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	gin.SetMode(gin.ReleaseMode)
	p := newProxy(strings.TrimSpace(*statePath))

	r := gin.New()
	r.Use(gin.Recovery(), cors(), accessLog(), requireToken(*token))

	r.GET("/healthz", p.health)

	// 会话：创建、登出。前端启动时取一个，之后放在 X-Session 头里。
	r.POST("/bili/session", p.newSession)
	r.GET("/bili/session", p.sessionInfo)
	r.DELETE("/bili/session", p.dropSession)

	// 客户端把自己保存的 Cookie 补回会话：服务端丢状态时不至于掉登录。
	// 只写不读，见 ImportCookies 的说明。
	r.POST("/bili/session/import", p.importSession)

	// 媒体流单独一个限流额度，避免和 API 互相挤占
	mediaLimiter := newRateLimiter(*mediaRate, time.Minute)
	r.Any("/bili/media/:bvid", mediaLimiter.middleware(), p.media)

	// 透明反代。前端只要把 host 换成这些前缀，其余代码一行不用改。
	apiLimiter := newRateLimiter(*apiRate, time.Minute)
	for _, route := range upstreamRoutes {
		route := route
		r.Any(route.prefix+"/*path", apiLimiter.middleware(), func(c *gin.Context) {
			rest := strings.TrimPrefix(c.Request.URL.EscapedPath(), route.prefix)
			if rest == "" {
				rest = "/"
			}
			p.relay(c, route, rest)
		})
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		// 不设 WriteTimeout：媒体流是长连接，设了会把正在播的音频切断
	}

	// 每小时扫一次过期会话
	go func() {
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for range ticker.C {
			p.store.sweep()
		}
	}()

	go func() {
		slog.Info("B站反代已启动",
			"addr", *addr,
			"version", version,
			"auth", *token != "",
			"state", *statePath,
		)
		slog.Info("前端接入示例",
			"api", "http://<host>:8787/bili/api",
			"passport", "http://<host>:8787/bili/passport",
			"media", "http://<host>:8787/bili/media/<bvid>?u=<url>&kind=audio",
		)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("监听失败", "err", err)
			os.Exit(1)
		}
	}()

	// 优雅退出：给正在传输的媒体流 10 秒收尾时间
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	slog.Info("收到退出信号，正在关闭…")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		slog.Warn("关闭超时", "err", err)
	}
	p.store.persist()
	slog.Info("已退出")
}

// ── 会话接口 ─────────────────────────────────────────────

// newSession 下发一个新的会话 id。
//
// 前端启动时调一次，把 id 存在本地，之后所有请求通过 X-Session 带回来。
// 不用 Cookie 传是因为跨域下第三方 Cookie 基本被浏览器禁掉了。
func (p *Proxy) newSession(c *gin.Context) {
	sess := p.store.Create()
	c.JSON(http.StatusOK, gin.H{
		"sid":     sess.ID,
		"expires": sessionTTL.Seconds(),
	})
}

// sessionInfo 让前端确认当前会话是否已经登录。
func (p *Proxy) sessionInfo(c *gin.Context) {
	sess := p.store.fromRequest(c.Request)
	if sess == nil {
		c.JSON(http.StatusOK, gin.H{"known": false, "logged_in": false})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"known":     true,
		"logged_in": sess.LoggedIn(),
		"uid":       sess.UID,
		"csrf":      sess.CSRF(),
	})
}

// dropSession 清掉登录凭证。会话本身保留，
// 这样前端不用重新拿 sid，扫码时可以覆盖。
func (p *Proxy) dropSession(c *gin.Context) {
	sess := p.store.fromRequest(c.Request)
	if sess == nil {
		c.JSON(http.StatusOK, gin.H{"ok": true})
		return
	}
	p.store.clearLogin(sess)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// importSession 让客户端把手上的 Cookie 推回来。
//
// 修的是「服务端状态丢了但客户端还有凭证」这一类场景：反代重启且没落盘、
// 换机器、从旧反代切到新反代。这些情况下让用户重新扫码是没有必要的。
//
// 必须带一个服务端认识的 X-Session —— 这里不会自动建会话，
// 否则任何人都能靠刷这个接口把内存刷爆。
func (p *Proxy) importSession(c *gin.Context) {
	sess := p.store.fromRequest(c.Request)
	if sess == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少或未知的 X-Session"})
		return
	}

	var body struct {
		Cookie string `json:"cookie"`
		Mid    string `json:"mid"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体不是合法 JSON"})
		return
	}

	changed := p.store.ImportCookies(sess, body.Cookie, body.Mid)
	c.JSON(http.StatusOK, gin.H{
		"imported":  changed,
		"logged_in": sess.LoggedIn(),
	})
}
