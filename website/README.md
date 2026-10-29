# FoldGit 落地页

纯静态网站，无需构建，可直接部署到 GitHub Pages 等静态托管。

```text
index.html        页面结构与中文文案
manual.html       使用手册
changelog.json    各版本的中英文更新文案，网页与 Release 共用
changelog.html    更新日志页面，条目由脚本生成
i18n.js           英文文案
styles.css        设计变量、液态玻璃样式、亮暗色与动效
main.js           语言与外观切换、截图切换、滚动动效、Fold 演示
assets/           图标、赞助二维码与两种场景的截图（中英 × 亮暗，含 1x 与 2x）
scripts/          截图用演示仓库生成脚本
```

## 本地预览

```sh
python3 -m http.server 8765 --directory website
```

然后打开 <http://127.0.0.1:8765/>。

- 语言默认跟随浏览器：`zh-*` 显示中文，其他语言一律显示英文。
- 亮暗色默认跟随浏览器，图标、截图和网站图标随之切换。
- 导航栏按钮可手动切换并保存在当前浏览器中；切回与浏览器一致的选项时，会清除保存的选择，重新跟随浏览器。

修改 `styles.css`、`main.js` 或 `i18n.js` 后，把所有页面中引用它们的 `?v=` 版本号加一，避免浏览器使用旧缓存。

## 手册与首页文案

`manual.html` 的中英文内容使用 `show-zh` 和 `show-en` 成对维护。章节按仓库整理、目录树与差异、暂存与提交、历史、同步和工作树等日常流程编排；操作名称应对照对应语言的实际界面。

首页的审查与暂存说明链接到 `manual.html#review`。手册复用 `assets/screenshots/main-*` 的真实截图，通过网站的 `data-lang` 和 `data-scheme` 切换语言与亮暗色，点击可查看原图。更新章节时同步维护目录锚点、快捷键和两种语言，避免把目录展开与差异展开混为同一操作。

## 更新日志

首页与使用手册的页脚提供更新日志入口。日志按版本倒序排列，跟随网站的中英文、亮暗色设置。

每次升级版本，在 `changelog.json` 顶部添加版本号、发布日期及对应的 `zh`、`en` 短句列表。条目只描述该版本的实际变化，不重复安装步骤或旧版本文案。然后在仓库根目录运行：

```sh
python3 Scripts/changelog.py --write  # 同步静态网页
python3 Scripts/changelog.py --check  # 检查版本、双语与网页是否同步
python3 Scripts/changelog.py --release 0.2.0  # 输出指定版本的双语 Release 文案
```

网页条目由脚本更新，页面框架和样式仍在 `changelog.html`、`styles.css` 中维护。生成后的页面随源码提交，部署时无需脚本或额外请求数据。发版工作流从同一份数据读取对应版本的中文与英文，缺少条目或页面未同步时停止发布。

## Homebrew 安装入口

首屏提供 `brew install --cask dufu1991/tap/foldgit` 命令，并链接到使用手册的安装部分。中英文文案分别维护在 `index.html` 和 `i18n.js`，手册同时说明更新命令与首次打开步骤。

安装包仍由 FoldGit 的 GitHub Releases 分发，`dufu1991/homebrew-tap` 每 15 分钟自动检查最新稳定版，校验安装包后同步版本号与 SHA-256 校验值。同步使用 tap 自身的 `GITHUB_TOKEN`，无须配置个人令牌；GitHub 调度繁忙时可能延迟。发布流程与手动重试入口见项目根目录的中英文 README。

## 赞助信息

落地页与仓库的中英文 README 共用 `assets/sponsor/` 中的二维码原图。赞助链接和二维码来自 <https://any-tdf.dev/> 右上角的「支持」入口：

- Buy Me a Coffee：<https://www.buymeacoffee.com/dufu1991>。
- PayPal：<https://paypal.me/dufu1991>。
- 微信赞赏：`assets/sponsor/wechat.png`，原图为 <https://any-tdf.dev/assets/fund/wp_code.png>。
- 支付宝收款：`assets/sponsor/alipay.png`，原图为 <https://any-tdf.dev/assets/fund/ap_code.png>。

## 重新生成截图

截图取自最新成功构建的真实 macOS 界面，不重绘控件或修改截图文案。演示项目使用虚构数据；FoldGit 场景使用本仓库的临时副本，保留真实历史与当前 macOS 代码改动，避免截图素材自身的变更出现在文件列表里。

1. 生成演示仓库：

   ```sh
   website/scripts/make-demo-repos.sh <全新的输出目录>
   ```

   脚本创建 `aurora-ui`、`tide-api`、`pebble-notes` 和 `harbor-docs`，包含分支、合并、标签、贮藏、工作树与未提交改动。`aurora-ui` 另有已暂存的主题与测试，以及未暂存的组件改动。输出目录已存在时会退出，避免覆盖文件。

2. 用 `defaults export com.dufu.foldgit <备份.plist>` 备份偏好。关闭所有 FoldGit 实例，使用 `Platforms/macOS/Configuration/LocalSigning.xcconfig` 的固定 Apple Development 签名，在原有 Debug 应用路径构建当前代码。不得复制应用或修改 Bundle ID。
3. 临时设置演示仓库列表：`aurora-ui`、`tide-api` 和 `pebble-notes` 放入 Studio 分组，将 `pebble-notes` 标为不活跃；FoldGit 临时副本与 `harbor-docs` 放入 Open Source 分组。
4. 使用 1920 × 988 的窗口，历史列宽 320，确保英文底部选项完整显示在一行。保留目录树、暂存区与展开的 `Badge.swift` 并排差异，折叠暂存区的 Tests 目录。提交框只填写演示文案，不执行提交。
5. FoldGit 场景切换到列表与单栏差异，展开 `StageFileDiffView.swift`，滚动到包含增删行的代码片段。不要修改或暂存真实工作目录的文件。
6. 分别切换中文、英文与亮暗色，捕获主窗口。语言切换后重启同一个应用；每次都确认运行路径和构建版本。移开鼠标，避免截图包含悬浮提示。若使用 Computer Use 布置界面，必须先停止其窗口控制服务，再用系统截图工具捕获，逐图确认左上角是真实的红黄绿按钮，不含紫色共享指示器。
7. 使用 `cwebp -q 90 -m 6` 导出 `assets/screenshots/<main|foldgit>-<zh|en>-<light|dark>.webp`（1920 × 988）和同名 `@2x.webp`（3840 × 1976）。只缩放与压缩，不修饰实际界面。
8. 同步 `Platforms/macOS/Screenshots/Screenshot2-1.png` 与 `Screenshot2-2.png`，分别保留中文亮暗色主图原图。README 引用同一组 WebP 素材，网站两种场景均跟随语言和外观切换。
9. 退出应用，执行 `defaults import com.dufu.foldgit <备份.plist>`。该命令会保留新增键，需删除仅由截图会话新增的偏好键，再逐项核对恢复结果。重新打开原路径的最新构建，恢复原仓库列表。

当前截图基于 2026 年 10 月 29 日的工作目录，包含目录树审查、文件暂存动画，以及无背景的打开文件箭头。落地页截图路径带缓存版本参数；替换同名图片时同步更新 `main.js` 和 Open Graph 图片的版本参数。
