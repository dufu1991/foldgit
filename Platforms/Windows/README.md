# FoldGit for Windows

原生 Windows 客户端使用 C#、WinUI 3 和 .NET 10，目标为 Windows 11 24H2 及以上，支持 x64 和 ARM64。Windows 不依赖 Swift，也不包含 AI 功能。

## 工程与依赖

- `src/FoldGit.Core`：进程执行、Git 记录解析、差异、提交图、工作区和 Worktree 工作流。
- `src/FoldGit.Platform.Windows`：Windows 文件身份、Git 检测、文件监控、设置和外部应用。
- `src/FoldGit.App`：原生 XAML 工作台、MVVM 状态、差异控件、设置与系统集成。
- `tests/FoldGit.Core.Tests`：不依赖界面的行为测试程序，创建独立临时仓库。
- `Packaging/package.ps1`：MSIX 构建、签名、校验文件和 App Installer 清单。

开发环境需要 Visual Studio 的 WinUI 应用开发工具、Windows SDK、Python 3，以及 `global.json` 指定的 .NET SDK。NuGet 依赖固定版本并保存锁文件。普通构建使用已提交的资源，不需要 Node.js、Pillow 或 Icon Composer。

```powershell
python Scripts/generate-resources.py --check
python Scripts/validate-windows.py
dotnet run --project Platforms/Windows/tests/FoldGit.Core.Tests -c Release
dotnet build Platforms/Windows/src/FoldGit.App -p:Platform=x64 -p:RuntimeIdentifier=win-x64
```

在 Visual Studio 中打开 `FoldGit.slnx`，选择与本机一致的架构，设置 `FoldGit.App` 为启动项目。使用已注册的 MSIX 应用身份调试。应用将第二次启动重定向到现有进程。

## Git 与认证

安装 Git for Windows，或者在设置中选择 `git.exe`。检测顺序为显式配置、Git for Windows 注册表、`PATH` 和标准安装目录。错误的显式路径会显示配置错误，不会静默改用另一套 Git。

执行器使用参数列表直接启动进程，异步处理输入与两路输出，保留二进制内容，支持超时和取消。标准输出限制为 64 MiB，标准错误限制为 4 MiB。同一 Git 公共目录的操作串行执行，避免关联 Worktree 的应用内写操作互相插入。用户凭据助手、SSH、签名和 Hooks 继续由 Git 管理。后台 Fetch 禁止交互认证，重复 Fetch 请求合并。

## 资源和偏好

品牌、文件图标和许可从 `Shared/Resources` 引用。维护共享翻译后运行 `python Scripts/generate-resources.py`，生成两端原生资源。Windows 运行时使用同源翻译目录处理动态文本和复数；MSIX 的显示信息使用 `.resw` 资源。

Windows 图标已生成并提交。更改共享品牌图后，使用 Pillow 12.1.1 运行 `python Scripts/Branding/generate-windows-icons.py` 更新平台派生资源。

偏好保存在当前用户本地应用数据目录下的 `FoldGit/settings.json`，通过临时文件替换完成保存。包括仓库、逻辑分组、显示偏好、模板、最近应用和待完成 Worktree 流程。语言切换在下次启动时生效。恢复默认设置保留仓库与分组，并备份原设置文件。

## 打包

正式 Release 每个架构只发布一个 EXE 安装程序，支持 x64 和 ARM64。安装程序包含 .NET 和 Windows App SDK 运行时，安装到当前用户目录，并提供开始菜单入口与卸载程序，无需用户导入证书。

本地打包需先安装 Inno Setup 6：

```powershell
Platforms/Windows/Packaging/installer.ps1 -Architecture x64
Platforms/Windows/Packaging/installer.ps1 -Architecture ARM64
```

EXE 产物保存在 `dist/windows/<architecture>/installer`。配置可信代码签名证书后，可通过 `-CertificateThumbprint` 同时签名应用与安装程序。CI 会验证安装、启动和卸载。发布附件使用固定文件名，官网下载链接通过 `releases/latest/download` 获取最新版本。

MSIX 仍可用于开发调试与构建验证：

```powershell
# 只验证构建。未签名包不能作为正式安装包分发。
Platforms/Windows/Packaging/package.ps1 -Architecture x64 -Unsigned
Platforms/Windows/Packaging/package.ps1 -Architecture ARM64 -Unsigned

# 正式包需要可信证书，证书主题必须匹配清单中的固定 Publisher。
Platforms/Windows/Packaging/package.ps1 -Architecture x64 -CertificateThumbprint YOUR_CERTIFICATE_THUMBPRINT -UpdateUri https://example.com/foldgit/windows/x64
```

产物保存在 `dist/windows/<architecture>`。固定应用身份为 `dufu.FoldGit`，Publisher 为 `CN=dufu`，初始版本为 `0.1.0.0`。首次正式分发前应配置对应的可信发布证书，后续版本保持相同身份。脚本只生成产物，不上传、不自动发布。

App Installer 在后续启动时检查更新，不配置后台强制更新。应用内关闭流程等待正在执行的操作结束并保存状态。

## 验证边界

macOS 可运行 C# 核心测试、编译 Windows 适配库，并使用官方引用程序集检查界面 C# 类型。WinUI 的 XAML 编译、应用启动、凭据交互和 MSIX 安装必须在 Windows 上验证。

`.github/workflows/windows.yml` 提供 x64 和 ARM64 的行为测试、应用构建和未签名打包任务。尚未运行的 CI 或实机步骤不能视为已通过，验收项见 `docs/WINDOWS_PARITY.md`。
