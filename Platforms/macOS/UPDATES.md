# macOS 应用内更新

FoldGit 使用 Sparkle 2.10.1，在应用内下载、安装更新并重启。应用和嵌套的更新器使用 ad hoc 签名，更新 DMG 与 appcast 使用固定 EdDSA 密钥签名，不依赖 Developer ID 或 Apple 公证。

首次安装仍需要用户信任下载的应用。已经安装的旧版本若只会打开 GitHub 发布页，需要先手动安装一次包含 Sparkle 的版本。后续使用应用内更新；手动下载 DMG 或通过 Homebrew 替换应用仍属于独立安装流程。

## 配置与密钥

- `Configuration/FoldGit-Info.plist` 保存公开的 `SUPublicEDKey`，并强制验证更新包和更新源的签名。
- `Configuration/Base.xcconfig` 定义 `SPARKLE_FEED_URL`，默认指向 GitHub 最新 Release 的 `appcast.xml` 附件。
- 私钥保存在本机登录钥匙串，Sparkle account 为 `com.dufu.foldgit.sparkle`。CI 使用仓库 Actions secret `SPARKLE_EDDSA_PRIVATE_KEY`。私钥不能提交到仓库，也不能在构建日志中输出。
- 不要在每次构建或发布时生成新密钥。失去这把私钥后，现有 ad hoc 安装无法信任由另一把密钥签名的更新。应单独安全备份。

使用与工程相同版本的 Sparkle 官方工具读取公开密钥或导出私钥。

```sh
generate_keys --account com.dufu.foldgit.sparkle -p
generate_keys --account com.dufu.foldgit.sparkle -x /安全位置/eddsa-private-key
chmod 600 /安全位置/eddsa-private-key
```

## 发布流程

1. 按仓库约定更新软件版本、构建号和中英文更新日志。
2. `Scripts/package-macos.sh` 归档 Release，对嵌套的 Mach-O 文件、更新器、框架与主应用由内到外签名，校验后生成 DMG。
3. ad hoc 分发不启用 Hardened Runtime，避免其库校验拒绝无 Apple 身份的嵌入框架。本地 Debug 构建继续使用固定的 Apple Development 签名。
4. `Scripts/sparkle.py` 从 `Shared/Resources/Updates/changelog.json` 读取对应版本，在构建时生成按应用语言选择的说明，使用 Sparkle 官方工具生成并验证带签名的 appcast 与 DMG。公钥不匹配时停止，不会输出可发布附件。
5. CI 验证全部应用语言的日志选择、正常更新、篡改拒绝与错误密钥拒绝，再上传 `FoldGit-macOS-arm64.dmg` 和 `appcast.xml`。Windows 的 EXE 附件照常发布。

简体、繁体中文界面显示现有中文日志，其余应用语言暂时显示英文日志。每种应用语言都有显式的 `xml:lang` 节点，防止系统的次选语言影响显示。说明使用原生纯文本格式，在写入全部语言节点后重新签名，所有语言内容都受 appcast 签名保护。

appcast 是构建产物，保存在 Release 附件中，不在源码或 Cloudflare Pages 中维护副本。CF Pages 的构建命令和输出目录保持不变；如果配置过自定义构建监控路径，需要包含 `Shared/Resources/Updates/**`。

Debug 和测试进程不会启动 Sparkle 更新。菜单和设置按钮会在不能检查时禁用，防止将调试应用替换为发布版本。

## 真实升级验证

2026 年 11 月 4 日，在 Apple Silicon、macOS 27.2 上完成实际验证。

- 使用当前代码构建两个独立的 Release，构建号分别为 `6001` 和 `6002`，Bundle ID 均为 `com.dufu.foldgit`。
- 两个应用均通过完整性校验，签名为 `adhoc`，无 Team ID。仅旧版首次启动前处理一次隔离标记。
- 使用仅监听 `127.0.0.1` 的临时更新源。测试包通过单独的 Info.plist 允许本机 HTTP；生产更新源继续使用 HTTPS。
- 从旧版菜单执行「检查更新」，点击「安装更新」，再点击「安装并重启应用」，由 Sparkle 自行完成下载、校验、替换和重启。
- 新版在原路径运行，构建号为 `6002`，主程序 SHA-256 与新版安装包一致，仍为 ad hoc 签名，没有隔离标记，也未再次出现「移到废纸篓」提示。
- 更新完成后没有手动删除新版隔离标记，全程只运行一个 FoldGit 实例。测试结束后关闭服务器并恢复原有应用偏好。

本次验证覆盖当前主机上的完整应用内升级流程，不代表重新下载 DMG 的独立安装流程，也不替代其他 macOS 版本的兼容性验证。

更新工具的回归测试通过以下环境变量接收真实打包产物，CI 会自动执行。

```text
FOLDGIT_SPARKLE_TEST_APP
FOLDGIT_SPARKLE_TEST_ARCHIVE
SPARKLE_TOOLS_DIRECTORY
SPARKLE_EDDSA_PRIVATE_KEY
```

```sh
python3 -m unittest discover -s Scripts/tests -p 'test_sparkle.py'
```

## 更新日志语言与共享来源

更新日志只在 `Shared/Resources/Updates/changelog.json` 中维护一次。GitHub Release 的双语说明、Sparkle 的本地化说明和网站更新日志页均从这里读取。网站源码只保存 `website/templates/changelog.html` 模板，页面在构建时生成，不提交生成内容。

2026 年 11 月 4 日补充验证了全部 8 种应用语言、中文地区变体，以及法语、日语优先而中文为次选的组合。测试直接调用固定版本 Sparkle 的真实解析器，确认简体、繁体中文显示现有中文日志，其他语言显示英文。实际界面也验证了中文说明，以及法语界面下的英文说明。

每个语言节点的内容都在签名前写入。CI 会逐个篡改各语言节点，确认全部会使 appcast 签名校验失败。修改更新文案后必须重新生成并签名，不能直接编辑已发布的 appcast。
