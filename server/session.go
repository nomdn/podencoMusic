package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	// 访客 cookie（buvid3 / b_nut 这些）的有效期按 6 小时算，
	// 过期就重新抓一次。B站不会因为我们复用而报错。
	guestTTL = 6 * time.Hour

	// 登录会话闲置超过这个时间就回收，和B站 SESSDATA 的寿命对齐。
	sessionTTL = 30 * 24 * time.Hour
)

// Session 是一次客户端绑定。
//
// 存在的唯一理由是 Cookie 必须留在服务端：浏览器的 fetch 改不了 Cookie 头，
// 跨域的 Set-Cookie 又会被丢弃，所以登录态只能由我们保管，
// 客户端拿一个随机 id 来认领。
type Session struct {
	ID      string            `json:"id"`
	Cookies map[string]string `json:"cookies,omitempty"`

	// 登录后才有的展示信息，只用来给前端显示「已登录 xxx」
	UID  string `json:"uid,omitempty"`
	Name string `json:"name,omitempty"`

	Created  time.Time `json:"created"`
	LastUsed time.Time `json:"last_used"`
}

// LoggedIn 判断这个会话是否带了有效的登录凭证。
func (s *Session) LoggedIn() bool {
	return s != nil && s.Cookies["SESSDATA"] != ""
}

// CSRF 返回 bili_jct。发弹幕、发评论这类 POST 除了请求头里的 Cookie，
// 表单里还要单独带一份 csrf —— 浏览器读不到 Set-Cookie，客户端手上没有，
// 所以通过 sessionInfo 把它交回去（只回 csrf，不回 SESSDATA）。
func (s *Session) CSRF() string {
	if s == nil {
		return ""
	}
	return s.Cookies["bili_jct"]
}

// cookieHeader 拼出可以直接放进 Cookie 请求头的字符串。
func (s *Session) cookieHeader() string {
	if s == nil || len(s.Cookies) == 0 {
		return ""
	}
	// 顺序固定一下，方便比对日志
	keys := []string{"SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid", "buvid3", "b_nut"}
	parts := make([]string, 0, len(s.Cookies))
	seen := make(map[string]bool, len(keys))
	for _, k := range keys {
		if v := s.Cookies[k]; v != "" {
			parts = append(parts, k+"="+v)
			seen[k] = true
		}
	}
	for k, v := range s.Cookies {
		if seen[k] || v == "" {
			continue
		}
		parts = append(parts, k+"="+v)
	}
	return strings.Join(parts, "; ")
}

// SessionStore 是进程内的会话表，可选落盘。
//
// 落盘是为了让服务重启后用户不用重新扫码 —— 二维码登录的体验成本很高，
// 一重启就掉登录态会让人不想用。
type SessionStore struct {
	mu       sync.RWMutex
	sessions map[string]*Session
	path     string

	// 共享的访客身份。未登录的请求都用它，B站只认 buvid3 这一串，
	// 所有匿名用户共用一个不会互相干扰。
	guestMu     sync.Mutex
	guest       map[string]string
	guestAt     time.Time
	guestClient *http.Client
}

// NewSessionStore 创建会话表；path 为空表示不落盘。
func NewSessionStore(path string, client *http.Client) *SessionStore {
	s := &SessionStore{
		sessions:    make(map[string]*Session),
		path:        path,
		guestClient: client,
	}
	s.load()
	return s
}

// ── 会话基本操作 ──────────────────────────────────────────

// newID 生成 16 字节随机十六进制串。用 crypto/rand 而不是时间戳，
// 因为 sid 相当于一张门票，可猜就等于没有。
func newID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		// 极端情况下退回时间，至少不会崩
		return hex.EncodeToString([]byte(time.Now().Format(time.RFC3339Nano)))
	}
	return hex.EncodeToString(buf)
}

// Create 新建一个空会话。
func (s *SessionStore) Create() *Session {
	now := time.Now()
	sess := &Session{ID: newID(), Created: now, LastUsed: now}
	s.mu.Lock()
	s.sessions[sess.ID] = sess
	s.mu.Unlock()
	s.persist()
	return sess
}

// Get 按 id 取会话，同时刷新最后使用时间。
func (s *SessionStore) Get(id string) *Session {
	if id == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.sessions[id]
	if !ok {
		return nil
	}
	sess.LastUsed = time.Now()
	return sess
}

