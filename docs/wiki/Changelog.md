# 版本历史

## 2026-09-01/02 · 插件家族换代与体检/配色大修（应用本体版本维持 v1.0.0）

### 配套插件 dsh-mini-dialog → v0.2.0（plugin/，随 Launcher 分发）

- client 脸退役：会话跳转的浏览器端执行（`ctx.sessions.open`）整体移交 dsh-plugins-norm；自有 WS 通道（`/api/mini/ws`）与 9 包 inject 声明全部移除，插件收敛为宿主单脸
- `/api/mini/focus` 改经 norm 稳定面广播；norm 缺席时返回 503 部署指引，不拖垮发送主链
- **部署前置：dsh-plugins-norm ≥ 1.0.1**，且装卸必须与 cordis.patch.yml 条目同步（patch 引用缺失包会拒启整个 profile）
- 冒烟测试重写为 19 项（focus 走 norm 稳定面、无自有 WS 残留等断言）

### 新家族插件 dsh-plugins-norm v1.0.1（[iiiiiei/dsh-plugin-norm](https://github.com/iiiiiei/dsh-plugin-norm)）

- 家族漂移屏蔽层：唯一允许接触官方接口的插件，对外提供稳定面——`GET /api/dsh-plugins-norm/caps`（部署体检锚点：宿主形状探测 + 客户端上报合并 + 降级清单）、`POST /api/dsh-plugins-norm/focus`（会话跳转广播，含 lastFocusResult 审计）、`/api/dsh-plugins-norm/ws` 被动事件通道
- client 侧 `window.__dshPluginsNorm` 微内核（on / caps / focusSession，会话跳转三级降级链）；全程零轮询零缓存

### 一键体检大修（七项 → 十一项）

- 对标新架构新增：后端通道认证形态感知（稳定通道 200 = 健康、alpha 认证链 401 应答 = 健康）、norm 协议层（caps 路由）、mini 对话框版本、profile 工作区装配（缺失 = GUI 白屏的 alpha.3+ 坑）
- npx 多副本建议纠正：`npm cache clean` 只清 `_cacache`、不清 `_npx` 副本——多副本无害，建议改为指向动作按钮
- 条件动作按钮（按结果出现、点按才执行）：[释放 npm 缓存]（真实执行 `npm cache clean --force` 并重测体量行）、[打开 npx 目录]（Finder）、[重新体检]；体检窗取消悬浮置顶（动作会把工作交接给 Finder/终端）

### 迷你框深浅色实时适配根治

- 旧实现跟随 `NSApp.effectiveAppearance`——accessory 应用后台时该值会过期，表现为面板固定深色；现从系统偏好直读 `AppleInterfaceStyle` 钉窗口外观，换肤监听系统分布式通知（事件驱动零轮询）

### 其他

- 个人仓库现名 `iiiiiei/dsh-launcher`（小写），文档内指向个人仓库的链接已统一

## 2026-08-31 · 更新机制升级说明（Launcher 代码无变更，版本维持 v1.0.0）

DSH Desktop v1.0.3 起，「检查 Launcher 更新」从提示+手动下载升级为全自动安装（下载校验 → mini-dialog 插件同步 → 换壳重启），本仓库的 Release zip 结构（`DSH Launcher.app` + `dsh-mini-dialog` 平级）即为自动更新的载荷格式。详见 [Update](Update.md)。

## v1.0.0（2026-08-29）

首个公开发布版本，与 DSH Desktop v1.0.0 套件同步。

### 菜单栏与状态

- 三态鲸鱼图标：健康=原样 / 过渡=「？」角标约 1Hz 闪烁 / 异常=「！」角标（模板单色合成，深浅色自适应）
- 自适应健康轮询：稳态 30s、状态突变后 60s 内 5s、菜单展开强制补测；不缓存任何状态
- 右键菜单：启动 DSH Desktop / 一键体检 / 退出
- 左键三态：应用不可见弹迷你框，可见激活主应用

### 迷你对话框（`⌘⇧D`）

- Gemini 式单行胶囊，底部居中唤起，可拖动，失 key 即收，Esc 兜底
- 左「+」工作区菜单（不使用项目 / 添加工作区——访达选择）
- 右模型 chip：全提供方模型清单（名称+描述），思考强度档位按路由惰性拉取
- 输入区自适应换行，胶囊向上生长至接近整屏，超出内部滚动；展开阈值单锚定单行宽度，无抖动带
- 发送链路：按需拉起后端 → 创建会话（工作区/模型/思考强度）→ 收起胶囊 → 唤起主应用 → 会话级跳转直达对话（WebSocket 广播 + 120 秒冷启动回放）

### 一键体检

- 终端风独立小窗（Menlo 13pt、可拉伸），七项只读检测逐行刷出：macOS / Node / 应用签名 / 端口身份 / 桥接接口 / npx 副本 / 缓存体量
- 附建议区与复制报告；不杀任何进程

### 配套插件（plugin/dsh-mini-dialog，随主应用分发）

- 一包两脸：宿主脸（session.new / session.send / focus / options / reasoning 路由 + ws 升级端点）+ WebView 脸（ctx.sessions.open 会话跳转）
- 思考强度按会话覆盖（agent/request 瀑布改写 reasoningEffort）
- pendingFocus 握手回放，解决主应用冷启动晚于发送的时序

### 主应用配套改动（随 DSH Desktop v1.0.x 分发）

- 窗口状态分布式广播（最小化/恢复/获焦/Cmd+H）
- `dshdesktop://` URL scheme 声明（方案甲休眠，零运行成本）
- 设置 → 菜单栏插件 → 检查 Launcher 更新（语义化版本比较，版本源 = 本仓库 Release）

### 安装与卸载脚本（v1.0.0 同日工程补充）

- `install.sh`：三段式一键安装（环境预检/下载安装/启动回馈，KEY=VALUE 摘要供 agent 解析），**随装部署 mini-dialog 插件**（profiles 拷入 + cordis.patch.yml 幂等写入）
- `uninstall.sh`：对称一键卸载（退进程、移应用、移插件与装配条目，`--keep-plugin` 可保留）
- Release 资产改稳定名 `DSH.Launcher.zip`，内含应用本体 + 插件载荷

### 质量与工程

- 两轮独立代码审查 + 一轮布局专项实测审查；P0×2 / P1×8 / P2×24 全部修复
- 插件冒烟测试 22 项；展开逻辑五态几何断言
- 构建脚本三层回滚：仅构建模式 / 安装前自动备份 / git 历史
