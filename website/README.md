# FoldGit 落地页

页面源文件保存在此目录，构建后生成可部署的纯静态网站。共享品牌原图从仓库的相对位置读取，图标、favicon 与低分辨率截图在构建时生成。

```text
index.html        页面结构与中文文案
manual.html       使用手册
templates/changelog.html  更新日志页面模板，源码不保存版本条目
i18n.js           英文文案
styles.css        设计变量、液态玻璃样式、亮暗色与动效
main.js           语言与外观切换、截图同步、滚动动效、Fold 演示
assets/           赞助二维码、高分辨率原始截图、亮暗壁纸与 README 展示图
```

## 构建与本地预览

```sh
python3 -m pip install -r Scripts/build-requirements.txt
python3 Scripts/build-website.py
python3 -m http.server 8765 --directory dist/website
```

然后打开 <http://127.0.0.1:8765/>。

构建命令在仓库根目录执行。脚本从 `Shared/Resources/Branding/Images` 读取与 Windows、README 共用的无损 WebP，生成 `dist/website/assets` 下的图标与 favicon。截图只保存 `@2x.webp` 原图，构建时生成对应的 1 倍版本。发布后的资源 URL 保持现有路径。构建同时检查更新日志，并复制页面、样式、脚本和实际使用的静态资源。

## Cloudflare Pages 配置

在连接 Git 仓库的 Pages 项目中设置以下内容，生产与预览环境使用相同配置。

| 设置 | 值 |
|---|---|
| 框架预设 | None |
| 根目录 | 仓库根目录，留空 |
| 构建命令 | `python3 -m pip install -r Scripts/build-requirements.txt && python3 Scripts/build-website.py` |
| 构建输出目录 | `dist/website` |
| 环境变量 | `PYTHON_VERSION=3.12` |

构建监控路径可以保留默认设置。如果已配置自定义包含路径，需要覆盖以下构建输入，让共享资源与版本配置修改能够触发网站构建。

```text
website/**
Shared/Resources/Branding/Images/**
Shared/Resources/Updates/**
Scripts/**
Platforms/macOS/Configuration/Base.xcconfig
Platforms/Windows/src/FoldGit.App/Package.appxmanifest
Platforms/Windows/src/FoldGit.App/MainWindow.Dialogs.cs
```

GitHub 的 `Website build` 工作流会独立验证构建结果和页面资源引用。