// Drop 删除会话（登出）。
func (s *SessionStore) Drop(id string) bool {
	s.mu.Lock()
	_, ok := s.sessions[id]
	delete(s.sessions, id)
	s.mu.Unlock()
	if ok {
		s.persist()
	}
	return ok
}

// requestSessionID 取出客户端声明的会话 id：
// 优先 X-Session 头，其次 sid 查询参数。
//
// 查询参数这条是给 <audio src> 这类没法带头部的场景准备的。
// 单独抽出来是因为 relay 也要用它判断「客户端是不是带了个服务端不认识的票」。
func requestSessionID(r *http.Request) string {
	if id := r.Header.Get("X-Session"); id != "" {
		return id
	}
	return r.URL.Query().Get("sid")
}

// fromRequest 从请求里认领会话。认不出来返回 nil（调用方降级成匿名）。
func (s *SessionStore) fromRequest(r *http.Request) *Session {
	return s.Get(requestSessionID(r))
}

// clearLogin 只清掉登录凭证，会话本身留着。
//
// 这样前端不用重新拿 sid，扫码成功后直接覆盖，
// 也避免用户点「退出登录」时把本地 sid 也一起弄丢。
func (s *SessionStore) clearLogin(sess *Session) {
	if sess == nil {
		return
	}
	s.mu.Lock()
	for _, key := range []string{"SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"} {
		delete(sess.Cookies, key)
	}
	sess.UID = ""
	sess.Name = ""
	s.mu.Unlock()
	slog.Info("已登出", "sid", sess.ID[:8])
	s.persist()
}

// importableKeys 是允许从客户端导入的 cookie 名。
//
// 不开放全量是因为没必要，也是防止有人把无关的键灌进来占空间。
var importableKeys = map[string]bool{
	"SESSDATA":          true,
	"bili_jct":          true,
	"DedeUserID":        true,
	"DedeUserID__ckMd5": true,
	"sid":               true,
	"buvid3":            true,
	"b_nut":             true,
}

// parseCookieHeader 把 `a=1; b=2` 拆成 map，只保留白名单里的键。
func parseCookieHeader(raw string) map[string]string {
	jar := make(map[string]string)
	for _, part := range strings.Split(raw, ";") {
		part = strings.TrimSpace(part)
		eq := strings.IndexByte(part, '=')
		if eq <= 0 {
			continue
		}
		name := strings.TrimSpace(part[:eq])
		value := strings.TrimSpace(part[eq+1:])
		if name == "" || value == "" || !importableKeys[name] {
			continue
		}
		jar[name] = value
	}
	return jar
}

// ImportCookies 接收客户端自己保存的 Cookie 串，让会话恢复登录态。
//
// 存在的理由是「服务端丢了状态，但客户端还留着凭证」：
// 反代换机器、重启且 state.json 没落盘、或者用户从 A 反代切到 B 反代，
// 这些情况下前端手上那份 cookie 完全有效，没必要让用户重新扫一次码。
//
// 只写不读 —— 这个接口不能用来查别人的凭证，所以响应里只告诉
// 导入了几条、以及现在是不是登录态，不回显任何 cookie 内容。
func (s *SessionStore) ImportCookies(sess *Session, raw, mid string) int {
	if sess == nil {
		return 0
	}
	jar := parseCookieHeader(raw)
	if len(jar) == 0 {
		return 0
	}

	s.mu.Lock()
	if sess.Cookies == nil {
		sess.Cookies = make(map[string]string, len(jar))
	}
	changed := 0
	for key, value := range jar {
		if sess.Cookies[key] != value {
			sess.Cookies[key] = value
			changed++
		}
	}
	// 访客项补齐：客户端那份可能只存了登录相关的 5 个键
	for key, value := range s.guest {
		if _, exist := sess.Cookies[key]; !exist {
			sess.Cookies[key] = value
		}
	}
	if mid != "" {
		sess.UID = mid
	} else if sess.UID == "" {
		sess.UID = sess.Cookies["DedeUserID"]
	}
	sess.LastUsed = time.Now()
	loggedIn := sess.LoggedIn()
	uid := sess.UID
	s.mu.Unlock()

	s.persist()
	if loggedIn {
		slog.Info("从客户端恢复登录态", "sid", sess.ID[:8], "uid", uid, "changed", changed)
	}
	return changed
}

// ── 访客 cookie ──────────────────────────────────────────

