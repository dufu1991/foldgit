# FoldGit

面向多项目日常开发的 Git 客户端。当前提供原生 macOS 应用，目录与共享核心已为后续 Windows 客户端拆分。

现有功能包括项目分组、提交图、统一与双栏差异、代码块暂存、分支和标签管理、版本比较、搜索、Stash、自动 Fetch 和外部应用集成。macOS 应用支持八种界面语言，并在 Apple Intelligence 可用时提供差异摘要生成。

侧边栏顶部支持按目录名、仓库文件夹名称和自定义显示名称过滤。排序默认保留手动顺序，也可按名称、最近打开、最近修改和最近添加排序。添加菜单可导入本地仓库或目录，也可先选择本地保存位置再克隆远程仓库，成功后自动添加并选中仓库。

仓库分组独立于访达中的目录结构。可以新建分组，选择不同位置的仓库，也可在边栏多选仓库后通过右键菜单统一分组。分组支持重命名、管理成员和解散；每个仓库同一时间只属于一个分组。导入包含多个仓库的目录是快速建组入口，不会持续按目录内容重置成员。分组操作不会移动文件夹，解散分组会保留边栏中的仓库。

提交列表顶部提供统一搜索框，可按作者姓名、邮箱或完整提交信息实时筛选当前分支历史。搜索采用字面匹配，忽略大小写，支持 CJK 输入法上屏后触发和 300 毫秒防抖。新输入会取消旧查询，索引复用、后台匹配和结果分页可避免反复读取完整提交详情，搜索不会触发远程抓取。

支持 Git worktree 管理。设置中的「仓库 → 启用工作树」是全局功能开关，默认开启。全局启用后，仓库右键菜单才显示「启用工作树」选项，各仓库默认不启用；仓库启用后才显示关联目录、分支列表和提交标记，以及新建、管理和完成工作树等入口。主目录与关联工作树共用启用选择。关闭全局开关会隐藏所有工作树入口并保留各仓库选择，重新开启后恢复。当前分支、手动添加的仓库和合并冲突处理始终保留，分支占用检查继续生效。添加任一工作树目录后，侧边栏自动发现关联工作树，并在仓库条目下展开尚未单独添加的目录。关联工作树显示专属图标、工作树标记和分支名称。仓库右键菜单及添加菜单提供新建和管理入口，支持新建分支、使用未占用的已有分支、分离 HEAD、移动、锁定、解锁、移除和清理缺失记录。点击被其他工作树占用的分支会打开对应目录。移除工作树保留分支，不会强制删除存在修改或未跟踪文件的目录。工作树右键菜单和管理窗口还提供「完成工作树」流程，支持检查并选择目标分支、合并提交，以及按需移除目录和删除本地源分支。合并冲突可在原生弹窗中比较两侧版本、选择保留版本或打开外部编辑器处理，再标记解决并继续合并，也可中止合并。未完成的合并会在仓库页面显示处理入口，重新打开收尾流程可继续处理。清理前会再次校验提交已合并，并保留有新提交、未提交修改或锁定状态的工作树。

## 目录结构

```text
Package.swift                 共享 Swift Package 入口
Package.resolved              共享依赖锁定
Shared/
  Sources/FoldGitCore/         平台无关的 Git 与业务核心
  Resources/Branding/         共享图标源文件、矢量图层与通用图片
  Resources/Licenses/         项目许可与第三方许可声明
  Testing/                    可复用的临时仓库测试工具
  Tests/FoldGitCoreTests/      独立共享核心测试
Platforms/
  macOS/                      原生 macOS 应用及其全部私有文件
    Sources/                  SwiftUI、AppKit、状态绑定和系统服务
    Resources/                本地化与 Apple 资源目录
    Configuration/            应用标识、签名和导出配置
    Tests/                    macOS 界面与系统集成测试
    FoldGit.xcodeproj/         Xcode 工程
    project.yml               macOS 工程生成配置
  Windows/                    Windows 客户端接入说明
Scripts/                      仓库级校验工具
.github/                      共享核心与平台构建工作流
docs/                         架构与迁移文档
```

