# FoldGit 品牌资源

品牌图形由 macOS 与后续其他平台共用，源文件只有一份。

- `AppIcon.icon` 是权威分层图标，内部 `Assets` 存放 5 个通用 SVG 图层，按玻璃文件夹、仓库卡片、网格底纹分为 3 组。
- `Images/FoldGit.png` 与 `Images/FoldGit-dark.png` 是 1024 × 1024 的通用 PNG，供 Windows、网站及其他不支持 `.icon` 的场景使用。
- macOS 工程直接编译此处的 `AppIcon.icon`，不在平台目录保留副本。

当前方案采用蓝色网格底板、粉色与紫色及暖橙色卡片，前方为半透明玻璃文件夹。三张卡片上的 Git 图形均为真实矢量镂空。亮色与暗色分别设置底板、玻璃和阴影，透明与着色外观由 Icon Composer 的原生渲染器生成。

画布为 1024 × 1024，仅启用 macOS 平台。圆角遮罩和材质效果由系统处理，源素材不烘焙圆角或投影。

在 Icon Composer 中编辑源文件后，从仓库根目录运行：

```sh
python3 Scripts/Branding/render-icons.py
```

如需重新生成矢量轮廓，运行：

```sh
swift Scripts/Branding/BuildArtwork.swift Shared/Resources/Branding/AppIcon.icon
```

重新生成轮廓不会覆盖 `icon.json` 中的系统材质、平台和外观注释。最终版预览与辅助脚本集中在 `output/FoldGit-icon-final`，旧探索图及备份已清理。

官方设计依据：[Apple App Icons 指南](https://developer.apple.com/design/human-interface-guidelines/app-icons)。
