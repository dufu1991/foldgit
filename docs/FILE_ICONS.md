# 文件类型图标

FoldGit 内置 Material Icon Theme 5.39.0 的文件图标和官方生成的匹配规则。图标以 SVG 文件存入 `Shared/Resources/FileIcons/MaterialFileIcons`，作为文件夹资源原样复制到应用包，由各平台的原生 SVG 控件按需绘制并缓存。应用运行和普通构建不需要访问网络，也不需要 Node.js 或 VS Code。

当前包含 576 种文件图标、47 个浅色主题变体、1,349 条后缀规则和 2,132 条文件名规则。SVG 源文件共 522,058 字节。浅色变体保存为 `<图标>.light.svg`，`MaterialFileIcons.json` 的 `lightIcons` 列出拥有浅色变体的图标，界面按当前外观选择文件，图标保留原始颜色和矢量信息。不使用 Asset Catalog，是因为它会为每个 SVG 额外生成两份位图，使应用包增加约 5 MB。

## 匹配方式

`FileIconTheme` 只负责图标，不依赖语法高亮的 `Language` 枚举。匹配忽略大小写，按以下顺序处理。

1. 包含父目录的文件名规则，从最长路径开始匹配，例如 `.github/FUNDING.yml`。
2. 完整文件名，例如 `Dockerfile`、`package.json`、`.gitignore` 和 `README.md`。
3. 从最长到最短的复合后缀，例如 `d.ts` 优先于 `ts`，`test.ts` 优先于 `ts`。
4. 普通后缀，例如 `swift`、`md`、`vue` 和 `png`。
5. Material Icon Theme 的默认文件图标。

文件匹配只读取路径，不依赖文件实际存在，因此支持删除文件和历史提交。重命名文件使用目标路径。导入时使用 `activeIconPack: 'none'`，避免在所有仓库中启用 Angular 专用的文件后缀规则。

## 更新资源

上游项目：https://github.com/material-extensions/vscode-material-icon-theme

生成脚本：`Scripts/vendor-material-icons.mjs`，需要 Node.js 18 或更新版本。固定版本和 SHA-512 完整性校验值位于脚本顶部。更新版本时同步修改这两个值，然后运行。

```sh
node Scripts/vendor-material-icons.mjs
```

也可以使用已经下载的官方 npm 压缩包，脚本仍会校验其完整性。

```sh
node Scripts/vendor-material-icons.mjs /absolute/path/material-icon-theme-5.39.0.tgz
```

脚本调用官方 `generateManifest`，保留文件名与后缀规则，只导入规则实际引用的文件图标及其浅色变体，不导入文件夹图标。匹配表生成到 `Shared/Resources/FileIcons/MaterialFileIcons.json`。脚本同时更新共享的 `Shared/Resources/Licenses/LICENSE.txt`，应用分发包会包含该 MIT 许可证。

更新后运行 macOS 工程中的 `FileIconThemeTests`，验证匹配优先级以及所有匹配结果对应的资源均可加载。