配置项对应 [Cloudflare Pages 构建配置](https://developers.cloudflare.com/pages/configuration/build-configuration/) 和 [Python 版本设置](https://developers.cloudflare.com/pages/configuration/build-image/)。

- 语言默认跟随浏览器：`zh-*` 显示中文，其他语言一律显示英文。
- 亮暗色默认跟随浏览器，图标、截图和网站图标随之切换。
- 导航栏按钮可手动切换并保存在当前浏览器中；切回与浏览器一致的选项时，会清除保存的选择，重新跟随浏览器。

修改 `styles.css`、`main.js` 或 `i18n.js` 后，把所有页面中引用它们的 `?v=` 版本号加一，避免浏览器使用旧缓存。

## 手册与首页文案

`manual.html` 的中英文内容使用 `show-zh` 和 `show-en` 成对维护。章节按仓库整理、目录树与差异、暂存与提交、历史、目录视角与完整文件、同步、工作树、Git 命令日志和操作失败排查等日常流程编排；操作名称应对照对应语言的实际界面。日志与错误排查说明以 macOS 实现为准，需覆盖读取命令筛选、按当前筛选结果复制或导出、会话保留限制，以及自动获取和工作树警告的查看入口。

首页的审查与暂存说明链接到 `manual.html#review`。首页「看代码」区块（`#review`）介绍目录视角与工作树状态，分别链接到 `manual.html#browse` 和 `manual.html#worktrees`；该区块使用签名 macOS 构建中采集的 Markdown 阅读区截图，按中英文和亮暗外观切换。侧边栏示意仍由 HTML 和 CSS 绘制，角标含义需与应用实际界面一致。工作树章节说明状态角标、悬停详情、管理与清理流程，功能变化时同步更新。手册复用 `assets/screenshots/main-*` 的真实截图，通过网站的 `data-lang` 和 `data-scheme` 切换语言与亮暗色，点击可查看原图。更新章节时同步维护目录锚点、快捷键和两种语言，避免把目录展开与差异展开混为同一操作。

## 展示图壁纸

首页和手册通过 `styles.css` 的 `.screenshot-wallpaper` 为真实应用截图添加壁纸、四周留白和窗口阴影。`assets/wallpapers/landscape-light.webp` 用于亮色，`landscape-dark.webp` 用于暗色，随网站外观一起切换。原始截图仍保存在 `assets/screenshots/`，手册点击后打开原图。

首页展示区先呈现完整壁纸，滚动进入固定展示区后，软件窗口从下方以 3D 倾角逐渐出现，随后展开并落稳。展示区按视口高度适配，窗口展开后保留一段滚动距离供阅读。启用系统的减少动态效果设置时，两张截图纵向排列。手册和 README 保持静态构图。

首页主图随滚动从「提交视角」过渡到「目录视角」，向上滚动时按原路切回。中英文 README 并列展示同一组窗口截图，两处均使用 `assets/screenshots/commit-*` 和 `assets/screenshots/directory-*`，保留语言和深浅色版本。目录视角截图应同时显示选中的 Markdown 文档、文件树和 Mermaid 渲染结果。

旧版展示图使用 `assets/showcases/` 的静态展示图，通过 `<picture>` 跟随阅读器亮暗色。展示图使用网站共用的 CSS，不重绘应用界面。画布为 2176 × 1244，窗口为 1920 × 988，四周各留 128 像素；按 2 倍分辨率导出 WebP。

Open Graph 与 Twitter 分享卡片使用 `assets/og.png`，尺寸 1200 × 630。左侧展示图标、名称和三项核心功能，右侧使用最新版提交视角的代码差异与目录视角的 Markdown 图表截图。三个页面的 `og:image` 必须使用 `https://foldgit.com/` 开头的绝对地址；替换卡片后可更改文件名或追加查询参数，促使各平台刷新缓存。

替换原始截图后，同步更新中英文、亮暗色版本以及分享卡片。分享卡片的制作脚本保存在本地。网站构建会从共享原图生成图标、favicon 和 1 倍截图。

## 更新日志

顶部导航和使用手册页脚提供更新日志入口。日志按版本倒序排列，跟随网站的中英文、亮暗色设置。

更新日志唯一数据源位于仓库根目录的 `Shared/Resources/Updates/changelog.json`，网页、GitHub Release 与 Sparkle 共用。每次升级版本，只在该文件顶部添加版本号、发布日期及对应的 `zh`、`en` 短句列表。条目只描述该版本的实际变化，不重复安装步骤或旧版本文案。然后在仓库根目录运行：

```sh
python3 Scripts/changelog.py --check  # 检查版本、双语日志与页面模板
python3 Scripts/build-website.py  # 构建包含更新日志的完整网站
python3 Scripts/changelog.py --release 0.2.0  # 输出指定版本的双语 Release 文案
```

页面框架和样式在 `templates/changelog.html`、`styles.css` 中维护。网站构建时从共享日志生成 `dist/website/changelog.html`，浏览时无需额外请求数据。源码不保存生成页面或重复的日志数据。发版工作流从同一份数据读取对应版本的中文与英文，缺少条目、语言或签名校验失败时停止发布。

## Homebrew 安装入口

首屏提供 `brew install --cask dufu1991/tap/foldgit` 命令，并链接到使用手册的安装部分。中英文文案分别维护在 `index.html` 和 `i18n.js`，手册同时说明更新命令与首次打开步骤。

安装包仍由 FoldGit 的 GitHub Releases 分发，`dufu1991/homebrew-tap` 每 6 小时自动检查最新稳定版，校验安装包后同步版本号与 SHA-256 校验值。同步使用 tap 自身的 `GITHUB_TOKEN`，无须配置个人令牌；GitHub 调度繁忙时可能延迟。发布流程与手动重试入口见项目根目录的中英文 README。

## 赞助信息

落地页与仓库的中英文 README 共用 `assets/sponsor/` 中的二维码原图。赞助链接和二维码来自 <https://any-tdf.dev/> 右上角的「支持」入口：

- Buy Me a Coffee：<https://www.buymeacoffee.com/dufu1991>。
- PayPal：<https://paypal.me/dufu1991>。
- 微信赞赏：`assets/sponsor/wechat.png`，原图为 <https://any-tdf.dev/assets/fund/wp_code.png>。
- 支付宝收款：`assets/sponsor/alipay.png`，原图为 <https://any-tdf.dev/assets/fund/ap_code.png>。

## 重新生成截图

截图取自当前代码的 macOS 签名构建。侧栏以两个分组展示四个示例仓库，并展开 `tide-api` 的关联工作树。主窗口选中名为 FoldGit 的演示仓库，仓库包含用于审查和预览的 Swift 与 Markdown 示例。

1. 用 `defaults export com.dufu.foldgit <备份.plist>` 备份偏好。关闭旧实例，使用本机 Apple Development 证书在原有 Debug 路径构建并启动应用。
2. 保持窗口尺寸为 1920 × 988 点，并保留「提交视角」和「目录视角」两个标签页。提交视角选中包含 `Badge.swift` 的历史提交并展开并排差异。目录视角选中对应语言的发布流程文档，确认 Mermaid 流程图、检查清单、表格和代码块已渲染。手册的工作树截图另外展示暂存区、未跟踪文件和 `GlassCard.swift` 差异。
3. 分别采集中文、英文与亮暗色组合。语言切换后重启应用，核对运行路径和构建版本，并确认截图使用原生标题栏。完整窗口以 3840 × 1976 像素导出为 `assets/screenshots/{commit,directory,main}-<zh|en>-<light|dark>@2x.webp`，构建时生成 1920 × 988 像素的版本。Markdown 特写从预览区裁切，导出为 `markdown-<zh|en>-<light|dark>.webp`。
4. 导出分享卡片并更新截图和卡片的缓存版本参数。退出应用，清除截图会话的临时偏好，用 `defaults import com.dufu.foldgit <备份.plist>` 恢复并核对原有设置，再启动原路径的最新构建。

截图原图和演示仓库保存在本地。应用界面只做裁切、缩放和压缩，成品存入 `assets/screenshots/`。
