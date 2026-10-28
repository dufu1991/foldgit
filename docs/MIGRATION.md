# FoldGit 迁移记录

## 应用身份

| 项目 | 新值 |
| --- | --- |
| 应用名称 | FoldGit |
| 工程与 Scheme | FoldGit |
| Swift 模块 | FoldGit |
| Bundle ID | com.dufu.foldgit |
| 测试目标 | FoldGitTests |
| 初始版本 | 0.1.0 |
| 签名团队 | 由开发者或发布环境提供 |

当前项目目录保留，旧 Git 历史、分支和远程仓库配置已清除。项目已作为 FoldGit 独立仓库重新初始化，使用 main 分支，以当前整理好的完整项目创建首次提交，尚未配置远程仓库。项目主页采用预期的新仓库地址，实际创建远程仓库后再使用。

## 已有功能的保留范围

- 项目分组、直属仓库发现、排序、活跃与不活跃分类。
- 提交图、历史分页、搜索、提交详情和版本比较。
- 统一与双栏差异、字号、换行、行号和文件折叠。
- 文件与代码块暂存、取消暂存、提交、修改提交和消息模板。
- 分支、标签、远程同步和 Stash。
- 按仓库自动 Fetch、外部应用发现、固定应用和最近应用。
- 外观、语言、会话恢复和登录启动设置。
- 八种语言资源、手动提交消息和提交模板。

自动迁移保留项目列表、项目分组、自动 Fetch 配置、外部应用偏好、提交模板和已知显示偏好。旧应用的系统登录启动授权不会自动变成新应用的授权。

## 来源说明

FoldGit 是由 dufu 独立维护的开源项目，使用独立的应用身份、工程结构和版本管理，项目采用 MIT 许可证。项目版权声明位于根目录 `LICENSE`。

已有的第三方代码和资源在 `Shared/Resources/Licenses/LICENSE.txt` 中单独列明来源、版权和许可，包括来自 Changes 的部分界面与领域代码。该文件同时包含 FoldGit 的 MIT 许可证，并随应用分发。

原来的同步进程扩展、全局同步 Fetch 执行器、自定义提交分隔符、短格式状态解析、Sourceful 运行依赖和测试子模块已经移除。旧仓库中的未提交功能在迁移前进行了完整归档。


## 共享核心与平台目录

原来的根目录 `Sources`、`Resources`、`Configuration`、`Tests` 和 Xcode 工程已拆分。平台无关部分位于 `Shared`，macOS 私有实现位于 `Platforms/macOS`，Windows 接入说明位于 `Platforms/Windows`。

根目录 `Package.swift` 可独立编译和测试 `FoldGitCore`。macOS 工程位置改为 `Platforms/macOS/FoldGit.xcodeproj`，生成入口改为 `Platforms/macOS/project.yml`。平台拆分期间没有恢复旧 Git 历史，后续从 FoldGit 独立仓库的首次提交开始版本管理。

拆分保留现有搜索历史编码与界面偏好。原生日期、图标和文案扩展只存在于 macOS 展示层；后台 Fetch 环境变量改为跨平台传递。项目许可与第三方许可声明保存在 `Shared/Resources/Licenses/LICENSE.txt`。

## Windows 原生客户端

Windows 使用独立的 C# 核心与 WinUI 3 工作台，运行在 .NET 10 上，不通过 Swift 桥接。品牌、文件图标、通用翻译、许可和行为测试样例集中在 Shared。macOS 的全部 Foundation Models 集成、摘要入口与相关测试已移除。Windows 运行与安装验收以 Windows 环境的实际结果为准。
