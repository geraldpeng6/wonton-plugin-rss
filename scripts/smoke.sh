#!/usr/bin/env bash
# 插件合并前的端到端冒烟：用工作区的插件起一套一次性开发环境，四项真实请求，不用 mock。
#   scripts/dev.sh smoke
# 四项：装得上 / 网页打得开 / 用户身份能用 / 工具 Bot 调得到。任何 FAIL 退出非 0。
# 插件自己的探测在 scripts/smoke-probes.sh，写法见模板里的这个文件。
# 作者已有的 .wonton 不动：整个工作区复制到临时目录，用冒烟自己的实例，跑完删掉容器、网络、卷和目录。
#
# WONTON_DEV_EGRESS_PROXY：给了就先把它配成核心的出口代理（插件冷启动要出网时用），不给就不配。
set -uo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

for tool in docker curl jq python3 timeout nice flock; do
  need "$tool"
done

mkdir -p "$root/.wonton"
exec 9>"$root/.wonton/smoke.lock"
flock -n 9 || die "同一仓库的另一套冒烟正在跑"

work="$(mktemp -d "${TMPDIR:-/tmp}/wonton-smoke.XXXXXX")"
copy="$work/repo"
LOG="$root/.wonton/smoke.log"
: >"$LOG"
instance="smoke$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
SMOKE_DIR="$copy"
SMOKE_INSTANCE="$instance"
SMOKE_JAR="$copy/.wonton/session.cookies"
SMOKE_TOOLS="$work/tools.json"
DID_FAIL=0

say() { echo "== $*"; }
pass() { echo "PASS $1：$2"; }
fail() { echo "FAIL $1：$2"; DID_FAIL=1; }
na() { echo "N/A  $1：$2"; }

# #121：宿主机配了 Docker 客户端代理时，容器会带上 HTTP_PROXY，Hydra 的回环健康检查一直失败。
# 去掉 config.json 的 proxies，其余（凭据、context）留着。
docker_config="${DOCKER_CONFIG:-$HOME/.docker}"
if [[ -f "$docker_config/config.json" ]]; then
  mkdir -p "$work/docker-config"
  cp -a "$docker_config/." "$work/docker-config/"
  jq 'del(.proxies)' "$docker_config/config.json" >"$work/docker-config/config.json"
  export DOCKER_CONFIG="$work/docker-config"
fi

cleanup() {
  local image=""
  image="$(sed -n 's/^WONTON_CORE_IMAGE=//p' "$copy/.wonton/.env" 2>/dev/null | tail -1)"
  if [[ -f "$copy/.wonton/.env" ]]; then
    say "清理实例 $instance"
    (cd "$copy" && nice -n 19 timeout 900 scripts/dev.sh purge --yes) >>"$LOG" 2>&1
  fi
  docker ps -aq --filter "label=wonton.instance=$instance" | xargs -r docker rm -f >/dev/null 2>&1
  docker network ls -q --filter "label=wonton.instance=$instance" | xargs -r docker network rm >/dev/null 2>&1
  docker volume ls -q --filter "label=wonton.instance=$instance" | xargs -r docker volume rm >/dev/null 2>&1
  # 核心以 root 写数据目录，普通用户的 rm 删不动；purge 也失败时交给容器里的 root 删。
  if ! rm -rf "$work" 2>/dev/null; then
    [[ -n "$image" ]] && docker run --rm --user 0 --entrypoint rm -v "${work%/*}:/host-tmp" "$image" \
      -rf "/host-tmp/${work##*/}" >/dev/null 2>&1
    rm -rf "$work" 2>/dev/null
  fi
  local left
  left="$(docker ps -aq --filter "label=wonton.instance=$instance" | wc -l)"
  say "残留资源（实例 $instance）：$left"
  if [[ "$left" != 0 ]]; then
    echo "FAIL 清理：残留 $left 个资源"
    DID_FAIL=1
  fi
}

finish() {
  local rc=$?
  trap - EXIT
  cleanup || true
  if ((rc != 0)); then
    exit "$rc"
  elif ((DID_FAIL)); then
    echo
    echo "失败详情：$LOG"
    exit 1
  fi
  exit 0
}
trap finish EXIT

