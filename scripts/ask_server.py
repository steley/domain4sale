#!/usr/bin/env python3
"""Caddy on_demand_tls 的域名白名单接口（ask endpoint）。

Caddy 在为某个域名签发证书前会先请求:
    GET http://127.0.0.1:5555/check?domain=example.com
返回 200 表示"这个域名是我的，允许签发"；403 及其他状态码一律拒绝。

只监听 127.0.0.1，外部无法访问。domains.json 每次被修改后自动重新加载
（按文件 mtime 缓存），所以更新价格数据后无需重启本服务。
用 systemd 常驻运行，见 deploy/domain-sale-ask.service。
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

DOMAINS_JSON = Path(os.environ.get(
    "DOMAINS_JSON", "/var/www/domain-sale/public/data/domains.json"))
HOST = os.environ.get("ASK_HOST", "127.0.0.1")
PORT = int(os.environ.get("ASK_PORT", "5555"))

_cache = {"mtime": None, "domains": set()}


def load_domains():
    """读取白名单，文件缺失/损坏时返回空集合（拒绝签发，宁可漏不可滥）。"""
    try:
        mtime = DOMAINS_JSON.stat().st_mtime
    except OSError:
        return set()
    if _cache["mtime"] != mtime:
        try:
            data = json.loads(DOMAINS_JSON.read_text(encoding="utf-8"))
            _cache["domains"] = set(data.keys())
            _cache["mtime"] = mtime
        except (OSError, ValueError):
            return set()
    return _cache["domains"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        domain = (q.get("domain") or [""])[0].strip().lower()
        if domain.startswith("www."):
            domain = domain[4:]
        allowed = bool(domain) and domain in load_domains()
        self.send_response(200 if allowed else 403)
        self.end_headers()

    def log_message(self, fmt, *args):
        print(f"[ask] {fmt % args}", flush=True)


if __name__ == "__main__":
    print(f"ask endpoint: http://{HOST}:{PORT}/check  (data: {DOMAINS_JSON})",
          flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
