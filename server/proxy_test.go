package main

import (
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
	"time"
)

func TestAllowedMediaHost(t *testing.T) {
	cases := []struct {
		host string
		want bool
	}{
		{"upos-sz-mirrorali.bilivideo.com", true},
		{"cn-gddg-cm-01-04.bilivideo.com", true},
		{"xy112x123.mcdn.bilivideo.cn:8082", true},
		{"t6ur09t.edge.mountaintoys.cn:4483", true},
		{"i0.hdslb.com", true},
		{"hdslb.com", true},
		{"api.bilibili.com", true},
		// 以下是必须拒掉的：内网、任意站点、以及"看起来像"的钓鱼域名
		{"127.0.0.1:8787", false},
		{"localhost", false},
		{"example.com", false},
		{"bilivideo.com.evil.com", false},
		{"evilibivideo.com", false},
		{"", false},
	}
	for _, c := range cases {
		if got := allowedMediaHost(c.host); got != c.want {
			t.Errorf("allowedMediaHost(%q) = %v, want %v", c.host, got, c.want)
		}
	}
}

func TestCheckMediaURL(t *testing.T) {
	tests := []struct {
		name     string
		raw      string
		wantCode int
		wantErr  bool
	}{
		{"正常 https", "https://upos-sz-mirrorali.bilivideo.com/a.m4s?sig=1", 0, false},
		{"明文 http", "http://upos-sz-mirrorali.bilivideo.com/a.m4s", 400, true},
		{"非白名单", "https://example.com/a.m4s", 403, true},
		{"内网", "https://192.168.1.1/a.m4s", 403, true},
		{"不是地址", "::not a url::", 400, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, code, err := checkMediaURL(tt.raw)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr && code != tt.wantCode {
				t.Errorf("code = %d, want %d", code, tt.wantCode)
			}
		})
	}
}

func TestRefererFor(t *testing.T) {
	// 播放地址必须带具体视频页，否则 CDN 403
	if got := refererFor("https://api.bilibili.com", "/x/player/playurl",
		url.Values{"bvid": {"BV1xx411c7mD"}}); got != "https://www.bilibili.com/video/BV1xx411c7mD/" {
		t.Errorf("播放地址 referer 不对：%s", got)
	}
	// 搜索接口要 search 子域
	if got := refererFor("https://search.bilibili.com", "/x/web-interface/search/type", nil); got != refererSearch {
		t.Errorf("搜索 referer 不对：%s", got)
	}
	// bvid 不合法时不能直接拼进去
	if got := refererFor("https://api.bilibili.com", "/x/player/playurl",
		url.Values{"bvid": {"../../etc"}}); got != refererHome {
		t.Errorf("非法 bvid 应退回根域，实际：%s", got)
	}
}

func TestIsBvid(t *testing.T) {
	if !isBvid("BV1ZVsn6nEMn") {
		t.Error("合法 bvid 被判成非法")
	}
	for _, bad := range []string{"", "BV", "av123", "BV1ZVsn6nEM", "BV1ZVsn6nEMnn"} {
		if isBvid(bad) {
			t.Errorf("%q 应判为非法", bad)
		}
	}
}

func TestCaptureLogin(t *testing.T) {
	store := NewSessionStore("", &http.Client{})
	sess := store.Create()

	// B站扫码成功时的真实响应形态：cookie 在 data.url 的查询串里
	payload := map[string]any{
		"code": 0,
		"data": map[string]any{
			"code": 0,
			"url": "https://passport.biligame.com/crossDomain?DedeUserID=12345" +
				"&DedeUserID__ckMd5=abc&SESSDATA=secret%2C123&bili_jct=csrf&gourl=x",
		},
	}
	body, _ := json.Marshal(payload)
	store.captureLogin(sess, body, nil)

	if !sess.LoggedIn() {
		t.Fatal("登录后 LoggedIn 应为 true")
	}
	if sess.UID != "12345" {
		t.Errorf("UID = %q, want 12345", sess.UID)
	}
	// SESSDATA 是 URL 编码的，解码后应还原成逗号
	if sess.Cookies["SESSDATA"] != "secret,123" {
		t.Errorf("SESSDATA = %q", sess.Cookies["SESSDATA"])
	}
	header := sess.cookieHeader()
	for _, want := range []string{"SESSDATA=secret,123", "bili_jct=csrf", "DedeUserID=12345"} {
		if !contains(header, want) {
			t.Errorf("Cookie 头里缺少 %s：%s", want, header)
		}
	}
}

