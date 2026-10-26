# Git 提交

- Git 提交信息必须使用英文，包括标题和正文。

# 开发与调试

- 开发调试时，只允许运行一个 FoldGit 应用实例，且必须使用当前代码最新成功构建的版本。
- 启动前先检查已有实例，关闭旧版应用、旧调试实例及临时预览实例，再启动最新构建，避免同时运行多个应用。
- 不得通过复制应用、修改 Bundle ID 或使用不同应用路径额外启动预览实例。
- 验证前确认运行中的应用来自本次最新构建，避免误用已安装版本或旧构建产物。
- 本地 Debug 构建和测试必须使用固定的 Apple Development 签名，并保留相同的 Bundle ID 和应用路径。使用 Platforms/macOS/Configuration/LocalSigning.xcconfig 配置本机证书，不得通过 CODE_SIGNING_ALLOWED=NO 或临时签名启动本地调试应用。
