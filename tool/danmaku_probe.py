"""弹幕播放状态验证器：连 Flutter Web 的 DDS，驱动「播放 / 暂停」，用截图差异
判断屏幕上是否真的在动。

只依赖 tool/dds.py 同款的 VM Service 通道，不需要浏览器前台、不抢用户操作。

用法：
  python tool/danmaku_probe.py <ws_url> state
  python tool/danmaku_probe.py <ws_url> watch [秒数]     # 采样窗口内是否在动

输出一行 JSON 结论，便于子代理直接读取，不必回传图片。
"""
import base64
import hashlib
import io
import json
import sys
import time

import websocket

# 视频区在 Flutter 层里的相对范围（截图上方那块）。控制条的时间文字会随
# 播放变化，必须排除，否则「在动」会被误判成真。这块区域只含视频 + 弹幕。
VIDEO_TOP_RATIO = 0.0
VIDEO_BOTTOM_RATIO = 0.78


class Probe:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=20)
        self._seq = 0
        vm = self.call("getVM")
        self.isolate = vm["result"]["isolates"][0]["id"]

    def call(self, method, params=None):
        self._seq += 1
        msg = {"jsonrpc": "2.0", "id": self._seq, "method": method}
        if params:
            msg["params"] = params
        self.ws.send(json.dumps(msg))
        deadline = time.time() + 20
        while time.time() < deadline:
            res = json.loads(self.ws.recv())
            if res.get("id") == self._seq:
                if "error" in res:
                    raise RuntimeError(f"{method}: {res['error']}")
                return res
        raise TimeoutError(method)

    def shot_bytes(self):
        res = self.call(
            "ext.flutter.flutter_skill.screenshot",
            {"isolateId": self.isolate},
        )
        img = res["result"].get("image", "")
        if not img:
            raise RuntimeError(f"截图失败：{json.dumps(res)[:200]}")
        return base64.b64decode(img)

    def shot_crop(self):
        """截视频区并返回灰度字节块 + 尺寸，供帧间比较。"""
        from PIL import Image

        raw = self.shot_bytes()
        img = Image.open(io.BytesIO(raw)).convert("L")
        w, h = img.size
        box = (0, int(h * VIDEO_TOP_RATIO), w, int(h * VIDEO_BOTTOM_RATIO))
        return img.crop(box)

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


def diff_ratio(a, b):
    """两帧不同像素占比。PSNR 之类在这里没必要，占比足够判「动没动」。"""
    from PIL import ImageChops

    if a.size != b.size:
        return 1.0
    diff = ImageChops.difference(a, b)
    hist = diff.histogram()
    same = hist[0]
    total = a.size[0] * a.size[1]
    return 1.0 - (same / total if total else 0.0)


def cmd_state(p):
    img = p.shot_crop()
    digest = hashlib.md5(img.tobytes()).hexdigest()
    print(json.dumps({"size": img.size, "md5": digest}, ensure_ascii=False))


def cmd_watch(p, seconds=6.0, interval=1.5):
    """在给定窗口内连续采样，报告画面是否在变化。"""
    samples = []
    end = time.time() + seconds
    prev = p.shot_crop()
    while time.time() < end:
        time.sleep(interval)
        cur = p.shot_crop()
        samples.append(round(diff_ratio(prev, cur), 5))
        prev = cur
    moving = [r for r in samples if r > 0.0005]
    print(
        json.dumps(
            {
                "samples": samples,
                "moving_frames": len(moving),
                "total_frames": len(samples),
                "verdict": "moving" if moving else "static",
            },
            ensure_ascii=False,
        )
    )


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    url, cmd = sys.argv[1], sys.argv[2]
    p = Probe(url)
    try:
        if cmd == "state":
            cmd_state(p)
        elif cmd == "watch":
            secs = float(sys.argv[3]) if len(sys.argv) > 3 else 6.0
            cmd_watch(p, secs)
        else:
            print(f"未知命令 {cmd}")
            return 1
    finally:
        p.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
