package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"

	"github.com/gin-gonic/gin"
)

// 桌面 Chrome 的 UA。B站按 UA 决定返回什么形态的内容，
// 用 Dart 默认的 UA 会被当成爬虫。
const browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
	"(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

// B站会检查这几个头，缺了 view 接口就回 HTML 而不是 JSON。
// Origin 必须是 www.bilibili.com，否则风控直接 403。
const (
	originHome     = "https://www.bilibili.com"
	refererHome    = "https://www.bilibili.com/"
	refererSearch  = "https://search.bilibili.com/"
	passportHost   = "https://passport.bilibili.com"
	passportPollRe = "/x/passport-login/web/qrcode/poll"
)

// upstreamRoute 是一条透明的路径映射。
//
// 之所以用「路径前缀 → 上游域名」的裸映射而不是一条条手写接口，
// 是因为前端已经有一整套 Dart 接口层，重写一遍既容易漏又容易和桌面版行为分叉。
// 映射之后前端的请求路径一个字都不用改，只是把域名换掉。
type upstreamRoute struct {
	prefix string // 本地前缀，例如 /bili/api
	host   string // 上游根地址，例如 https://api.bilibili.com
}

var upstreamRoutes = []upstreamRoute{
	{prefix: "/bili/api", host: "https://api.bilibili.com"},
	{prefix: "/bili/passport", host: passportHost},
	{prefix: "/bili/app", host: "https://app.bilibili.com"},
	{prefix: "/bili/www", host: "https://www.bilibili.com"},
	{prefix: "/bili/search", host: "https://search.bilibili.com"},
}

// relay 把请求原样转发给上游，再把响应流式送回去。
//
// 唯一有「智能」的地方是认证：客户端不发 Cookie，我们按会话补上。
// 这正是浏览器做不到、而服务端可以做到的事。
func (p *Proxy) relay(c *gin.Context, route upstreamRoute, rest string) {
	// 路径原样保留。不能用 c.Param("path")，那是解码后的值，
	// 遇到 %2F 之类会变味；EscapedPath 拿到的才是原始编码。
	target := route.host + rest
	rawQuery := c.Request.URL.RawQuery
	if rawQuery != "" {
		target += "?" + rawQuery
	}

	ctx, cancel := context.WithTimeout(c.Request.Context(), apiTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, c.Request.Method, target, nil)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "上游地址不合法"})
		return
	}

	sess := p.store.fromRequest(c.Request)

	// 告诉客户端这张票服务端还认不认得。
	//
	// 客户端会把 sid 存在本地，服务端重启且状态没落盘时那张票就成了孤儿：
	// 请求照常成功（降级成匿名），但用户会看到「明明登录着，收藏却空了」。
	// 有了这个头，前端能立刻发现并重建会话，再把本地凭证补回来。
	if requestSessionID(c.Request) != "" {
		known := "0"
		if sess != nil {
			known = "1"
		}
		c.Writer.Header().Set("X-Session-Known", known)
	}

	req.Header.Set("User-Agent", browserUA)
	req.Header.Set("Referer", refererFor(route.host, rest, c.Request.URL.Query()))
	req.Header.Set("Origin", originHome)
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	req.Header.Set("sec-ch-ua", `"Chromium";v="126", "Not:A-Brand";v="24"`)
	req.Header.Set("sec-ch-ua-platform", `"Windows"`)

	// 登录态优先，没有就用服务端共享的访客身份
	cookie := sess.cookieHeader()
	if cookie == "" {
		cookie = p.store.GuestCookie(ctx)
	}
	if cookie != "" {
		req.Header.Set("Cookie", cookie)
	}

	resp, err := p.apiClient.Do(req)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "连不上B站：" + err.Error()})
		return
	}
	defer resp.Body.Close()

	// 扫码登录的响应要留一份：cookie 藏在 body 的跳转地址里，
	// 不读 body 就永远拿不到登录态。这类响应只有几百字节，缓冲无压力。
	if route.host == passportHost && strings.HasSuffix(rest, passportPollRe) {
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		if readErr != nil {
			c.JSON(http.StatusBadGateway, gin.H{"error": "读取登录响应失败"})
			return
		}
		p.store.captureLogin(sess, body, resp.Header)
		copyResponseHeaders(c, resp)
		if ct := resp.Header.Get("Content-Type"); ct != "" {
			c.Writer.Header().Set("Content-Type", ct)
		}
		c.Status(resp.StatusCode)
		c.Writer.WriteHeaderNow()
		if c.Request.Method != http.MethodHead {
			_, _ = c.Writer.Write(body)
		}
		return
	}

	copyResponseHeaders(c, resp)
	if ct := resp.Header.Get("Content-Type"); ct != "" {
		c.Writer.Header().Set("Content-Type", ct)
	} else {
		c.Writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	}
	c.Status(resp.StatusCode)
	c.Writer.WriteHeaderNow()

	if c.Request.Method == http.MethodHead {
		return
	}
	if _, err := io.Copy(c.Writer, resp.Body); err != nil {
		// 客户端提前断开（切歌、关页面）是正常的，不当错误处理
		slog.Debug("转发中断", "path", rest, "err", err)
	}
}

// refererFor 决定该带哪个 Referer。
//
// 这不是可选项：搜索接口要求 search.bilibili.com，播放地址要求具体视频页，
// 给错了一律 403 或者返回风控页。bvid 能从 query 里读出来，
// 所以不用前端额外传。
func refererFor(host, path string, q url.Values) string {
	if bv := q.Get("bvid"); bv != "" && isBvid(bv) {
		return originHome + "/video/" + bv + "/"
	}
	if host == "https://search.bilibili.com" || strings.Contains(path, "search/type") {
		return refererSearch
	}
	return refererHome
}

// copyResponseHeaders 只抄我们需要的头。
//
// 不做全量透传是刻意的：上游会带 Set-Cookie、Content-Security-Policy、
// Access-Control-Allow-Origin 这些东西，把上游的 CORS 头原样透出去
// 反而会和我们自己的冲突，导致浏览器把响应丢掉。
func copyResponseHeaders(c *gin.Context, resp *http.Response) {
	for _, name := range []string{
		http.CanonicalHeaderKey("Content-Type"),
		http.CanonicalHeaderKey("Content-Length"),
		http.CanonicalHeaderKey("Cache-Control"),
		http.CanonicalHeaderKey("ETag"),
		http.CanonicalHeaderKey("Last-Modified"),
	} {
		if v := resp.Header.Get(name); v != "" {
			c.Writer.Header().Set(name, v)
		}
	}
}

// health 给部署方一个探活口，顺便暴露版本和会话数，方便确认服务还活着。
func (p *Proxy) health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"ok":       true,
		"service":  "podenco-bili-proxy",
		"version":  version,
		"uptime_s": int(uptime().Seconds()),
	})
}
