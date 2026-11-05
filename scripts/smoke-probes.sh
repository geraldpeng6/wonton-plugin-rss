# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：本插件没有账号体系（sso: none），页面只有核心网关的会话能打开，没有应用自己的“当前用户”接口可断言，
#       写 IDENTITY_NA=1 并在 SMOKE_NOTE 里说明。dweb / web_get 是带用户会话的请求助手。
# 工具：本插件没有 mcp，SMOKE_NOTE 里写不适用，冒烟会输出 N/A。
# 订阅抓取要出网，起冒烟前设 WONTON_DEV_EGRESS_PROXY（见 smoke.sh 开头）。

web_assert() { grep -q '<title>动态</title>'; }

IDENTITY_NA=1
SMOKE_NOTE="无应用内账号体系（sso: none），网页只经核心网关的会话打开；工具不适用（没有 mcp）。"
