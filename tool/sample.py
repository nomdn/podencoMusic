"""弹幕引擎采样器：等页面连上 → 周期调 ext.podenco/dm → 落 jsonl + 汇总。

比用 agent 跑更抗环境抖动：它只是一个进程，结论写文件。

用法：python tool/sample.py [采样次数] [间隔秒]
"""
import json
import os
import re
import sys
import time

import websocket

# 注意：Git Bash 的 /tmp 实际是 %TEMP%，python 里写 "/tmp" 会被解析成 C:\tmp
# ——两个路径不是一回事，直接用环境变量拼，避免采样器空转。
_TMP = os.environ.get("TEMP", "/tmp")
LOG = os.path.join(_TMP, "flutter_dev.log")
OUT = os.path.join(_TMP, "dm_sample.jsonl")


def find_ws():
    try:
        txt = open(LOG, encoding="utf-8", errors="ignore").read()
    except OSError:
        return None
    hits = re.findall(r"ws://127\.0\.0\.1:\d+/[A-Za-z0-9_=-]+/ws", txt)
    return hits[-1] if hits else None


class Probe:
    def __init__(self, url):
        self.url = url
        self.ws = websocket.create_connection(url, timeout=20)
        self.seq = 0
        self.isolate = None
        self.refresh_isolate()

    def call(self, method, params=None):
        self.seq += 1
        msg = {"jsonrpc": "2.0", "id": self.seq, "method": method}
        if params:
            msg["params"] = params
        self.ws.send(json.dumps(msg))
        deadline = time.time() + 20
        while time.time() < deadline:
            res = json.loads(self.ws.recv())
            if res.get("id") == self.seq:
                return res
        raise TimeoutError(method)

    def refresh_isolate(self):
        """取最新的 isolate。页面刷新后 DWDS 会换 isolate，旧的调不动。"""
        vm = self.call("getVM")
        isos = vm.get("result", {}).get("isolates", [])
        if not isos:
            raise RuntimeError("no isolate yet")
        self.isolate = isos[-1]["id"]

    def reconnect(self):
        try:
            self.ws.close()
        except Exception:
            pass
        self.ws = websocket.create_connection(self.url, timeout=20)
        self.seq = 0
        self.refresh_isolate()

    def snapshot(self):
        """一次采样：失败就先换 isolate 再试，仍失败就重连。"""
        for attempt in range(3):
            try:
                if attempt > 0:
                    self.refresh_isolate()
                res = self.call("ext.podenco/dm", {"isolateId": self.isolate})
                if "error" in res:
                    raise RuntimeError(res["error"].get("message", "ext error"))
                return res.get("result", {})
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(1)
        raise RuntimeError("unreachable")


def summarize(rows):
    if not rows:
        print("没有样本")
        return
    ok = [r for r in rows if isinstance(r, dict) and r.get("mounted")]
    print(f"样本 {len(rows)}，其中已挂载弹幕层 {len(ok)}")
    if not ok:
        print("全部 mounted=false：用户没进视频页")
        return
    at_dup = max(r.get("atDup", 0) for r in ok)
    text_dup = max(r.get("textDup", 0) for r in ok)
    frozen = max(
        sum(1 for e in r.get("entries", []) if e.get("type") == "S" and e.get("v", 1) == 0)
        for r in ok
    )
    active_max = max(r.get("active", 0) for r in ok)
    pend_max = max(r.get("pending", 0) for r in ok)
    bad_pause = [
        (r.get("posMs"), r.get("isPlaying"), r.get("engineRunning"))
        for r in ok
        if (not r.get("isPlaying")) and r.get("engineRunning")
    ]
    print(f"atDup 峰值={at_dup}（>1 才是真重复）")
    print(f"textDup 峰值={text_dup}（同文本多条，可能合法）")
    print(f"滚动弹幕 v=0 峰值={frozen}（>0 说明有冻结）")
    print(f"active 峰值={active_max}，pending 峰值={pend_max}")
    print(f"暂停但引擎仍 running 的样本数={len(bad_pause)} {bad_pause[:5]}")
    poses = [r.get("posMs", 0) for r in ok]
    print(f"posMs 范围 {min(poses)}~{max(poses)}ms")


def main():
    total = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    interval = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0

    print("等待页面就绪（最多 6 分钟）...", flush=True)
    probe = None
    for _ in range(180):
        url = find_ws()
        if url:
            try:
                probe = Probe(url)
                break
            except Exception:
                probe = None
        time.sleep(2)
    if not probe:
        print("页面始终没就绪，放弃")
        return 1
    print(f"WS={probe.url} isolate={probe.isolate}", flush=True)

    rows = []
    with open(OUT, "w", encoding="utf-8") as f:
        for i in range(total):
            try:
                data = probe.snapshot()
            except Exception as e:  # 刷新/断开/页面重载都会走到这
                data = {"mounted": False, "error": str(e)[:120]}
                try:
                    probe.reconnect()
                except Exception:
                    pass
            rows.append(data)
            f.write(json.dumps(data, ensure_ascii=False) + "\n")
            f.flush()
            if i % 10 == 0:
                brief = {
                    k: data.get(k)
                    for k in ("posMs", "isPlaying", "engineRunning", "active", "atDup")
                }
                print(f"  #{i} {json.dumps(brief, ensure_ascii=False)}", flush=True)
            time.sleep(interval)
    summarize(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
