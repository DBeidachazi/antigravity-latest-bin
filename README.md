# antigravity-latest-bin

Google Antigravity 2.0 官方预编译二进制的 Arch Linux AUR 打包仓库（`antigravity-latest-bin`），通过 GitHub Actions 自动追踪官方下载页与更新接口并同步推送到 AUR。

## 安装

使用任意 AUR Helper 安装（例如 `paru` 或 `yay`）：

```bash
paru -S antigravity-latest-bin
```

该包提供 `antigravity`（`provides=('antigravity')`），并与 `antigravity`、`antigravity-bin` 互斥。

## 上游发布源

- 官方下载页：`https://antigravity.google/download/`
- 官方更新 API：`https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/releases`
- 二进制分发：`https://storage.googleapis.com/antigravity-public/antigravity-hub/<version>-<build_id>/linux-{x64,arm}/Antigravity.tar.gz`

## 自动化工作流

- **自动更新（`.github/workflows/update-aur.yml`）**
  - 每 6 小时定时运行（`0 */6 * * *`），也支持在 GitHub Actions 页面通过 `workflow_dispatch` 手动触发（可选勾选 `force_recheck` 强制重新下载校验）。
  - 发现新版本号或同版本新 `build_id` 时，会自动下载验证 `x86_64` 与 `aarch64` 压缩包，计算 `b2sums`，同步更新 `PKGBUILD` 和 `.SRCINFO`，然后推送到 AUR 并回写 GitHub 仓库。
- **手动提升 `pkgrel`（`.github/workflows/bump-patch.yml`）**
  - 通过 `workflow_dispatch` 手动将 `pkgrel` 加 1 并同步至 AUR 与 GitHub。
- **失败自动重试（`.github/workflows/retry-aur.yml`）**
  - 当上述工作流因网络波动等原因失败时，最多自动重试至第 3 次尝试。