# 共用一台 Docker 时可以限制同时跑的验证栈：WONTON_SMOKE_MAX_STACKS=<套数>（只数别人的，自己还没起），
# WONTON_SMOKE_WAIT_MINUTES 是最多等多久（默认 45）。不设就不排队：自己的开发环境也算一套，默认限制会挡住只有一个人的主机。
if [[ -n "${WONTON_SMOKE_MAX_STACKS:-}" ]]; then
  [[ "$WONTON_SMOKE_MAX_STACKS" =~ ^[1-9][0-9]*$ ]] || die "WONTON_SMOKE_MAX_STACKS 要是正整数：$WONTON_SMOKE_MAX_STACKS"
  wait_minutes="${WONTON_SMOKE_WAIT_MINUTES:-45}"
  [[ "$wait_minutes" =~ ^[0-9]+$ ]] || die "WONTON_SMOKE_WAIT_MINUTES 要是整数：$wait_minutes"
  waited=0
  while foreign="$(docker ps --filter 'label=wonton.instance' --format '{{.Label "wonton.instance"}}' | sort -u | wc -l)"
    ((foreign >= WONTON_SMOKE_MAX_STACKS)); do
    ((waited == 0)) && say "已有 $foreign 套验证栈在跑（上限 $WONTON_SMOKE_MAX_STACKS），排队等待"
    ((waited >= wait_minutes)) && die "等了 $wait_minutes 分钟还是 $foreign 套验证栈，排队放弃（没有跑任何插件检查）"
    sleep 60
    waited=$((waited + 1))
  done
fi

say "复制工作区（不动 .wonton）"
mkdir "$copy"
tar -C "$root" --exclude=.wonton --exclude=.git -cf - . | tar -C "$copy" -xf - || die "复制工作区失败"
chmod -R a+rX "$copy"

smoke_dev() { (cd "$copy" && WONTON_DEV_STATE="$copy/.wonton" WONTON_INSTANCE="$instance" nice -n 19 scripts/dev.sh "$@"); }

status_wait() { # <插件 id> <次数>：等状态变成 running healthy
  local id="$1" tries="$2" i out line=""
  for ((i = 0; i < tries; i++)); do
    out="$(smoke_dev status 2>>"$LOG")"
    line="$(grep -F "$id" <<<"$out" | head -1)"
    if grep -q $'\trunning healthy\t' <<<"$line"; then
      printf '%s\n' "$line"
      return 0
    fi
    sleep 15
  done
  printf '%s\n' "$line"
  return 1
}

# 清单事实；compose 自己解析，不引额外依赖。
facts="$(cd "$copy" && docker compose -f docker-compose.yml config --no-interpolate --format json)" ||
  die "解析不了 docker-compose.yml"
plugin_id="$(jq -r '."x-wonton".id // empty' <<<"$facts")"
[[ -n "$plugin_id" ]] || die "清单没有 x-wonton.id"
slug="${plugin_id//./-}"
has_webui="$(jq -r 'if ."x-wonton".webui.service then 1 else 0 end' <<<"$facts")"
sso="$(jq -r '."x-wonton".webui.sso // "none"' <<<"$facts")"
has_mcp="$(jq -r 'if ."x-wonton".mcp.service then 1 else 0 end' <<<"$facts")"

probes="$copy/scripts/smoke-probes.sh"
IDENTITY_NA=0
MCP_TOOL=""
MCP_ARGS='{}'
SMOKE_NOTE=""
export WONTON_OWNER_EMAIL="${WONTON_OWNER_EMAIL:-owner@$instance.wonton.localhost}"
if [[ -f "$probes" ]]; then
  # shellcheck source=scripts/smoke-probes.sh
  . "$probes"
fi