// 有些账号扫码成功后 data.url 是空的，凭证只在 Set-Cookie 里。
// 只认 url 的实现会让这些账号永远登不上（界面提示「没拿到凭证」，
// 重试多少次都一样）。
func TestCaptureLoginFromSetCookie(t *testing.T) {
	store := NewSessionStore("", &http.Client{})
	sess := store.Create()

	body := []byte(`{"code":0,"data":{"code":0,"url":""}}`)
	header := http.Header{}
	header.Add("Set-Cookie", "SESSDATA=abc%2C1794801182%2Cdef; Path=/; Domain=.bilibili.com; HttpOnly")
	header.Add("Set-Cookie", "bili_jct=jct123; Path=/")
	header.Add("Set-Cookie", "DedeUserID=1643709100; Path=/")
	header.Add("Set-Cookie", "Path=/; Domain=.bilibili.com")

	store.captureLogin(sess, body, header)

	if !sess.LoggedIn() {
		t.Fatal("Set-Cookie 里有 SESSDATA 就该算登录成功")
	}
	if sess.UID != "1643709100" {
		t.Errorf("UID = %q, want 1643709100", sess.UID)
	}
	if sess.Cookies["SESSDATA"] != "abc%2C1794801182%2Cdef" {
		t.Errorf("SESSDATA = %q", sess.Cookies["SESSDATA"])
	}
	// Path / Domain 这类属性不能混进 Cookie 头
	if c := sess.cookieHeader(); contains(c, "Path=") || contains(c, "Domain=") {
		t.Errorf("Cookie 头里混进了属性：%s", c)
	}
}

// url 里有值的时候优先用 url（那是B站确认过完整的一套），
// Set-Cookie 只是兜底。
func TestCaptureLoginPrefersURL(t *testing.T) {
	store := NewSessionStore("", &http.Client{})
	sess := store.Create()

	body := []byte(`{"code":0,"data":{"code":0,"url":"https://passport.biligame.com/crossDomain?DedeUserID=999&SESSDATA=fromurl"}}`)
	header := http.Header{}
	header.Add("Set-Cookie", "SESSDATA=fromheader; Path=/")

	store.captureLogin(sess, body, header)

	if sess.Cookies["SESSDATA"] != "fromurl" {
		t.Errorf("应以 url 为准，实际 %q", sess.Cookies["SESSDATA"])
	}
}

func TestCaptureLoginIgnoresPending(t *testing.T) {	store := NewSessionStore("", &http.Client{})
	sess := store.Create()

	// 未扫码（86101）：不应写入任何东西
	body := []byte(`{"code":0,"data":{"code":86101,"url":""}}`)
	store.captureLogin(sess, body, nil)

	if sess.LoggedIn() {
		t.Error("未扫码时不该变成已登录")
	}
}

func TestCaptureLoginIgnoresGarbage(t *testing.T) {
	store := NewSessionStore("", &http.Client{})
	sess := store.Create()

	store.captureLogin(sess, []byte("<html>风控页</html>"), nil)
	// 成功码但没有 SESSDATA：不能当成登录成功
	store.captureLogin(sess, []byte(`{"code":0,"data":{"code":0,"url":"https://x/?a=b"}}`), nil)

	if sess.LoggedIn() {
		t.Error("垃圾响应不该产生登录态")
	}
}

func TestClearLoginKeepsSession(t *testing.T) {
	store := NewSessionStore("", &http.Client{})
	sess := store.Create()
	sess.Cookies = map[string]string{"SESSDATA": "x", "DedeUserID": "1"}
	sess.UID = "1"

	store.clearLogin(sess)

	if sess.LoggedIn() {
		t.Error("clearLogin 之后不该还是登录态")
	}
	if sess.ID == "" {
		t.Error("会话本身应该保留，前端不用重新拿 sid")
	}
	if store.Get(sess.ID) == nil {
		t.Error("会话不该被从表里删掉")
	}
}

func TestSessionPersistRoundTrip(t *testing.T) {
	path := t.TempDir() + "/state.json"
	store := NewSessionStore(path, &http.Client{})
	sess := store.Create()
	sess.Cookies = map[string]string{"SESSDATA": "keep-me", "DedeUserID": "42"}
	store.persist()

	// 模拟重启：新建一个 store 读同一个文件
	again := NewSessionStore(path, &http.Client{})
	loaded := again.Get(sess.ID)
	if loaded == nil {
		t.Fatal("重启后会话应该还在")
	}
	if loaded.Cookies["SESSDATA"] != "keep-me" {
		t.Errorf("SESSDATA 丢了：%v", loaded.Cookies)
	}
}

