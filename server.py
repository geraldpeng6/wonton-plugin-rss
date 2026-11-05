"""RSS 插件后端：只用 Python 标准库，数据存 /data/rss.json。

结构：state 里的每个订阅是一个 dict（articles 带正文），API 全量返回 state。
抓取在锁外进行，改动和落盘都在锁内；抓取失败记进 feed["error"]，由页面如实显示。
"""

import gzip
import hashlib
import json
import os
import re
import secrets
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from html import escape
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from pathlib import Path
from urllib.parse import unquote, urlsplit
from urllib.request import Request, urlopen

DATA = Path("/data/rss.json")
PAGE = b""
PORT = 8080

FETCH_TIMEOUT = 15
MAX_FEED_BYTES = 5 * 1024 * 1024
MAX_FEEDS = 64
MAX_ARTICLES = 50        # 每个订阅保留的文章数
MAX_CONTENT_CHARS = 60000
MAX_BODY = 4 * 1024
REFRESH_WORKERS = 4

STATE_LOCK = threading.Lock()


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# ---------- 存取 ----------

def load():
    try:
        state = json.loads(DATA.read_text())
    except FileNotFoundError:
        return {"feeds": []}
    except ValueError as e:
        # 数据坏了如实报错，绝不悄悄清空重写。
        raise ApiError(500, f"数据文件损坏（{DATA}）：{e}") from e
    if not isinstance(state, dict) or not isinstance(state.get("feeds"), list):
        raise ApiError(500, f"数据文件格式不对（{DATA}）")
    return state


def save(state):
    fd, tmp = tempfile.mkstemp(dir=DATA.parent)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp, DATA)


# ---------- 抓回来的 HTML：白名单过滤 ----------

ALLOWED_TAGS = {
    "p", "br", "hr", "a", "img", "blockquote", "pre", "code",
    "h1", "h2", "h3", "h4", "h5", "h6",
    "strong", "em", "b", "i", "u", "s", "del", "ins", "sup", "sub", "small",
    "ul", "ol", "li", "table", "thead", "tbody", "tr", "td", "th",
    "figure", "figcaption",
}
VOID_TAGS = {"br", "hr", "img"}
DROPPED_WITH_CONTENT = {
    "script", "style", "iframe", "object", "embed", "noscript",
    "svg", "form", "button", "select", "textarea", "template",
}
SAFE_URL = re.compile(r"^(https?:|mailto:)", re.I)


def _fmt_attrs(attrs):
    parts = [f' {n}="{escape(str(v), quote=True)}"' for n, v in attrs]
    return "".join(parts)


class Sanitizer(HTMLParser):
    """把订阅源里的 HTML 收紧成白名单子集，链接只留 http(s)/mailto。"""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.stack = []
        self.skip_depth = 0

    def _start(self, tag, attrs, self_closing):
        tag = tag.lower()
        if tag in DROPPED_WITH_CONTENT and not self_closing:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if tag not in ALLOWED_TAGS:
            return
        clean = []
        for name, value in attrs:
            name = name.lower()
            if name in ("href", "src"):
                value = (value or "").strip()
                if not SAFE_URL.match(value):
                    continue
                clean.append((name, value))
            elif name == "alt":
                clean.append((name, value or ""))
        if tag == "a":
            clean += [("rel", "noopener noreferrer"), ("target", "_blank")]
        if tag in VOID_TAGS or self_closing:
            self.out.append(f"<{tag}{_fmt_attrs(clean)}>")
            return
        self.stack.append(tag)
        self.out.append(f"<{tag}{_fmt_attrs(clean)}>")

    def handle_starttag(self, tag, attrs):
        self._start(tag, attrs, False)

    def handle_startendtag(self, tag, attrs):
        self._start(tag, attrs, True)

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in DROPPED_WITH_CONTENT:
            self.skip_depth = max(0, self.skip_depth - 1)
            return
        if self.skip_depth or tag not in ALLOWED_TAGS or tag in VOID_TAGS:
            return
        if tag in self.stack:
            while self.stack:
                open_tag = self.stack.pop()
                self.out.append(f"</{open_tag}>")
                if open_tag == tag:
                    break

    def handle_data(self, data):
        if not self.skip_depth:
            self.out.append(escape(data))