# 公共助手，给探测用：dweb / web_get 带用户的会话，mcp 走同一套 dev.sh 入口。
dweb() { smoke_dev web --jar "$SMOKE_JAR" "$@"; }
web_get() { local path="$1"; shift; curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "$@" "$SMOKE_WEB_URL$path"; }
mcp() {
  local sub="${1:-}"
  shift || true
  if [[ "${1:-}" == http* ]]; then shift; fi
  smoke_dev mcp "$sub" "$@"
}
smoke_api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --noproxy '*' --fail-with-body -X "$method" -H "Authorization: Bearer $SMOKE_TOKEN" "$@" "$SMOKE_BASE$path"
}

# ---------- 1. 装得上 ----------
say "1. 装得上（check --official、install、running healthy）"
chk_out="$(cd "$copy" && nice -n 19 timeout 900 scripts/check.sh --official 2>&1)" && chk_rc=0 || chk_rc=$?
printf '%s\n' "$chk_out" >>"$LOG"
chk_first="$(head -1 <<<"$chk_out")"
if ((chk_rc != 0)); then
  fail 装得上 "check.sh --official 退出 $chk_rc：$chk_first"
  chk_note="check 不合格（$chk_first）；"
else
  chk_note="check --official 通过；"
fi

if ! smoke_dev up >>"$LOG" 2>&1; then
  fail 装得上 "dev.sh up 失败，看 $LOG"
  for item in 网页打得开 用户身份能用 工具Bot调得到; do fail "$item" "环境没起来"; done
  exit 0
fi
read_env() { sed -n "s/^$1=//p" "$copy/.wonton/.env" | tail -1; }
SMOKE_BASE="http://$instance.wonton.localhost:$(read_env WONTON_PORT)"
SMOKE_TOKEN="$(smoke_dev token)" || { fail 装得上 "读不到用户令牌"; exit 0; }
core="wonton-$instance--core"
SMOKE_OWNER="$(docker exec "$core" cat "$(read_env WONTON_DATA_DIR)/core/owner.json" 2>/dev/null | jq -r '.username // empty')"
SMOKE_OWNER="${SMOKE_OWNER:-owner}"
SMOKE_OWNER_EMAIL="$(read_env WONTON_OWNER_EMAIL)"
SMOKE_PLUGIN_ID="$plugin_id" SMOKE_SLUG="$slug" SMOKE_SSO="$sso" SMOKE_MCP="$has_mcp"
export SMOKE_DIR SMOKE_INSTANCE SMOKE_JAR SMOKE_TOOLS SMOKE_BASE SMOKE_TOKEN SMOKE_OWNER SMOKE_OWNER_EMAIL
export SMOKE_PLUGIN_ID SMOKE_SLUG SMOKE_SSO SMOKE_MCP

if [[ -n "${WONTON_DEV_EGRESS_PROXY:-}" ]]; then
  say "配置出口代理 $WONTON_DEV_EGRESS_PROXY"
  cur="$(smoke_api GET /_wonton/api/egress-proxy)" || { fail 装得上 "读不到出口代理设置"; exit 0; }
  body="$(jq -nc --arg u "$WONTON_DEV_EGRESS_PROXY" --argjson r "$(jq -c '[.restarts[].id]' <<<"$cur")" \
    '{url:$u,direct_cidrs:[],restarts:$r}')"
  smoke_api PUT /_wonton/api/egress-proxy -H 'Content-Type: application/json' -d "$body" >/dev/null ||
    { fail 装得上 "配置出口代理失败"; exit 0; }
  probe="$cur"
  for _ in $(seq 1 60); do
    probe="$(smoke_api GET /_wonton/api/egress-proxy)" || break
    [[ "$(jq -r '.plugin_path.problem // "none"' <<<"$probe")" == none ]] && break
    sleep 2
  done
  [[ "$(jq -r '.plugin_path.problem // "none"' <<<"$probe")" == none ]] ||
    { fail 装得上 "出口代理探测没通：$(jq -c '.plugin_path' <<<"$probe")"; exit 0; }
fi

# Hermes 是核心预装的默认 Agent：工具 Bot 要用，装得上这项也确认它健康（不锁版本）。
hermes_line="$(status_wait com.nousresearch.hermes 40)" ||
  { fail 装得上 "预装 Hermes 不是 running healthy：$hermes_line"; exit 0; }
