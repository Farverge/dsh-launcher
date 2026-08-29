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

迷你对话框功能依赖随主应用分发的后端插件，源码在本仓库 `plugin/dsh-mini-dialog/`：

1. 拷贝整包到 `~/.dsh/profiles/node_modules/dsh-mini-dialog/`
2. 在 `~/.dsh/profiles/web/cordis.patch.yml` 的 insert 列表追加一行：

```yaml
- insert:
    - id: mini-dialog
      name: 'dsh-mini-dialog'
```

3. 重启 DSH 后端生效

插件冒烟测试（不启动后端、不访问网络）：

```bash
cd plugin/dsh-mini-dialog && node test/smoke.mjs
```

## 5. 发版约定

- 版本源：本仓库的 Release tag（`vX.Y.Z`），同时是主应用「检查 Launcher 更新」按钮的比对源
- 资产：`DSH-Launcher-vX.Y.Z.zip`（`~/Library/Application Support` 内构建出的 `.app` 压缩）+ sha256
- 主应用与 Launcher 版本节奏保持同步，套件内版本号一致
