# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
# shellcheck shell=bash disable=SC2034
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：本插件没有账号体系（sso: none），页面只有核心网关的会话能打开，没有应用自己的“当前用户”接口可断言，
#       写 IDENTITY_NA=1 并在 SMOKE_NOTE 里说明。dweb / web_get 是带用户会话的请求助手。
# 工具：本插件没有 mcp，SMOKE_NOTE 里写不适用，冒烟会输出 N/A。
# 订阅抓取要出网，起冒烟前设 WONTON_DEV_EGRESS_PROXY（见 smoke.sh 开头）。

web_assert() { grep -q '<title>动态</title>'; }

IDENTITY_NA=1
SMOKE_NOTE="无应用内账号体系（sso: none），网页只经核心网关的会话打开；工具不适用（没有 mcp）。"

marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/rss-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

# 数据：订阅就是用户数据（POST /api/feeds 时抓成功才落盘）。用 GitHub 的公开 Atom 源做标记地址：
# 冒烟就在 GitHub 的 CI 上跑，egress 链路对这个域的可用性有专门验证；data_write 存订阅、记下 id，
# data_check 重装/升级后订阅还在。
RSS_PROBE_FEED="https://github.com/geraldpeng6/wonton-docs/commits.atom"

rss_get() { # <方法> [JSON 体]：带网关会话调应用接口
  local method="$1" body="${2:-}"
  if [[ -n "$body" ]]; then
    curl -sS --noproxy '*' --max-time 60 --fail-with-body -b "${SMOKE_JAR:-}" -X "$method" \
      -H 'Content-Type: application/json' -d "$body" "$SMOKE_WEB_URL/api/feeds"
  else
    curl -sS --noproxy '*' --max-time 60 --fail-with-body -b "${SMOKE_JAR:-}" -X "$method" "$SMOKE_WEB_URL/api/feeds"
  fi
}

data_write() {
  local resp id
  [[ -n "${SMOKE_JAR:-}" && -n "${SMOKE_WEB_URL:-}" ]] || { echo "缺 SMOKE_JAR/SMOKE_WEB_URL"; return 1; }
  resp="$(rss_get POST "{\"url\":\"$RSS_PROBE_FEED\"}")" || { echo "加订阅失败：$resp"; return 1; }
  id="$(jq -r --arg u "$RSS_PROBE_FEED" '.feeds[] | select(.url == $u) | .id' <<<"$resp" | head -1)"
  [[ -n "$id" ]] || { echo "订阅列表里没有标记源：$(head -c 300 <<<"$resp")"; return 1; }
  jq -nc --arg i "$id" --arg u "$RSS_PROBE_FEED" '{id:$i,url:$u}' >"$(marker_file)"
}

data_check() {
  local resp
  resp="$(rss_get GET)" || { echo "读订阅列表失败：$resp"; return 1; }
  jq -e --arg u "$RSS_PROBE_FEED" 'any(.feeds[]; .url == $u)' <<<"$resp" >/dev/null ||
    { echo "升级/重装后找不到订阅 $RSS_PROBE_FEED：$(head -c 300 <<<"$resp")"; return 1; }
}