say "Hermes：$hermes_line"
if [[ "$(jq -r '(."x-wonton".permissions // []) | index("models") // empty' <<<"$facts")" != "" ]]; then
  magpie_line="$(status_wait ai.usemagpie.magpie 30)" ||
    { fail 装得上 "模型网关不是 running healthy：$magpie_line"; exit 0; }
fi

if declare -F before_install >/dev/null; then
  say "装前准备（before_install）"
  before_install >>"$LOG" 2>&1 || { fail 装得上 "before_install 失败，看 $LOG"; exit 0; }
fi
if ! smoke_dev install --yes >>"$LOG" 2>&1; then
  fail 装得上 "dev.sh install --yes 失败，看 $LOG"
  for item in 网页打得开 用户身份能用 工具Bot调得到; do fail "$item" "装不上"; done
  exit 0
fi
line="$(status_wait "$plugin_id" 40)" || { fail 装得上 "状态不是 running healthy：$line"; exit 0; }
if ((chk_rc != 0)); then
  fail 装得上 "$chk_note install 后状态 running healthy"
else
  pass 装得上 "${chk_note}install 后状态 running healthy（$line）；Hermes running healthy"
fi

# ---------- 2/3. 网页与用户身份 ----------
say "2/3. 网页打得开与用户身份能用"
plugins_json="$(smoke_api GET /_wonton/api/plugins)" || { fail 网页打得开 "列不出插件"; fail 用户身份能用 "列不出插件"; exit 0; }
SMOKE_WEB_URL="$(jq -rn --arg id "$plugin_id" --arg json "$plugins_json" '$json | fromjson | .plugins[] | select(.id==$id) | .web_url // ""')"
export SMOKE_WEB_URL

if [[ "$has_webui" != 1 ]]; then
  na 网页打得开 "清单没有 webui"
  na 用户身份能用 "清单没有 webui"
else
  smoke_dev session >>"$LOG" 2>&1 || say "会话建立失败（后面的探测会失败）"
  unauth_code="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 60 "$SMOKE_WEB_URL/")"
  unauth_evi="匿名返回 $unauth_code"
  case "$unauth_code" in
    401) unauth_evi="匿名 401" ;;
    301|302|303|307|308)
      loc="$(curl -sS --noproxy '*' -o /dev/null -w '%{redirect_url}' --max-time 60 "$SMOKE_WEB_URL/")"
      unauth_evi="匿名 $unauth_code → $loc"
      grep -q "/_wonton/login" <<<"$loc" && unauth_evi="$unauth_evi（核心登录页）" ;;
  esac
  case "$unauth_evi" in
    *"匿名 401"*|*"核心登录页"*) : ;;
    *) fail 网页打得开 "网关没拒绝匿名请求：$unauth_evi" ;;
  esac
  body="$(dweb / -L 2>>"$LOG")" || { say "dweb 失败一次，重试"; body="$(dweb / -L 2>>"$LOG")" || body=""; }
  if ! declare -F web_assert >/dev/null; then
    fail 网页打得开 "没写探测：在 scripts/smoke-probes.sh 里写 web_assert（标准输入读页面，命中真实页面时返回 0）；$unauth_evi"
  elif [[ -n "$body" ]] && web_assert <<<"$body" >>"$LOG" 2>&1; then
    pass 网页打得开 "应用真实页面特征命中；$unauth_evi"
  else
    fail 网页打得开 "页面特征没命中，开头：$(head -c 200 <<<"$body" | tr '\n' ' ')"
  fi

  if [[ "$IDENTITY_NA" == 1 ]]; then
    na 用户身份能用 "${SMOKE_NOTE:-应用没有可断言的用户体系}"
  elif ! declare -F identity_check >/dev/null; then
    fail 用户身份能用 "没写探测：在 scripts/smoke-probes.sh 里写 identity_check（调应用自己的当前用户接口，断言是用户管理员；没有用户体系就写 IDENTITY_NA=1）"
  elif identity_check >>"$LOG" 2>&1; then
    pass 用户身份能用 "sso=$sso：应用认出用户 $SMOKE_OWNER（管理员）"
  else
    fail 用户身份能用 "identity_check 失败，见 $LOG 末尾：$(tail -c 200 "$LOG" | tr '\n' ' ')"
  fi
