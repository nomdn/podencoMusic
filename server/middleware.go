package main

import (
	"log/slog"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

// cors 允许任意来源访问。
//
// 为什么敢用 *：这个服务的定位是「给任何前端（含 Web 版）用的网关」，
// 而它的鉴权不依赖 Cookie —— 会话走 X-Session 头。
// 不开 Allow-Credentials，就没有「任意站点借用户 Cookie 发请求」的风险，
// 这也是浏览器 SSRF 与 CSRF 的分界线。
//
// Expose-Headers 必须显式列出：浏览器的 fetch 默认读不到
// Content-Range 这类头，而播放器和断点续传要靠它。
func cors() gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.Writer.Header()
		h.Set("Access-Control-Allow-Origin", "*")
		// DELETE 用于退出登录（DELETE /bili/session）。漏掉它会让浏览器
		// 预检直接失败，表现为「退出登录转圈但凭证没清」。
		h.Set("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS")
		h.Set("Access-Control-Allow-Headers", "Range, Content-Type, Accept, X-Session, X-Token, X-Requested-With")
		h.Set("Access-Control-Expose-Headers",
			"Content-Length, Content-Range, Accept-Ranges, ETag, X-Session, X-Session-Known")
		h.Set("Access-Control-Max-Age", "86400")

		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

// accessLog 记一行一条的访问日志。
//
// 不用 gin.Logger 是因为它对流式响应拿不到真实字节数（Writer 的 Size()
// 在 io.Copy 之后才准，而 gin 的日志在 handler 返回后才读，其实也能读到），
// 更重要的是这里想统一成 slog 并带上 status 与耗时两个关键字段。
func accessLog() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		cost := time.Since(start)
		slog.Info("req",
			"method", c.Request.Method,
			"path", c.Request.URL.Path,
			"status", c.Writer.Status(),
			"cost_ms", cost.Milliseconds(),
			"ip", c.ClientIP(),
		)
	}
}

// rateLimiter 是每 IP 的滑动窗口计数器。
//
// 目的不是防攻击（那该交给前面的 Nginx / Cloudflare），
// 而是防止这个服务被人当成免费代理刷流量 —— 一旦形成规模，
// 出口 IP 会被B站封掉，正常用户也跟着挂。
type rateLimiter struct {
	mu      sync.Mutex
	limit   int
	window  time.Duration
	buckets map[string]*bucket
}

type bucket struct {
	count int
	reset time.Time
}

func newRateLimiter(limit int, window time.Duration) *rateLimiter {
	rl := &rateLimiter{
		limit:   limit,
		window:  window,
		buckets: make(map[string]*bucket),
	}
	go rl.gc()
	return rl
}

func (rl *rateLimiter) allow(key string) bool {
	if rl.limit <= 0 {
		return true
	}
	now := time.Now()

	rl.mu.Lock()
	defer rl.mu.Unlock()

	b, ok := rl.buckets[key]
	if !ok || now.After(b.reset) {
		rl.buckets[key] = &bucket{count: 1, reset: now.Add(rl.window)}
		return true
	}
	if b.count >= rl.limit {
		return false
	}
	b.count++
	return true
}

// gc 清掉过期的桶，否则 map 会随 IP 数量无限增长。
func (rl *rateLimiter) gc() {
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		rl.mu.Lock()
		for k, b := range rl.buckets {
			if now.After(b.reset) {
				delete(rl.buckets, k)
			}
		}
		rl.mu.Unlock()
	}
}

// limit 套在路由上。媒体流单独给更大的额度：
// 一首歌要发好几次 Range 请求，用 API 的额度会误伤。
func (rl *rateLimiter) middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if !rl.allow(c.ClientIP()) {
			c.Header("Retry-After", strconv.Itoa(int(rl.window.Seconds())))
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{
				"error": "请求太频繁，稍后再试",
			})
			return
		}
		c.Next()
	}
}

// requireToken 是可选的共享密钥。
//
// 部署到公网时强烈建议打开：没有它，任何人扫到这个端口都能用你的
// 出口 IP 去刷B站，风控的锅是你的。
func requireToken(token string) gin.HandlerFunc {
	return func(c *gin.Context) {
		if token == "" || c.Request.URL.Path == "/healthz" {
			c.Next()
			return
		}
		supplied := c.Request.Header.Get("X-Token")
		if supplied == "" {
			supplied = c.Query("token")
		}
		if supplied != token {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
				"error": "缺少或错误的 X-Token",
			})
			return
		}
		c.Next()
	}
}
