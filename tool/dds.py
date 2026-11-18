"""连 Flutter Web 的 DDS，读日志 / 列 flutter_skill 扩展 / 调扩展。

用法：
  python dds.py <ws_url> [方法名] [参数JSON]

不给方法名时：列出 isolate 的扩展列表（含 ext.flutter_skill.*）。
"""
import json
import sys
import time

import websocket


def connect(ws_url):
    ws = websocket.create_connection(ws_url, timeout=15)
    seq = [0]

    def call(method, params=None):
        seq[0] += 1
        msg = {"jsonrpc": "2.0", "id": seq[0], "method": method}
        if params:
            msg["params"] = params
        ws.send(json.dumps(msg))
        deadline = time.time() + 15
        while time.time() < deadline:
            res = json.loads(ws.recv())
            if res.get("id") == seq[0]:
                return res
        raise TimeoutError(f"{method} 超时")

    return ws, call


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    ws_url = sys.argv[1]
    ws, call = connect(ws_url)

    vm = call("getVM")
    isolates = vm.get("result", {}).get("isolates", [])
    if not isolates:
        print("没有 isolate（页面没启动？）")
        return 1

    if len(sys.argv) == 2:
        for iso in isolates:
            info = call("getIsolate", {"isolateId": iso["id"]})
            exts = info.get("result", {}).get("extensionRPCs", [])
            print(f"=== {iso.get('name')} ({iso['id']}) 扩展 {len(exts)} 个 ===")
            for e in sorted(exts):
                print(" ", e)
        ws.close()
        return 0

    method = sys.argv[2]
    params = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    params.setdefault("isolateId", isolates[0]["id"])
    res = call(method, params)
    # 不截断：调用方常常要把结果直接喂给下一个 json 解析器，
    # 截断会让 JSON 变成非法文本（踩过一次，白查半天）。
    print(json.dumps(res, ensure_ascii=False))
    ws.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
