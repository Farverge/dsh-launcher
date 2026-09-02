# 构建

面向维护者：编译、部署、回滚与插件装配。

> **定位声明**：社区项目，非 DeepSeek 官方出品。完整免责声明见仓库 [README](../../README.md#免责声明)。

---

## 1. 环境要求

- macOS 13+、Apple Silicon
- Xcode Command Line Tools（`xcode-select --install`；脚本内置工具链 vfsoverlay 修复，半更新状态的 CLT 也能编）

## 2. 一键构建与部署

```bash
./build.sh
```

行为：编译（swiftc release）→ 组装 `.app` → **自动备份运行中的旧版**（`DSH Launcher.app.bak-时间戳`）→ 安装到 `~/Library/Application Support/DSH Launcher.app` → ad-hoc 签名 → 自带 `manifest.json`（主应用设置页读取）。

仅构建不安装（开发期默认用法，绝不触碰运行中的应用）：

```bash
DSH_LAUNCHER_NO_INSTALL=1 ./build.sh
```

产物：`.build/DSHLauncher`。

## 3. 回滚

安装脚本每次部署都先整目录备份。验收出问题时：

```bash
rm -rf ~/Library/Application\ Support/"DSH Launcher.app"
mv ~/Library/Application\ Support/"DSH Launcher.app.bak-<时间戳>" \
   ~/Library/Application\ Support/"DSH Launcher.app"
```

仓库侧另有 git 历史与 `backup-pre-squash` 分支兜底。

## 4. 插件装配（dsh-mini-dialog）

**install.sh 已自动完成**（应用安装时随装部署）。手动兜底流程：

1. 拷贝整包到 `~/.dsh/profiles/node_modules/dsh-mini-dialog/`
2. 在 `~/.dsh/profiles/web/cordis.patch.yml` 的 insert 列表追加：

```yaml
    - id: mini-dialog
      name: 'dsh-mini-dialog'
```

3. 重启 DSH 后端生效

**前置依赖（mini-dialog 0.2.0 起）**：会话跳转通道由 **dsh-plugin-norm ≥ 1.0.1** 承载——家族漂移屏蔽层，唯一允许接触官方接口的插件，仓库 [iiiiiei/dsh-plugin-norm](https://github.com/iiiiiei/dsh-plugin-norm)（包名 / 服务名 / 路由前缀是 `dsh-plugin-norm`，仓库名无 s）。norm 不随 Launcher Release 分发，按其仓库说明单独部署（同一套 profiles 拷入 + cordis.patch.yml 条目 + 重启后端惯例）。

**装卸同步红线**：插件的装卸必须与 cordis.patch.yml 条目同步——patch 引用了 node_modules 里不存在的包时，**整个 profile 会拒绝启动**（install.sh 的幂等写入与 uninstall.sh 的两行剥离即为此设计；手动装卸务必成对维护）。

卸载侧的对称移除由 uninstall.sh 处理（含装配条目的两行剥离，已沙盒验证不误伤其他插件条目）。

插件冒烟测试（不启动后端、不访问网络；v0.2.0 起重写为 19 项，覆盖 focus 走 norm 稳定面、无自有 WS 残留等断言）：

```bash
cd plugin/dsh-mini-dialog && node test/smoke.mjs
```

## 5. 发版约定

- 版本源：本仓库的 Release tag（`vX.Y.Z`），同时是主应用「检查 Launcher 更新」按钮的比对源
- 资产：`DSH.Launcher.zip` **稳定名**（GitHub 把资产名空格归一为点号，`releases/latest/download/<名>` 跨版本可用），内含应用本体 + mini-dialog 插件载荷；附带 sha256
- 主应用与 Launcher 版本节奏保持同步，套件内版本号一致
