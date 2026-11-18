package main

import (
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/gin-gonic/gin"
)

// bvid 的固定形态：BV + 10 位 base58。只做格式校验，
// 不校验是否存在 —— 它会直接拼进 Referer，不能放任任意字符串进来。
var bvidRe = regexp.MustCompile(`^BV[0-9A-Za-z]{10}$`)

func isBvid(s string) bool { return bvidRe.MatchString(s) }

// 允许反代的媒体域名后缀。
//
// 这是一道 SSRF 闸门：/bili/media 的 u 参数是完整 URL，
// 如果不校验，任何人都能把它当成「以你的服务器身份访问任意内网地址」的跳板。
// 宁可列白名单偶尔漏一个 CDN，也不能开成任意转发。
var mediaHostSuffixes = []string{
	".bilivideo.com",
	".bilivideo.cn",
	".bilivideo.net",
	".hdslb.com",
	".mountaintoys.cn",
	".bilibili.com",
	".akamaized.net",
	".biliapi.net",
}

// allowedMediaHost 判断主机名是否在 CDN 白名单内。
//
// 端口要单独剥掉：PCDN 节点常带 :8082 / :4483 这类端口，
// 直接比 host 会全部拒掉。
func allowedMediaHost(hostport string) bool {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "" {
		return false
	}
	for _, suffix := range mediaHostSuffixes {
		if strings.HasSuffix(host, suffix) {
			return true
		}
		// 裸域名本身（例如 hdslb.com）也算
		if strings.TrimPrefix(suffix, ".") == host {
			return true
		}
	}
	return false
}

// media 是音视频流的专用通道。
//
// 为什么不复用透明反代：媒体地址是带签名的完整 URL（不是固定域名+路径），
// 而且它必须带「该视频页」的 Referer。把 bvid 放在路径里，
// Referer 就能自动推出来，前端不用关心这些细节。
//
//	GET /bili/media/BV1xx411c7mD?u=<encoded>&u=<encoded>&kind=audio
//
// u 可以重复：playurl 会给主站 CDN 加若干 PCDN 备用地址，
// 它们都是同一份资源的镜像。按顺序试，谁通用谁，
// 这样"某个节点抽风"就不会变成"这首歌放不了"。
func (p *Proxy) media(c *gin.Context) {
	bvid := strings.TrimSpace(c.Param("bvid"))
	if !isBvid(bvid) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "bvid 格式不对"})
		return
	}

	raws := c.QueryArray("u")
	if len(raws) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少 u 参数"})
		return
	}

	// 先把所有候选校验一遍再发请求：避免"试到第三个才发现地址非法"
	// 这种半成功状态，也让配置错误立刻暴露。
	targets := make([]string, 0, len(raws))
	for _, raw := range raws {
		target, code, err := checkMediaURL(raw)
		if err != nil {
			c.JSON(code, gin.H{"error": err.Error()})
			return
		}
		targets = append(targets, target)
	}

	// 音频和视频都是 fragmented mp4，区别只在给播放器的 Content-Type。
	// 上游给的是 application/octet-stream，直接透传的话
	// Media Foundation / ExoPlayer 会靠嗅探去猜，猜错就静默失败。
	//
	// json 是给B站字幕用的：字幕文件也在 CDN 上，Web 端同样取不到
	// （没有 CORS 头），只能借这条通道。
	kind := c.DefaultQuery("kind", "audio")
	contentType := contentTypeFor(kind)

	lastStatus := 0
	for idx, target := range targets {
		resp, err := p.openMedia(c, target, bvid, kind)
		if err != nil {
			slog.Debug("候选地址连接失败", "bvid", bvid, "idx", idx, "err", err)
			continue
		}

		if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusPartialContent {
			p.writeMedia(c, resp, contentType)
			resp.Body.Close()
			return
		}

		// 这个节点不通（403 / 404 / 5xx），读掉一小段 body 再换下一个。
		// 不读完会让连接无法复用，反而拖慢后续请求。
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		resp.Body.Close()
		lastStatus = resp.StatusCode
		slog.Warn("候选地址不可用，换下一个",
			"bvid", bvid, "idx", idx, "status", resp.StatusCode, "host", hostOf(target))
	}

	if lastStatus == 0 {
		lastStatus = http.StatusBadGateway
	}
	c.JSON(lastStatus, gin.H{"error": "所有候选地址都取不到流"})
}