func TestRateLimiter(t *testing.T) {
	rl := newRateLimiter(3, time.Minute)
	for i := 0; i < 3; i++ {
		if !rl.allow("1.2.3.4") {
			t.Fatalf("第 %d 次应该放行", i+1)
		}
	}
	if rl.allow("1.2.3.4") {
		t.Error("第 4 次应该被限流")
	}
	// 不同 IP 互不影响
	if !rl.allow("5.6.7.8") {
		t.Error("另一个 IP 不该被牵连")
	}

	// limit=0 表示不限
	off := newRateLimiter(0, time.Minute)
	for i := 0; i < 100; i++ {
		if !off.allow("1.2.3.4") {
			t.Fatal("限额为 0 时应完全不限")
		}
	}
}

func TestRateLimiterWindowReset(t *testing.T) {
	rl := newRateLimiter(1, 50*time.Millisecond)
	if !rl.allow("ip") {
		t.Fatal("第一次应放行")
	}
	if rl.allow("ip") {
		t.Fatal("窗口内第二次应被拒")
	}
	time.Sleep(80 * time.Millisecond)
	if !rl.allow("ip") {
		t.Error("窗口过后应重新放行")
	}
}

func TestParseSetCookies(t *testing.T) {
	store := NewSessionStore("", &http.Client{})
	jar := store.parseSetCookies([]string{
		"buvid3=ABC%2F123; Path=/; Domain=.bilibili.com; Expires=Wed, 21 Oct 2026 07:28:00 GMT",
		"b_nut=1700000000; Path=/",
		"garbage-without-eq",
		"=empty-name",
	})
	if jar["buvid3"] != "ABC%2F123" {
		t.Errorf("buvid3 = %q", jar["buvid3"])
	}
	if jar["b_nut"] != "1700000000" {
		t.Errorf("b_nut = %q", jar["b_nut"])
	}
	if len(jar) != 2 {
		t.Errorf("应只保留两条，实际 %v", jar)
	}
}

func contains(haystack, needle string) bool {
	return len(needle) == 0 || (len(haystack) >= len(needle) && indexOf(haystack, needle) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func TestParseCookieHeader(t *testing.T) {
	jar := parseCookieHeader("SESSDATA=abc%2C1; bili_jct=csrf; DedeUserID=42; evil=drop; =noname; malformed")

	if jar["SESSDATA"] != "abc%2C1" {
		t.Errorf("SESSDATA = %q", jar["SESSDATA"])
	}
	if jar["bili_jct"] != "csrf" || jar["DedeUserID"] != "42" {
		t.Errorf("登录项解析不全：%v", jar)
	}
	// 白名单之外的键必须被丢掉
	if _, ok := jar["evil"]; ok {
		t.Error("白名单外的键不该被接受")
	}
	if len(jar) != 3 {
		t.Errorf("应只留下 3 条，实际 %d：%v", len(jar), jar)
	}
}

func TestImportCookiesRestoresLogin(t *testing.T) {
	store := NewSessionStore("", &http.Client{})
	sess := store.Create()

	if sess.LoggedIn() {
		t.Fatal("新会话不该是登录态")
	}

	changed := store.ImportCookies(sess,
		"SESSDATA=fresh; bili_jct=csrf; DedeUserID=99; DedeUserID__ckMd5=m", "99")

	if !sess.LoggedIn() {
		t.Fatal("导入后应为登录态")
	}
	if changed != 4 {
		t.Errorf("changed = %d, want 4", changed)
	}
	if sess.UID != "99" {
		t.Errorf("UID = %q, want 99", sess.UID)
	}

	// 再导一次同样的内容：不该算作变更
	if again := store.ImportCookies(sess,
		"SESSDATA=fresh; bili_jct=csrf; DedeUserID=99; DedeUserID__ckMd5=m", "99"); again != 0 {
		t.Errorf("重复导入 changed = %d, want 0", again)
	}
}

func TestImportCookiesRejectsEmpty(t *testing.T) {
	store := NewSessionStore("", &http.Client{})
	sess := store.Create()

	if n := store.ImportCookies(sess, "", ""); n != 0 {
		t.Errorf("空串应导入 0 条，实际 %d", n)
	}
	if sess.LoggedIn() {
		t.Error("空串不该产生登录态")
	}
	// nil 会话不能 panic
	if n := store.ImportCookies(nil, "SESSDATA=x", ""); n != 0 {
		t.Errorf("nil 会话应返回 0，实际 %d", n)
	}
}

func TestRequestSessionID(t *testing.T) {
	r, _ := http.NewRequest("GET", "/bili/api/x?sid=query-sid", nil)
	if got := requestSessionID(r); got != "query-sid" {
		t.Errorf("应取查询参数，实际 %q", got)
	}
	r.Header.Set("X-Session", "header-sid")
	if got := requestSessionID(r); got != "header-sid" {
		t.Errorf("头应优先于查询参数，实际 %q", got)
	}
}
