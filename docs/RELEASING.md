# 发布流程

## 应用身份

macOS 应用名为 `FoldGit`，Bundle ID 为 `com.dufu.foldgit`；Windows 包身份为 `dufu.FoldGit`，Publisher 为 `CN=dufu`。签名配置位于 `Platforms/macOS/Configuration`。

## 版本号

版本号分布在三处且必须一致：`Platforms/macOS/Configuration/Base.xcconfig` 中的 `MARKETING_VERSION`、`Platforms/Windows/src/FoldGit.App/Package.appxmanifest`，以及 Windows「关于」页的文字。用 `Scripts/version.py` 统一修改：

```sh
python3 Scripts/version.py            # 显示版本号，并检查各平台是否一致
python3 Scripts/version.py set 0.2.0  # 设置新版本，并递增 macOS 构建号
```

版本号变化时，Agent 必须按 [AGENTS.md](../AGENTS.md) 自动维护 `website/changelog.json`：以最近发布标签为基线，将用户可感知的实际变化整理为简洁、含义对应的中文与英文条目，并填写发布日期。然后生成落地页的更新日志页面，一并提交：

```sh
python3 Scripts/changelog.py --write
python3 Scripts/changelog.py --check
```

更新日志入口在网站页脚，文案跟随网站语言。发版 CI 在构建前检查当前版本条目、双语及静态页面是否齐全，发布时用 `python3 Scripts/changelog.py --release "$VERSION"` 读取该版本的两种文案，作为 GitHub Release 的更新内容。直接展示中英文条目，不添加“更新内容”或“What's new”标题，也不用 GitHub 自动生成的提交列表；SHA-256 附在条目之后。更正日志后推送也会触发版本检查，已发布版本仍须勾选 *rebuild* 才会替换 Release。

安装说明仅保留在首次发布中。后续 Release 不重复安装链接、安装步骤或签名提示，完整指南统一维护在官网使用手册；若安装方式、兼容性或升级要求有变化，在该版本的中英文条目中说明。

## 发布工作流

提交并推送到 `main` 后，[发布工作流](../.github/workflows/release.yml)会为 `v0.2.0` 仅发布三个安装包：macOS Apple Silicon 的 DMG，以及 Windows x64 和 ARM64 各一个 Inno Setup EXE。SHA-256 校验值写入发布说明。附件使用固定文件名，官网下载链接会自动指向最新版本。推送已有标签的版本不会重复发布；如需替换已发布版本的安装包，可手动运行工作流并勾选 *rebuild*。

未配置 Apple 签名 Secrets 时，首次打开应用的处理方式见官网使用手册，后续 Release 不重复说明。

## Homebrew

GitHub Release 发布成功后，[tap 仓库](https://github.com/dufu1991/homebrew-tap)的 [Sync FoldGit 工作流](https://github.com/dufu1991/homebrew-tap/actions/workflows/foldgit.yml)会自动同步 Homebrew。该任务每小时检查最新稳定 Release，下载 macOS DMG，核对 GitHub 提供的文件大小与 SHA-256 摘要，再提交更新后的 `Casks/foldgit.rb`。同一版本重新构建后，也会刷新校验值；版本和校验值未变时不会创建提交。

同步任务在 tap 仓库内使用 GitHub 自动提供的 `GITHUB_TOKEN`，仅需该仓库的 Contents 读写权限，无须在 FoldGit 配置个人令牌或跨仓库 Secret。应用发版与 Homebrew 同步各自记录运行结果，发布摘要提供同步任务入口。

同步由定时任务触发，并非即时更新；GitHub 调度繁忙时可能延迟。需要立即同步或重试时，在 tap 仓库的 **Actions → Sync FoldGit → Run workflow** 手动运行，无需重新打包应用或增加版本号。

## 签名 Secrets

签名所需的 Secrets 均为可选：

| Secrets | 未配置时 |
|---|---|
| `APPLE_TEAM_ID`、`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`KEYCHAIN_PASSWORD`、`AC_USERNAME`、`AC_PASSWORD` | macOS 使用 ad hoc 签名，不经公证；用户首次打开前需清除隔离标记。 |
| `WINDOWS_CERTIFICATE_BASE64`、`WINDOWS_CERTIFICATE_PASSWORD`（可信代码签名 PFX） | EXE 安装程序不签名，但已包含所需运行时，无需用户另外下载证书。 |
