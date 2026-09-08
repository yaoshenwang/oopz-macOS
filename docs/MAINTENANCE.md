# 维护模式与参考

采用一个 main 分支、短分支 PR、一个无凭据 PR CI 和标签触发的签名公证发布流程。日常不维护第二套私有产品源码，不建立服务端部署、自动登录机器人、夜间真机测试或庞大的操作系统矩阵。

本次整理参考了以下公开项目／文档（2026-09-07 查阅）：

- [AeroSpace build workflow](https://github.com/nikitabobko/AeroSpace/blob/main/.github/workflows/build.yml)：让 CI 调用仓库内构建和测试脚本，区分调试与发布构建。本项目只保留单环境，不采用其环境变量完整输出或签名方式。
- [Actions contribution guide](https://github.com/sindresorhus/Actions/blob/main/.github/contributing.md)：围绕具体变更组织贡献要求和验证说明。本项目的真机验证继续遵守无头与人工验收边界。
- [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use)：Actions 固定完整提交 SHA、只读权限、不给不可信 PR 签名或账号凭据。
- [GitHub macOS runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)：明确选择已提供的 Xcode 26.0.1，避免默认 Xcode 漂移。
- [Apple notarization tooling](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)：使用 notarytool 与直接 p8 文件参数，不读取钥匙串 profile。

依赖按需升级；升级时同时更新 SDK 校验清单、Package.resolved、第三方声明和相关检查。不增加自动依赖 PR 噪声；只在版本标签上签名安装包，稳定标签进入 Releases，dev 标签仅保存 Actions artifacts。

## Dev 通道参考（2026-09-08）

- [VS Code Insiders](https://code.visualstudio.com/insiders/)：持续提供最新改动供开发者使用。本项目采用持续内测通道，但共用原应用身份以延续权限和数据，没有采用其并行安装策略。
- [Electron release channels](https://releases.electronjs.org/)：区分 nightly、pre-release 和 stable。本项目目前只需要 dev 与 stable；RC 留给未来功能冻结后的候选版本。
- [GitHub GITHUB_TOKEN 触发规则](https://docs.github.com/en/actions/concepts/security/github_token)：自带 token 创建标签后须显式 workflow_dispatch，避免依赖不会触发的 push，也无需长效 PAT。
- [Actions artifact retention](https://github.com/actions/upload-artifact/blob/main/README.md)：安装包留在 Actions，dev 保留 90 天；下载说明与恢复方式见 RELEASING.md。

## 发布前人工审查

扫描之外仍要检查新增加的二进制资源、提交身份、截图、文档样本及新日志出口。第三方库也可能含构建路径，应检查完整组装后的 App。签名证书的公开身份是单独的分发选择。