def sanitize_html(raw):
    if not raw:
        return ""
    parser = Sanitizer()
    try:
        parser.feed(raw)
        parser.close()
    except Exception:
        # 解析不了的碎片段按纯文本处理，不让任何未过滤的标记出去。
        return "<p>%s</p>" % escape(re.sub(r"<[^>]*>", "", raw))
    while parser.stack:
        parser.out.append(f"</{parser.stack.pop()}>")
    html = "".join(parser.out).strip()
    if len(html) > MAX_CONTENT_CHARS:
        html = html[:MAX_CONTENT_CHARS] + "<p>（内容过长，已截断）</p>"
    return html


class TextGrabber(HTMLParser):
    """取纯文字做摘要：丢掉不该显示的部分，其余标签只留文字。"""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag.lower() in DROPPED_WITH_CONTENT:
            self.skip_depth += 1
        elif tag.lower() in ("p", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "tr"):
            self.parts.append(" ")

    def handle_endtag(self, tag):
        if tag.lower() in DROPPED_WITH_CONTENT:
            self.skip_depth = max(0, self.skip_depth - 1)

    def handle_data(self, data):
        if not self.skip_depth:
            self.parts.append(data)


def to_text(raw, limit=None):
    if not raw:
        return ""
    grabber = TextGrabber()
    try:
        grabber.feed(raw)
        grabber.close()
    except Exception:
        grabber.parts = [re.sub(r"<[^>]*>", " ", raw)]
    text = re.sub(r"\s+", " ", "".join(grabber.parts)).strip()
    return text[:limit] if limit else text


# ---------- 订阅源解析（RSS 2.0 / RSS 1.0 / Atom）----------

def _local(el):
    return el.tag.rsplit("}", 1)[-1].lower() if isinstance(el.tag, str) else ""


def _kids(el, *names):
    return [c for c in el if _local(c) in names]


def _first(el, *names):
    for c in el:
        if _local(c) in names:
            return c
    return None


def _text(el):
    if el is None:
        return ""
    return re.sub(r"\s+", " ", "".join(el.itertext())).strip()


def _link(el):
    """RSS 的 link 是文字；Atom 的是 href 属性。页面要把链接直接当 href 用，只留 http(s)，别的当没有。"""
    for c in _kids(el, "link"):
        href = c.get("href", "").strip()
        if not href:
            text = _text(c)
            href = text
        if href[:9].lower() == "https://" or href[:8].lower() == "http://":
            return href
    return ""


def parse_date(text):
    if not text:
        return None
    text = text.strip()
    try:
        return int(parsedate_to_datetime(text).timestamp())
    except Exception:
        pass
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return int(parsed.timestamp())
    except Exception:
        return None


def _article_id(url, title):
    """用链接（没有链接时用标题）的哈希当 id，重抓时才能对上同一篇。"""
    base = (url or title or "").encode("utf-8", "replace")
    return hashlib.sha256(base).hexdigest()[:12]


def parse_feed(body):
    try:
        root = ET.fromstring(body)
    except ET.ParseError as e:
        raise ValueError(f"返回的不是合法的 XML：{e}") from e
    if _local(root) == "rss":
        channel = _first(root, "channel")
        if channel is None:
            raise ValueError("RSS 里没有 channel")
        items = _kids(channel, "item")
        meta = {"title": _text(_first(channel, "title")), "site": _link(channel)}
    elif _local(root) == "rdf":
        items = [el for el in root.iter() if _local(el) == "item"]
        channel = _first(root, "channel")
        meta = {"title": _text(_first(channel, "title")) if channel is not None else "",
                "site": _link(channel) if channel is not None else ""}
    elif _local(root) == "feed":
        items = _kids(root, "entry")
        meta = {"title": _text(_first(root, "title")), "site": _link(root)}
    else:
        raise ValueError("不是 RSS 或 Atom 格式")
    meta["articles"] = [a for a in (_parse_item(i) for i in items) if a]
    return meta


def _parse_item(el):
    title = _text(_first(el, "title"))
    link = _link(el)
    if not title and not link:
        return None
    # 注意：Element 没有子元素时按布尔值是 False，这里只能判 is not None。
    content_el = _first(el, "encoded")
    if content_el is None:
        content_el = _first(el, "content")
    summary_el = _first(el, "description")
    if summary_el is None:
        summary_el = _first(el, "summary")
    content_html = _text(content_el) if content_el is not None else ""
    summary_raw = _text(summary_el) if summary_el is not None else ""
    body_html = sanitize_html(content_html or summary_raw)
    date_text = _text(_first(el, "pubdate")) or _text(_first(el, "date")) \
        or _text(_first(el, "published")) or _text(_first(el, "updated"))
    return {
        "id": _article_id(link, title),
        "title": title or to_text(summary_raw, 80) or "(无标题)",
        "link": link,
        "published": parse_date(date_text),
        "summary": to_text(content_html or summary_raw, 200),
        "content": body_html,
    }


