# 发布流程

## 应用身份

macOS 应用名为 `FoldGit`，Bundle ID 为 `com.dufu.foldgit`；Windows 包身份为 `dufu.FoldGit`，Publisher 为 `CN=dufu`。签名配置位于 `Platforms/macOS/Configuration`。

## 版本号

版本号分布在三处且必须一致：`Platforms/macOS/Configuration/Base.xcconfig` 中的 `MARKETING_VERSION`、`Platforms/Windows/src/FoldGit.App/Package.appxmanifest`，以及 Windows「关于」页的文字。用 `Scripts/version.py` 统一修改：

```sh
python3 Scripts/version.py            # 显示版本号，并检查各平台是否一致
python3 Scripts/version.py set 0.2.0  # 设置新版本，并递增 macOS 构建号
```

## 发布工作流

提交并推送到 `main` 后，[发布工作流](../.github/workflows/release.yml)会为 `v0.2.0` 仅发布三个安装包：macOS Apple Silicon 的 DMG，以及 Windows x64 和 ARM64 各一个 Inno Setup EXE。SHA-256 校验值写入发布说明。附件使用固定文件名，官网下载链接会自动指向最新版本。推送已有标签的版本不会重复发布；如需替换已发布版本的安装包，可手动运行工作流并勾选 *rebuild*。

未配置 Apple 签名 Secrets 时，发布说明会附上清除隔离标记的命令。

## Homebrew

发版 CI 会在 GitHub Release 发布成功后，自动调用 [Publish Homebrew cask 工作流](../.github/workflows/homebrew.yml)。它会下载已发布的 macOS DMG，核对 GitHub 提供的文件大小与 SHA-256 摘要，再将更新后的 `Casks/foldgit.rb` 直接提交到 [tap 仓库](https://github.com/dufu1991/homebrew-tap)。Homebrew 发布失败会让发版 CI 失败；重新构建同一版本时，也会刷新校验值。

自动发布依赖 FoldGit 仓库的 Actions 密钥 `HOMEBREW_TAP_TOKEN`（**Settings → Secrets and variables → Actions**）。使用仅授权 `dufu1991/homebrew-tap` 且具有 **Contents 读写权限**的细粒度令牌，缺失时 CI 会明确报错。失败后可手动运行 **Publish Homebrew cask** 重试，无需重新打包应用。tap 每小时运行的 **Sync FoldGit** 仍保留为补偿机制，使用 tap 自身的 `GITHUB_TOKEN`。

## 签名 Secrets

签名所需的 Secrets 均为可选：

| Secrets | 未配置时 |
|---|---|
| `APPLE_TEAM_ID`、`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`KEYCHAIN_PASSWORD`、`AC_USERNAME`、`AC_PASSWORD` | macOS 使用 ad hoc 签名，不经公证；用户首次打开前需清除隔离标记。 |
| `WINDOWS_CERTIFICATE_BASE64`、`WINDOWS_CERTIFICATE_PASSWORD`（可信代码签名 PFX） | EXE 安装程序不签名，但已包含所需运行时，无需用户另外下载证书。 |