// checkMediaURL 校验并归一化一个上游媒体地址。
func checkMediaURL(raw string) (target string, code int, err error) {
	u, parseErr := url.Parse(raw)
	if parseErr != nil || u.Host == "" {
		return "", http.StatusBadRequest, errors.New("u 不是合法地址")
	}
	// 只允许 https：http 会被运营商劫持，而且B站早已全站 https
	if u.Scheme != "https" {
		return "", http.StatusBadRequest, errors.New("只支持 https 上游")
	}
	if !allowedMediaHost(u.Host) {
		return "", http.StatusForbidden, errors.New("不在允许的 CDN 白名单内：" + u.Host)
	}
	return u.String(), 0, nil
}

// contentTypeFor 决定回给客户端的 Content-Type。
//
// 上游一律是 application/octet-stream，直接透传等于让播放器自己嗅探，
// 猜错就静默失败（Media Foundation 尤其如此）。
func contentTypeFor(kind string) string {
	switch kind {
	case "video":
		return "video/mp4"
	case "json", "text":
		return "application/json; charset=utf-8"
	default:
		return "audio/mp4"
	}
}

// isTextKind 判断是不是文本资源（字幕 JSON）。
// 文本不能转发 Range：CDN 会老实返回 206 + 半个 JSON，前端解析必然失败。
func isTextKind(kind string) bool {
	return kind == "json" || kind == "text"
}

// openMedia 构造并发出取流请求。
func (p *Proxy) openMedia(c *gin.Context, target, bvid, kind string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(c.Request.Context(), c.Request.Method, target, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("User-Agent", browserUA)
	req.Header.Set("Referer", originHome+"/video/"+bvid+"/")
	req.Header.Set("Origin", originHome)
	req.Header.Set("Accept", "*/*")
	// 不让 Transport 自作主张加 gzip：媒体流压缩没有意义，
	// 而且会让 Content-Length 和 Range 语义对不上。
	req.Header.Set("Accept-Encoding", "identity")
	if !isTextKind(kind) {
		if rg := c.Request.Header.Get("Range"); rg != "" {
			req.Header.Set("Range", rg)
		}
		// 条件请求也透传，播放器重连时能省掉整段传输
		for _, h := range []string{"If-Range", "If-None-Match", "If-Modified-Since"} {
			if v := c.Request.Header.Get(h); v != "" {
				req.Header.Set(h, v)
			}
		}
	}

	return p.mediaClient.Do(req)
}

// writeMedia 把上游响应写回客户端，同时补齐 seek 需要的头。
func (p *Proxy) writeMedia(c *gin.Context, resp *http.Response, contentType string) {
	// 这几个头是 seek 的全部依据，少一个就只能从头播
	for _, name := range []string{"Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if v := resp.Header.Get(name); v != "" {
			c.Writer.Header().Set(name, v)
		}
	}
	// 有的 CDN 节点不给 Accept-Ranges，但后面确实能接 Range 请求。
	// 补一个，否则播放器会以为不可跳转，把进度条锁死。
	if c.Writer.Header().Get("Accept-Ranges") == "" &&
		(resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusPartialContent) {
		c.Writer.Header().Set("Accept-Ranges", "bytes")
	}
	c.Writer.Header().Set("Content-Type", contentType)
	// 签名地址会过期，缓存下来只会拿到 403，所以明确告诉中间层别缓存
	c.Writer.Header().Set("Cache-Control", "no-store")

	c.Status(resp.StatusCode)
	c.Writer.WriteHeaderNow()

	if c.Request.Method == http.MethodHead {
		return
	}
	if _, err := io.Copy(c.Writer, resp.Body); err != nil {
		// 拖动进度条时播放器会主动断开旧连接，属于正常现象
		slog.Debug("媒体流中断", "err", err)
	}
}

func hostOf(raw string) string {
	if u, err := url.Parse(raw); err == nil {
		return u.Host
	}
	return ""
}