# ---------- 抓取 ----------

def fetch_feed(url):
    """抓一个订阅源，返回 parse_feed 的结果；失败抛 ApiError(502)。"""
    request = Request(url, headers={
        "User-Agent": "WontonRSS/0.1 (+https://github.com/geraldpeng6/wonton-plugin-rss)",
        "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*",
    })
    try:
        with urlopen(request, timeout=FETCH_TIMEOUT) as res:
            body = res.read(MAX_FEED_BYTES + 1)
            encoding = (res.headers.get("Content-Encoding") or "").lower()
            charset = res.headers.get_content_charset()
    except HTTPError as e:
        raise ApiError(502, f"订阅源返回 HTTP {e.code}") from e
    except URLError as e:
        raise ApiError(502, f"连不上订阅源：{e.reason}") from e
    except TimeoutError as e:
        raise ApiError(502, f"{FETCH_TIMEOUT} 秒内没有等到订阅源") from e
    except OSError as e:
        raise ApiError(502, f"网络错误：{e}") from e
    if len(body) > MAX_FEED_BYTES:
        raise ApiError(502, f"订阅源超过 {MAX_FEED_BYTES // (1024 * 1024)} MiB")
    if encoding == "gzip":
        try:
            body = gzip.decompress(body)
        except OSError as e:
            raise ApiError(502, f"订阅源的 gzip 坏了：{e}") from e
    if charset and charset.lower() not in ("utf-8", "us-ascii") and not body.lstrip()[:40].lower().startswith(b"<?xml"):
        body = body.decode(charset, "replace").encode("utf-8")
    try:
        return parse_feed(body)
    except ValueError as e:
        raise ApiError(502, str(e)) from e


def merge_articles(old, fresh):
    """新抓的在前：同一篇被源里更新过时，用新内容，不留在手上的旧文。"""
    by_id = {}
    for a in fresh + old:
        if a["id"] not in by_id:
            by_id[a["id"]] = a
    articles = list(by_id.values())
    articles.sort(key=lambda a: a["published"] or 0, reverse=True)
    return articles[:MAX_ARTICLES]


def validate_url(url):
    try:
        parts = urlsplit(url.strip())
    except ValueError:
        raise ApiError(400, "订阅地址不合法")
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ApiError(400, "订阅地址要以 http:// 或 https:// 开头")
    return url.strip()


def _apply_result(feed, parsed, error):
    """把一次抓取的结果（或失败原因）记到订阅上；失败不动旧文章。"""
    if parsed is None:
        feed["error"] = error
        return
    feed["title"] = parsed["title"] or feed["title"]
    feed["site"] = parsed["site"] or feed["site"]
    feed["articles"] = merge_articles(feed["articles"], parsed["articles"])
    feed["fetched_at"] = int(time.time())
    feed["error"] = None


def public_state(state):
    return {"feeds": state["feeds"]}


# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, status, body=b"", kind="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def reply_json(self, status, payload):
        self.reply(status, json.dumps(payload, ensure_ascii=False).encode())

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise ApiError(400, "请求体太大")
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            raise ApiError(400, "请求体不是 JSON")

    def do_GET(self):
        path = unquote(self.path.split("?", 1)[0])
        try:
            if path == "/healthz":
                self.reply(200, b"ok", "text/plain")
            elif path == "/" or path == "/index.html":
                self.reply(200, PAGE, "text/html; charset=utf-8")
            elif path == "/api/feeds":
                self.reply_json(200, public_state(load()))
            else:
                self.reply_json(404, {"error": "没有这个地址"})
        except ApiError as e:
            self.reply_json(e.status, {"error": e.message})

    def do_POST(self):
        path = unquote(self.path.split("?", 1)[0])
        try:
            if path == "/api/feeds":
                body = self.read_json()
                url = body.get("url") if isinstance(body, dict) else None
                if not isinstance(url, str) or not url.strip():
                    raise ApiError(400, "要填订阅地址")
                self.reply_json(200, self.add_feed(url))
            elif path == "/api/refresh":
                self.reply_json(200, self.refresh_all())
            elif re.fullmatch(r"/api/feeds/[^/]+/refresh", path):
                feed_id = path.split("/")[3]
                self.reply_json(200, self.refresh_one(feed_id))
            else:
                raise ApiError(404, "没有这个地址")
        except ApiError as e:
            self.reply_json(e.status, {"error": e.message})

    def do_DELETE(self):
        path = unquote(self.path.split("?", 1)[0])
        if not re.fullmatch(r"/api/feeds/[^/]+", path):
            self.reply_json(404, {"error": "没有这个地址"})
            return
        feed_id = path.split("/")[3]
        try:
            with STATE_LOCK:
                state = load()
                before = len(state["feeds"])
                state["feeds"] = [f for f in state["feeds"] if f["id"] != feed_id]
                if len(state["feeds"]) == before:
                    raise ApiError(404, "没有这个订阅")
                save(state)
                body = public_state(state)
            self.reply_json(200, body)
        except ApiError as e:
            self.reply_json(e.status, {"error": e.message})

    def add_feed(self, raw_url):
        url = validate_url(raw_url)
        with STATE_LOCK:
            state = load()
            if any(f["url"] == url for f in state["feeds"]):
                raise ApiError(400, "已经订阅过这个地址")
            if len(state["feeds"]) >= MAX_FEEDS:
                raise ApiError(400, f"最多订阅 {MAX_FEEDS} 个")
        parsed = fetch_feed(url)
        feed = {
            "id": secrets.token_hex(4),
            "url": url,
            "title": parsed["title"] or urlsplit(url).hostname or url,
            "site": parsed["site"],
            "added_at": int(time.time()),
            "fetched_at": int(time.time()),
            "error": None,
            "articles": merge_articles([], parsed["articles"]),
        }

        def insert(state):
            # 两个人同时加同一个地址：后写进来的判重复。
            if any(f["url"] == url for f in state["feeds"]):
                raise ApiError(400, "已经订阅过这个地址")
            if len(state["feeds"]) >= MAX_FEEDS:
                raise ApiError(400, f"最多订阅 {MAX_FEEDS} 个")
            state["feeds"].append(feed)
        with STATE_LOCK:
            state = load()
            insert(state)
            save(state)
            return public_state(state)

    def refresh_one(self, feed_id):
        with STATE_LOCK:
            state = load()
            feed = next((f for f in state["feeds"] if f["id"] == feed_id), None)
            if feed is None:
                raise ApiError(404, "没有这个订阅")
            url = feed["url"]
        # 抓取在锁外；写回时订阅可能已被删掉，找不到就当没这回事。
        try:
            parsed = fetch_feed(url)
            error = None
        except ApiError as e:
            parsed = None
            error = e.message
        with STATE_LOCK:
            state = load()
            feed = next((f for f in state["feeds"] if f["id"] == feed_id), None)
            if feed is not None:
                _apply_result(feed, parsed, error)
                save(state)
            return public_state(state)

    def refresh_all(self):
        with STATE_LOCK:
            state = load()
            urls = {f["id"]: f["url"] for f in state["feeds"]}
        results = {}
        if urls:
            with ThreadPoolExecutor(max_workers=REFRESH_WORKERS) as pool:
                waiting = [(pool.submit(fetch_feed, url), fid) for fid, url in urls.items()]
                for future, fid in waiting:
                    try:
                        results[fid] = future.result()
                    except ApiError as e:
                        results[fid] = e
        with STATE_LOCK:
            state = load()
            for feed in state["feeds"]:
                outcome = results.get(feed["id"])
                if isinstance(outcome, ApiError):
                    _apply_result(feed, None, outcome.message)
                elif outcome is not None:
                    _apply_result(feed, outcome, None)
            save(state)
            return public_state(state)


def main():
    global DATA, PAGE, PORT
    DATA = Path(os.environ.get("WONTON_RSS_DATA", "/data")) / "rss.json"
    PAGE = Path(os.environ.get("WONTON_RSS_PAGE", "/app/index.html")).read_bytes()
    PORT = int(os.environ.get("WONTON_RSS_PORT", "8080"))
    DATA.parent.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"rss: listening on {PORT}, data at {DATA}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
