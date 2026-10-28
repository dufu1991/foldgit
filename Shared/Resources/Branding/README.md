# FoldGit 品牌资源

品牌图形由 macOS 与后续其他平台共用，源文件只有一份。

- `AppIcon.icon` 是权威分层图标，内部 `Assets` 存放 7 个通用 SVG 图层，按玻璃文件夹、仓库卡片、连续玻璃表面、底板与网格分为 4 组。
- `Images/FoldGit.png` 与 `Images/FoldGit-dark.png` 是 1024 × 1024 的通用 PNG，供 Windows、网站及其他不支持 `.icon` 的场景使用。
- macOS 工程直接编译此处的 `AppIcon.icon`，不在平台目录保留副本。

当前方案采用青蓝渐变底板、粉色与紫色及暖橙色卡片，前方为半透明玻璃文件夹。底板参照 Xcode 的大网格比例，使用 4 × 4 网格，间距为 256 点，线宽为 4.2 点，白色线条不透明度为 52%。网格上方是一整块连续的透明玻璃表面，由 Icon Composer 原生折射底下的线条，形成边缘弯曲和厚度感。三张卡片上的 Git 图形均为真实矢量镂空，并启用原生边缘高光。亮色与暗色分别设置底板、玻璃和阴影，透明与着色外观由 Icon Composer 的原生渲染器生成。

画布为 1024 × 1024，仅启用 macOS 平台。圆角遮罩和材质效果由系统处理，源素材不烘焙圆角或投影。

在 Icon Composer 中编辑源文件后，从仓库根目录运行：

```sh
python3 Scripts/Branding/render-icons.py
```

导出脚本使用当前选中 Xcode 自带的 Icon Composer，默认导出第 27 代材质，避免独立安装的旧版工具忽略折射设置。如需核对 macOS 26 的兼容效果，使用 `--design-generation 26`，并通过 `--previews` 指定单独的预览目录。原生折射需要 macOS 27，旧系统保留玻璃高光和透明材质。

通用 PNG 更新后，同步重新生成各处派生图标，并一起提交：

```sh
python3 Scripts/Branding/generate-windows-icons.py
python3 Scripts/Branding/generate-website-icons.py
```

前者更新 `Platforms/Windows/src/FoldGit.App/Assets` 中的 MSIX 图标与 `FoldGit.ico`，后者更新落地页与手册使用的 `website/assets/icon(-dark).webp`（512 × 512）和 `favicon(-dark).png`（180 × 180）。两个脚本都需要 Pillow，网站脚本另需 `cwebp`。仓库 README 直接引用 `Images` 中的 PNG，无需额外处理。

如需重新生成矢量轮廓，运行：

```sh
swift Scripts/Branding/BuildArtwork.swift Shared/Resources/Branding/AppIcon.icon
```

重新生成轮廓不会覆盖 `icon.json` 中的系统材质、平台和外观注释。最终版预览与辅助脚本集中在 `output/FoldGit-icon-final`。折边与网格调整的对比预览及构建日志存放于 `output/FoldGit-icon-glass`。

官方设计依据：[Apple App Icons 指南](https://developer.apple.com/design/human-interface-guidelines/app-icons)。