// GuestCookie 返回访客 Cookie 头，必要时去B站首页抓一份。
//
// 为什么需要它：搜索接口没有 buvid3 时会返回一张 HTML 风控页而不是 JSON。
// 以前这一步在客户端做（Dart 直接读 Set-Cookie），Web 上做不到，
// 所以挪到服务端。
func (s *SessionStore) GuestCookie(ctx context.Context) string {
	s.guestMu.Lock()
	defer s.guestMu.Unlock()

	s.mu.RLock()
	ready := len(s.guest) > 0 && time.Since(s.guestAt) < guestTTL
	cached := guestHeader(s.guest)
	s.mu.RUnlock()
	if ready {
		return cached
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://www.bilibili.com/", nil)
	if err != nil {
		return cached
	}
	req.Header.Set("User-Agent", browserUA)
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")

	resp, err := s.guestClient.Do(req)
	if err != nil {
		slog.Warn("抓访客 cookie 失败", "err", err)
		return cached
	}
	defer resp.Body.Close()

	jar := s.parseSetCookies(resp.Header.Values("Set-Cookie"))

	s.mu.Lock()
	if len(jar) > 0 {
		s.guest = jar
		s.guestAt = time.Now()
	}
	header := guestHeader(s.guest)
	s.mu.Unlock()

	if len(jar) > 0 {
		slog.Info("已刷新访客 cookie", "keys", mapKeys(jar))
		s.persist()
	}
	return header
}

func guestHeader(jar map[string]string) string {
	if len(jar) == 0 {
		return ""
	}
	parts := make([]string, 0, len(jar))
	for k, v := range jar {
		parts = append(parts, k+"="+v)
	}
	return strings.Join(parts, "; ")
}

// parseSetCookies 把 Set-Cookie 头的数组解析成 name→value。
//
// 只取第一段，属性（Path / Domain / Expires / Secure）全部丢掉：
// 我们不做浏览器式的 cookie 域匹配，只需要把值原样送回去。
func (s *SessionStore) parseSetCookies(headers []string) map[string]string {
	jar := make(map[string]string, len(headers))
	for _, raw := range headers {
		pair := strings.TrimSpace(strings.SplitN(raw, ";", 2)[0])
		eq := strings.IndexByte(pair, '=')
		if eq <= 0 {
			continue
		}
		name := strings.TrimSpace(pair[:eq])
		value := strings.TrimSpace(pair[eq+1:])
		if name == "" || value == "" {
			continue
		}
		jar[name] = value
	}
	return jar
}

// ── 登录结果捕获 ─────────────────────────────────────────

// captureLogin 从二维码轮询的响应里抠出登录 cookie。
//
// 两个来源都要看，因为B站两条路都用过：
//
//  1. `data.url` —— 跳转地址（passport.biligame.com/crossDomain?...）的查询参数里
//     带着 SESSDATA / bili_jct / DedeUserID。
//  2. `Set-Cookie` —— 一部分账号/实验分组下 url 是空的，凭证改为在响应头里下。
//
// 只认 (1) 的时候，那些落在 (2) 的账号扫码成功却拿不到凭证，界面上就是
// 「登录成功了但没拿到凭证，再试一次」，再试多少次都一样。
func (s *SessionStore) captureLogin(sess *Session, body []byte, header http.Header) {
	if sess == nil {
		return
	}

	var payload struct {
		Code int `json:"code"`
		Data struct {
			Code int    `json:"code"`
			URL  string `json:"url"`
		} `json:"data"`
	}
	via := ""
	jar := make(map[string]string, 8)

	if err := json.Unmarshal(body, &payload); err == nil {
		// data.code == 0 表示扫码成功；其余是未扫码 / 待确认 / 已失效
		if payload.Data.Code != 0 {
			return
		}
		if payload.Data.URL != "" {
			if u, err := url.Parse(payload.Data.URL); err == nil {
				q := u.Query()
				for _, key := range []string{"SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"} {
					if v := q.Get(key); v != "" {
						jar[key] = v
					}
				}
			}
			if jar["SESSDATA"] != "" {
				via = "url"
			}
		}
	}

	// 跳转地址里没有就翻响应头。Set-Cookie 里的值同样是 URL 编码过的，
	// 原样存起来即可（发回去时也是原样拼 Cookie 头）。
	if jar["SESSDATA"] == "" && header != nil {
		for _, raw := range header.Values("Set-Cookie") {
			for name, value := range parseSetCookieCredential(raw) {
				jar[name] = value
			}
		}
		if jar["SESSDATA"] != "" {
			via = "set-cookie"
		}
	}

	if jar["SESSDATA"] == "" {
		// 扫码成功但两条路都没有凭证：把线索留在日志里，别再让用户瞎点重试
		slog.Warn("扫码轮询成功但没拿到凭证",
			"sid", sess.ID[:8], "url_len", len(payload.Data.URL),
			"set_cookie", len(header.Values("Set-Cookie")))
		return
	}

	s.mu.Lock()
	if sess.Cookies == nil {
		sess.Cookies = make(map[string]string, len(jar))
	}
	for k, v := range jar {
		sess.Cookies[k] = v
	}
	// 登录态把访客那部分也并进去，两边的 buvid 是一致的
	for k, v := range s.guest {
		if _, exist := sess.Cookies[k]; !exist {
			sess.Cookies[k] = v
		}
	}
	sess.UID = sess.Cookies["DedeUserID"]
	sess.LastUsed = time.Now()
	s.mu.Unlock()

	slog.Info("扫码登录成功", "sid", sess.ID[:8], "uid", sess.UID, "via", via)
	s.persist()
}

// parseSetCookieCredential 从一条 Set-Cookie 里取出凭证键。
//
// 只认白名单，不整条搬：Set-Cookie 里还有 Path / Expires / Domain，
// 混进 Cookie 头里只会让上游困惑。
func parseSetCookieCredential(raw string) map[string]string {
	jar := make(map[string]string, 2)
	first := raw
	if i := strings.IndexByte(first, ';'); i >= 0 {
		first = first[:i]
	}
	first = strings.TrimSpace(first)
	eq := strings.IndexByte(first, '=')
	if eq <= 0 {
		return jar
	}
	name := strings.TrimSpace(first[:eq])
	value := strings.TrimSpace(first[eq+1:])
	if value == "" || !importableKeys[name] {
		return jar
	}
	// Set-Cookie 里的值可能被引号包着（例如 bili_jct），去掉再存
	value = strings.Trim(value, `"`)
	if value != "" {
		jar[name] = value
	}
	return jar
}

// ── 持久化 ──────────────────────────────────────────────

type persistedState struct {
	Guest    map[string]string `json:"guest,omitempty"`
	GuestAt  time.Time         `json:"guest_at,omitempty"`
	Sessions []*Session        `json:"sessions,omitempty"`
}

func (s *SessionStore) load() {
	if s.path == "" {
		return
	}
	raw, err := os.ReadFile(s.path)
	if err != nil {
		return
	}
	var state persistedState
	if err := json.Unmarshal(raw, &state); err != nil {
		slog.Warn("状态文件解析失败，忽略", "path", s.path, "err", err)
		return
	}
	s.mu.Lock()
	for _, sess := range state.Sessions {
		if sess == nil || sess.ID == "" {
			continue
		}
		s.sessions[sess.ID] = sess
	}
	if len(state.Guest) > 0 {
		s.guest = state.Guest
		s.guestAt = state.GuestAt
	}
	s.mu.Unlock()
	slog.Info("已载入状态", "sessions", len(state.Sessions))
}

// persist 把当前状态写盘。先写临时文件再改名，
// 避免进程在写一半时被杀导致文件残缺。
func (s *SessionStore) persist() {
	if s.path == "" {
		return
	}

	s.mu.RLock()
	state := persistedState{
		Guest:    s.guest,
		GuestAt:  s.guestAt,
		Sessions: make([]*Session, 0, len(s.sessions)),
	}
	for _, sess := range s.sessions {
		state.Sessions = append(state.Sessions, sess)
	}
	s.mu.RUnlock()

	raw, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return
	}

	dir := filepath.Dir(s.path)
	if dir != "" && dir != "." {
		_ = os.MkdirAll(dir, 0o700)
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		slog.Warn("写状态文件失败", "err", err)
		return
	}
	if err := os.Rename(tmp, s.path); err != nil {
		slog.Warn("替换状态文件失败", "err", err)
	}
}

// sweep 定期回收长时间没动过的会话，顺便压一下内存。
func (s *SessionStore) sweep() {
	cutoff := time.Now().Add(-sessionTTL)
	s.mu.Lock()
	removed := 0
	for id, sess := range s.sessions {
		if sess.LastUsed.Before(cutoff) {
			delete(s.sessions, id)
			removed++
		}
	}
	s.mu.Unlock()
	if removed > 0 {
		slog.Info("回收过期会话", "count", removed)
		s.persist()
	}
}

func mapKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}
