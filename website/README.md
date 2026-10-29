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
assets/           图标、赞助二维码与主界面截图（中英 × 亮暗共四套，含 1x 与 2x）
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

## 更新日志

首页与使用手册的页脚提供更新日志入口。日志按版本倒序排列，跟随网站的中英文、亮暗色设置。

每次升级版本，在 `changelog.json` 顶部添加版本号、发布日期及对应的 `zh`、`en` 短句列表。条目只描述该版本的实际变化，不重复安装步骤或旧版本文案。然后在仓库根目录运行：

```sh
python3 Scripts/changelog.py --write  # 同步静态网页
python3 Scripts/changelog.py --check  # 检查版本、双语与网页是否同步
python3 Scripts/changelog.py --release 0.1.1  # 输出指定版本的双语 Release 文案
```

网页条目由脚本更新，页面框架和样式仍在 `changelog.html`、`styles.css` 中维护。生成后的页面随源码提交，部署时无需脚本或额外请求数据。发版工作流从同一份数据读取对应版本的中文与英文，缺少条目或页面未同步时停止发布。

## Homebrew 安装入口

首屏提供 `brew install --cask dufu1991/tap/foldgit` 命令，并链接到使用手册的安装部分。中英文文案分别维护在 `index.html` 和 `i18n.js`，手册同时说明更新命令与首次打开步骤。

安装包仍由 FoldGit 的 GitHub Releases 分发，`dufu1991/homebrew-tap` 自动同步最新稳定版的版本号与 SHA-256 校验值。发布流程和发版 CI 所需的跨仓库令牌见项目根目录的中英文 README。

## 赞助信息

落地页与仓库的中英文 README 共用 `assets/sponsor/` 中的二维码原图。赞助链接和二维码来自 <https://any-tdf.dev/> 右上角的「支持」入口：

- Buy Me a Coffee：<https://www.buymeacoffee.com/dufu1991>。
- PayPal：<https://paypal.me/dufu1991>。
- 微信赞赏：`assets/sponsor/wechat.png`，原图为 <https://any-tdf.dev/assets/fund/wp_code.png>。
- 支付宝收款：`assets/sponsor/alipay.png`，原图为 <https://any-tdf.dev/assets/fund/ap_code.png>。

## 重新生成截图

截图必须使用虚构的演示仓库，不得出现本机真实仓库。

1. 生成演示仓库：

   ```sh
   website/scripts/make-demo-repos.sh <输出目录>
   ```

   脚本会创建 `aurora-ui`、`tide-api`、`pebble-notes` 和 `harbor-docs` 四个仓库，作者均为虚构人物，并带有分支、合并、标签、Stash、工作树以及未提交的修改。

2. 备份当前偏好：`defaults export com.dufu.foldgit <备份.plist>`。
3. 关闭所有 FoldGit 实例，把 `folder` 偏好改为只包含演示仓库（`aurora-ui`、`tide-api` 和 `pebble-notes` 放入名为 Studio 的分组），再启动最新构建，选中 `aurora-ui`。
4. 将窗口调整为 1440 × 900，分别以中文和英文、亮色和暗色截取主窗口（`screencapture -o -l <窗口 ID>`）。
5. 用 `cwebp` 转换为 `assets/screenshots/main-<zh|en>-<light|dark>.webp`（1440 宽）和同名 `@2x.webp`（2880 宽）。
6. 退出应用，执行 `defaults import com.dufu.foldgit <备份.plist>` 恢复偏好。
