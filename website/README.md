# FoldGit 落地页

纯静态单页，无需构建，可直接部署到 GitHub Pages 等静态托管。

```text
index.html        页面结构与中文文案
i18n.js           英文文案
styles.css        设计变量、液态玻璃样式、亮暗色与动效
main.js           语言与外观切换、截图切换、滚动动效、Fold 演示
assets/           图标与主界面截图（中英 × 亮暗共四套，含 1x 与 2x）
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

修改 `styles.css`、`main.js` 或 `i18n.js` 后，把两个页面中引用它们的 `?v=` 版本号加一，避免浏览器使用旧缓存。

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
