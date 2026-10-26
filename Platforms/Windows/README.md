# Windows 客户端接入边界

此目录用于后续 Windows 应用、窗口、设置、系统集成、安装器和签名配置。目前尚未实现 Windows 图形客户端。

可复用的代码位于根目录的 `Shared`，并通过根目录 `Package.swift` 暴露 `FoldGitCore`。不要复制 macOS 目录中的 SwiftUI 或 AppKit 代码来构建 Windows 界面。

## 已有共享能力

- Git 命令构建、异步执行、超时、取消和按仓库排队。
- 提交、引用、补丁、文件统计和状态解析。
- 工作区分组、仓库发现、排序和提交图布局。
- 搜索条件、远程跟踪关系和重复 Fetch 请求合并。
- 临时仓库测试工具与独立核心测试。

共享进程执行直接启动 Git，并通过环境变量控制后台认证，不依赖 Unix 的 `env` 命令。Git 必须安装并能通过 `PATH` 找到。

## 后续需要实现

- Windows 窗口、导航、差异文本渲染和快捷键。
- Windows 凭据、外部编辑器与终端发现、登录启动和设置持久化。
- Windows 文件系统路径策略、打包、签名和更新流程。
- AI 能力适配。Apple Foundation Models 保留在 macOS 客户端中。

Swift 客户端可直接引用共享包。其他语言的客户端需要额外设计桥接接口，共享包当前没有承诺 C ABI。

安装 Swift 后，在仓库根目录运行 `swift test`。CI 已配置 Windows 共享核心测试；本地 macOS 验证不能替代 Windows CI 的实际结果。

应用图标复用 `Shared/Resources/Branding/Images` 的通用 PNG，矢量图层位于同目录的 `AppIcon.icon/Assets`。不要另行维护一份品牌源图。

打包时应包含 `Shared/Resources/Licenses/LICENSE.txt`。

Swift 官方安装说明：<https://www.swift.org/install/windows/>。