fi

# ---------- 4. 工具 Bot 调得到 ----------
say "4. 工具 Bot 调得到"
if [[ "$has_mcp" != 1 ]]; then
  na 工具Bot调得到 "清单没有 mcp"
elif [[ ! -f "$probes" ]]; then
  fail 工具Bot调得到 "没写探测：在 scripts/smoke-probes.sh 里写 MCP_TOOL=<只读工具>、MCP_ARGS 和 mcp_assert（标准输入读结果）"
elif [[ -z "$MCP_TOOL" ]] && ! declare -F mcp_check >/dev/null; then
  fail 工具Bot调得到 "没写探测：在 scripts/smoke-probes.sh 里写 MCP_TOOL=<只读工具>、MCP_ARGS 和 mcp_assert"
else
  gw="wonton-$instance--com-nousresearch-hermes--gateway"
  hermes_line="$(status_wait com.nousresearch.hermes 40)" ||
    { fail 工具Bot调得到 "Hermes 不是 running healthy：$hermes_line"; exit 0; }
  if declare -F before_mcp >/dev/null; then
    before_mcp >>"$LOG" 2>&1 || { fail 工具Bot调得到 "工具的准备工作（before_mcp）失败，见 $LOG 末尾：$(tail -c 200 "$LOG" | tr '\n' ' ')"; exit 0; }
  fi
  SMOKE_MCP_URL="$(docker exec "$gw" printenv WONTON_MCP_URL 2>>"$LOG")" ||
    { fail 工具Bot调得到 "gateway 容器里没有 WONTON_MCP_URL"; exit 0; }
  export SMOKE_MCP_URL
  mcp list >"$SMOKE_TOOLS" 2>"$work/mcp.err" ||
    { fail 工具Bot调得到 "MCP initialize/tools/list 失败：$(head -c 300 "$work/mcp.err" | tr '\n' ' ')"; exit 0; }
  n_mine="$(jq --arg s "$slug" '[.[] | select(.name | startswith($s + "__"))] | length' "$SMOKE_TOOLS")"
  say "MCP 通了，本插件前缀工具 $n_mine 个"
  if declare -F mcp_check >/dev/null; then
    if mcp_check >>"$LOG" 2>&1; then
      pass 工具Bot调得到 "tools/list 有本插件工具，只读调用返回符合预期"
    else
      fail 工具Bot调得到 "mcp_check 失败，见 $LOG 末尾：$(tail -c 200 "$LOG" | tr '\n' ' ')"
    fi
  elif [[ "$n_mine" -lt 1 ]]; then
    fail 工具Bot调得到 "tools/list 没有 ${slug}__ 前缀工具"
  elif [[ -z "$MCP_TOOL" ]]; then
    pass 工具Bot调得到 "tools/list 有本插件工具（探测没指定只读工具）"
  else
    tool="$MCP_TOOL"
    grep -q "__" <<<"$tool" || tool="${slug}__${tool}"
    ann="$(jq -r --arg t "$tool" '.[] | select(.name == $t) | .annotations.readOnlyHint // "missing"' "$SMOKE_TOOLS")"
    if [[ "$ann" != true ]]; then
      fail 工具Bot调得到 "$tool 不在 tools/list 或没标 readOnlyHint=true（$ann）"
    elif out="$(mcp call "$SMOKE_MCP_URL" "$tool" "$MCP_ARGS" 2>&1)"; then
      if declare -F mcp_assert >/dev/null && ! mcp_assert <<<"$out" >>"$LOG" 2>&1; then
        fail 工具Bot调得到 "$tool 的结果不符合预期：$(head -c 200 <<<"$out" | tr '\n' ' ')"
      else
        pass 工具Bot调得到 "tools/list 有本插件工具，真实调用只读工具 $tool 成功"
      fi
    else
      fail 工具Bot调得到 "调用只读工具 $tool 失败：$(head -c 300 <<<"$out" | tr '\n' ' ')"
    fi
  fi
fi
