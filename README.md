# 云吞官方 RSS 插件

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

在云吞（Wonton）App 底栏的“动态”页里看自己订阅的 RSS：粘贴订阅链接就能抓文章，点开读正文；单个订阅可以刷新或删除，
全部订阅一键刷新，抓不到的订阅如实标出原因。插件没有自己的账号，网页在核心网关的登录后面，只有你能打开。

本仓库同时是插件规范的一个真实例子：后端只用 Python 标准库（`server.py`），网页是 `web/index.html` 一个单文件，
数据存 `${WONTON_APP_DATA}`，底栏页面声明在清单的 `tabs` 里。
