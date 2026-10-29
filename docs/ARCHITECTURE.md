# FoldGit 平台架构

两端采用原生界面和各自的业务核心。macOS 通过根目录 Swift Package 引用 FoldGitCore，Windows 使用独立的 C# FoldGit.Core。资源、行为样例和功能规范在 Shared 中共用，不增加跨语言 ABI。

## 目录与职责

```text
Shared/
  Sources/FoldGitCore/
    Git/                  命令、执行、解析、领域模型和仓库快照
    Workspace/            项目分组、仓库发现和规范化身份
    History/              提交图布局算法
    Synchronization/      可复用的同步策略数据
    Utilities/            排序、集合和展示展开状态数据
  Resources/Branding/      共享图标源文件、矢量图层与通用图片
  Resources/Licenses/      共享第三方许可证
  Testing/                临时 Git 仓库测试工具
  Tests/FoldGitCoreTests/  独立核心测试
Platforms/
  macOS/
    Sources/
      App/                生命周期、窗口、菜单和环境值
      Workspace/          SwiftUI 工作区与 macOS 仓库过滤适配
      Features/           历史、提交、差异、比较、引用和设置界面
      State/              SwiftUI 绑定使用的窗口与仓库状态
      Presentation/       日期、文案、SF Symbols 与本地化格式化
      Components/         macOS 客户端内部复用的视图组件
      Platform/           AppKit、外部应用、偏好、后台任务
    Resources/            平台资源目录与界面本地化
    Configuration/        签名、Bundle ID 和导出配置
    Tests/                原生渲染、设置与系统集成回归
    Screenshots/          macOS 应用截图
    FoldGit.xcodeproj/     Xcode 工程
    project.yml           macOS 工程生成入口
  Windows/                WinUI 3、C# 核心、Windows 适配与 MSIX
Scripts/                  跨目录校验工具
```

`Sources/State` 中的 Observation 状态对象属于当前原生客户端。核心模块提供实际仓库操作与数据，不要求未来 Windows 客户端采用 SwiftUI 的状态管理方式。

## 依赖方向

```text
macOS 原生界面与状态 → FoldGitCore → Foundation、Subprocess
Windows 界面与状态 → C# FoldGit.Core ← Windows 系统适配
原生测试 → FoldGitCore、FoldGitTestSupport
共享核心测试 → FoldGitCore、FoldGitTestSupport
```

核心不能导入 AppKit、SwiftUI、OSLog 或客户端偏好类型。`Scripts/check-platform-boundaries.py` 检查这条边界，独立 `swift test` 验证核心无需加载原生应用。

日期显示、系统图标名称、搜索帮助文案和本地化统计由 macOS 扩展实现。仓库发现支持注入目录筛选规则，macOS 的应用包过滤由 `MacRepositoryDiscovery` 提供。共享 Git 服务不依赖 `AutoFetchScheduler` 或 `UserDefaults`。

仓库身份仍由规范化文件路径决定，逻辑分组使用独立的 `foldgit-group` 标识和显示名称。`WorkspaceGroups` 负责成员去重、移动、重命名、解散和旧目录分组转换，不执行文件操作。`RepositoryDiscovery` 的目录扫描仅用于导入时快速选择成员，不能覆盖已保存的逻辑分组。macOS 启动时会备份旧边栏数据，再迁移目录分组；仓库路径、显示名称偏好和自动获取配置保持有效。

品牌图标源文件集中在 `Shared/Resources/Branding`。macOS 工程直接引用分层图标，其他平台复用通用 PNG 或内部 SVG 图层。

共享第三方声明只有一份，macOS 工程将 `Shared/Resources/Licenses/LICENSE.txt` 复制到分发包。Windows 打包时使用同一份声明。

## Git 执行与状态

`GitRuntime` 使用 Swift 官方 Subprocess 1.0.0。标准输出和错误输出异步读取，输入写入后关闭；任务取消和超时会清理子进程。标准输出上限为 64 MiB，错误输出上限为 4 MiB，超过上限报错。输出严格按 UTF-8 解码。

同一仓库路径的命令排队，不同仓库可以并行。工作区快照在同一段队列操作内完成，应用内的写入不会插入读取过程。这不限制外部 Git 工具同时修改仓库。

后台 Fetch 的认证限制通过命令环境变量传递，不使用 Unix 的 `env` 可执行文件。共享运行器接受绝对路径或通过 `PATH` 查找可执行文件，不启动命令行 Shell。

`RemoteUpdateService` 合并重复 Fetch，并记录成功时间。同步关系通过真实上游引用和领先、落后数量计算。工作区状态和文件统计使用 NUL 分隔的程序输出，提交消息也使用不会与正文冲突的 NUL 字段分隔符。

`HistoryStore`、`RemoteSyncState` 和 `RepositorySession` 位于 macOS 状态层。它们协调共享服务，并使用请求代次检查防止旧结果覆盖新仓库或搜索条件。搜索历史保留原有 Codable 表示。

## 原生能力

统一与双栏差异共用 AppKit 文本渲染，保留字号、换行、行号和滚动处理。高亮使用 Swift Regex。设置、外部应用发现、登录启动、旧偏好迁移保留在 macOS 目录。

首次启动导入旧应用的已知偏好，不覆盖 FoldGit 中已有的值。测试加载应用时通过 `FOLDGIT_TESTING=1` 禁止导入偏好和启动自动 Fetch。

## 验证与 Windows 范围

在根目录执行 `swift test` 验证共享核心；执行 macOS 工程测试验证原生功能。共享测试创建独立临时 Git 仓库，不依赖上游测试仓库。只有 macOS 测试包含 AppKit 渲染与 Unix 工具路径。

CI 分别运行 macOS 共享测试、Windows 共享测试和原生应用测试。Windows 的原生构建、双架构 MSIX 与实机验收由 Windows 工作流和测试设备验证，本机 macOS 结果不能替代。

## Windows 核心与系统适配

FoldGit.Core 只依赖 .NET，包含 Git 进程执行、NUL 记录解析、二进制读取、提交图、分组和 Worktree 合并工作流。WindowsPathIdentity 使用卷标识与文件标识区分路径身份，不把路径统一转成小写。同一 Git 公共目录的操作排队，关联 Worktree 共用执行通道。平台适配包含 Git 检测、文件监控、偏好原子保存和外部应用发现。WinUI 应用在启动时组装这些服务。

Shared/Resources/FileIcons 保存 SVG 与匹配规则，Shared/Resources/Localization 是文案的单一来源，生成两端原生目录。Shared/Fixtures/behavior.json 由 Swift 与 C# 测试共同读取。
