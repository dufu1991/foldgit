# FoldGit 品牌资源

品牌图形由 macOS 与后续其他平台共用，源文件只有一份。

- `AppIcon.icon` 是权威分层图标，内部 `Assets` 存放 7 个通用 SVG 图层，按玻璃文件夹、仓库卡片、连续玻璃表面、底板与网格分为 4 组。
- `Images/FoldGit.webp` 与 `Images/FoldGit-dark.webp` 是 1024 × 1024 的无损 WebP，保留原图像素、ICC 色彩配置和 EXIF 元数据，供 Windows、网站及 README 共用。
- macOS 工程直接编译此处的 `AppIcon.icon`，不在平台目录保留副本。

当前方案采用青蓝渐变底板、粉色与紫色及暖橙色卡片，前方为半透明玻璃文件夹。底板参照 Xcode 的大网格比例，使用 4 × 4 网格，间距为 256 点，线宽为 4.2 点，白色线条不透明度为 52%。网格上方是一整块连续的透明玻璃表面，由 Icon Composer 原生折射底下的线条，形成边缘弯曲和厚度感。三张卡片上的 Git 图形均为真实矢量镂空，并启用原生边缘高光。亮色与暗色分别设置底板、玻璃和阴影，透明与着色外观由 Icon Composer 的原生渲染器生成。

画布为 1024 × 1024，仅启用 macOS 平台。圆角遮罩和材质效果由系统处理，源素材不烘焙圆角或投影。

仓库保存分层图标与共享无损 WebP。分层图标制作、预览与导出工具保存在本地。Windows 的各尺寸 PNG 与 ICO、网站的图标和 favicon 均在构建时从共享原图生成，生成脚本和固定依赖随源码维护。

在 Icon Composer 中编辑源文件后，导出并同步更新以下成品：

- `Images/FoldGit.webp` 与 `Images/FoldGit-dark.webp`，供 README 与其他平台使用。
- Windows 构建会通过 `Scripts/generate-windows-icons.py` 自动更新各尺寸 PNG 与 `FoldGit.ico`，输出到构建目录。
- 网站构建通过 `Scripts/build-website.py` 生成 `dist/website/assets/icon.webp` 与暗色版本，尺寸 512 × 512，同时生成 180 × 180 的 favicon。

导出时使用当前选中 Xcode 自带的 Icon Composer，并检查亮色和暗色外观。将导出的 PNG 转换为无损 WebP 时，使用 Pillow 的 `lossless=True`、`exact=True` 和 `method=6`，同时传递原图的 `icc_profile` 与 `exif`。转换后核对 RGBA 像素一致。修改矢量轮廓时保留 `icon.json` 中的系统材质、平台和外观配置。

官方设计依据：[Apple App Icons 指南](https://developer.apple.com/design/human-interface-guidelines/app-icons)。