共享模块不依赖 AppKit、SwiftUI、Foundation Models 或 macOS 偏好存储。macOS 应用通过本地 Swift Package 依赖引用核心，不把共享源码重复编译到应用模块。

## 共享核心

使用 Swift 6.2 或更新版本，并确保 Git 位于 `PATH` 中。在项目根目录执行：

```sh
swift test
python3 Scripts/check-platform-boundaries.py
```

CI 分别验证共享核心、Windows 共享核心和 macOS 应用。Windows 图形客户端尚未实现，接入范围见 [Windows 说明](Platforms/Windows/README.md)。

## macOS 开发

仅支持 Apple Silicon Mac，最低系统版本为 macOS 26。本次拆分使用 Xcode 27.1、Swift 6.4 验证。打开 `Platforms/macOS/FoldGit.xcodeproj` 开发。

本地 Debug 构建和测试使用固定的 Apple Development 证书，以便 macOS 在重新构建后继续识别已有的文件访问授权。首次配置时，将 `Platforms/macOS/Configuration/LocalSigning.xcconfig.example` 复制为同目录下的 `LocalSigning.xcconfig`，填写证书的团队标识。该文件已加入 Git 忽略列表，可以把 `CODE_SIGN_IDENTITY` 设置为证书的 SHA-1 指纹以固定具体证书。

团队标识对应证书主题中的 `OU` 字段。开发时保持相同的 Bundle ID 和应用路径，构建命令不要传入 `CODE_SIGNING_ALLOWED=NO`。首次切换签名可能需要重新授权一次。CI 中不启动交互式应用的构建仍可显式禁用签名。

```sh
xcodebuild test -project Platforms/macOS/FoldGit.xcodeproj -scheme FoldGit \
  -configuration Debug -destination 'platform=macOS'

python3 Scripts/validate-localizations.py
```

使用 XcodeGen 2.45 或更新版本重新生成 macOS 工程：

```sh
xcodegen generate --spec Platforms/macOS/project.yml
```

## 图标与本地打包

共享品牌资源位于 `Shared/Resources/Branding`。macOS 直接引用分层图标，其他平台可使用同目录的通用 PNG 与 SVG 图层。

在 macOS 上运行以下命令，生成仅含 Apple Silicon（`arm64`）架构的本地 Release 安装包：

```sh
Scripts/package-macos.sh
```

产物位于 `dist/macos`，包含 `FoldGit.app`、以 `macOS-arm64` 命名的 DMG 和 ZIP，以及 SHA-256 校验文件。本地脚本使用 ad hoc 签名，不执行 Apple 公证；正式发布继续使用签名与公证工作流。

## 应用身份与发布

macOS 应用名为 `FoldGit`，Bundle ID 为 `com.dufu.foldgit`，当前版本为 `0.1.0`。签名配置位于 `Platforms/macOS/Configuration`。

发布工作流需要 `APPLE_TEAM_ID`、`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`KEYCHAIN_PASSWORD`、`AC_USERNAME` 和 `AC_PASSWORD`，用于 Developer ID 签名、公证和票据装订。工作流创建草稿 Release。

详见 [架构说明](docs/ARCHITECTURE.md)、[迁移记录](docs/MIGRATION.md) 和 [本地化指南](docs/LOCALIZATION.md)。

## 开源许可

FoldGit 是由 dufu 独立维护的开源项目，采用 [MIT 许可证](LICENSE)，自有代码版权归 dufu 所有。

项目许可与第三方声明分别列出。包含的第三方代码、Swift Subprocess、Swift System 和 Material Icon Theme 保留各自的版权与许可声明。完整内容位于 [项目与第三方许可](Shared/Resources/Licenses/LICENSE.txt)，随 macOS 应用分发，可在设置的「开源许可」中查看。
