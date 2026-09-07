# oopz-macOS

OOPZ 的 macOS 社区客户端，使用 Swift、AppKit / SwiftUI 和 Agora macOS SDK。

本仓库是 macOS 客户端唯一的产品开发、测试和构建目录。v0.4.0 已迁入投屏音频隔离与控制修改；后续不再与旧研究目录双向维护产品源码。该版本的真实回声与官方 Web 听感仍待人工验收，详见 [音频说明](docs/AUDIO.md)。

支持 macOS 14 及以上、Apple Silicon 与 Intel。工程保留网页登录、域和频道、语音、文字及图片消息、屏幕共享和三级音量等实现。

**安装包见 [GitHub Releases](https://github.com/yaoshenwang/oopz-macOS/releases)。** 每个版本标签自动构建 Apple Silicon / Intel 通用 DMG 和 ZIP，完成 Developer ID 签名及 Apple 公证后发布。下载 DMG，将 Oopz 拖入 Applications 即可。 本仓库不内嵌生产协议认证材料、用户会话或维护者签名私钥。首次使用通过独立的官方网页登录页获取当前会话与页面使用的协议认证材料，仅保存在本机；该衔接的真实首次登录仍待人工验收。高级配置见 [开发配置](docs/DEVELOPMENT.md)。编译和离线测试不需要账号。

## 开发

要求完整 Xcode 26.0.1（Swift 6.2）或经过验证的兼容版本，以及 Python 3.9+。CI 使用 macOS 15 / Xcode 26.0.1；应用部署目标仍是 macOS 14。

```sh
./tools/bootstrap.sh       # 下载校验固定 SDK，解析锁定依赖，校验官方图标和提示音
./tools/check_fast.sh      # 无账号、无设备、无签名身份的离线检查
./tools/build.sh --compile # 仅编译当前架构
```

`./tools/build.sh --assemble` 组装 universal App 到 `build/<版本>/Oopz.app`，用于检查产物结构，**不是可分发的已公证安装包**。维护者本地签名构建使用 `--local` 和仓库外的配置，不会静默退回其他身份。

运行 GUI 应由用户按实际 App 路径操作；自动检查直接运行无头入口。`build/latest` 由构建脚本更新，旧版本目录保留。

## 功能与验证边界

| 能力 | 状态 |
| --- | --- |
| 账号、域与频道浏览、语音 | 实现已迁移；联网检查要求本机已登录账号及其自有空频道 |
| 文字和图片消息 | 支持历史、实时接收、未读及文本发送；表情、引用、@ 和私聊尚未实现 |
| 屏幕共享 | 独立共享鉴权、发布、停止、取消和观看实现已迁移；官方 Web 实际画面按人工清单验收 |
| 系统音频 | Direct 独立共享轨；投屏期间可调麦克风、成员音量和共享发送／收听音量；真实回声、麦克风并行与远端听感须人工验证 |
| 权限 | 麦克风与屏幕权限入口、返回前台复查；真实 TCC 弹窗和升级授权由用户确认 |
| 更新 | 可配置更新源；当前不提供托管更新服务 |

本地测试通过不代表官方端已经看到画面。服务端接口与限制由 OOPZ 控制，本项目不承诺协议长期稳定。

## 导航

- [贡献流程](CONTRIBUTING.md) · [架构](docs/ARCHITECTURE.md) · [协议维护笔记](docs/PROTOCOL.md)
- [测试与人工验收](docs/TESTING.md) · [签名与发布](docs/RELEASING.md) · [维护模式参考](docs/MAINTENANCE.md)
- [隐私与安全报告](SECURITY.md) · [变更记录](CHANGELOG.md) · [第三方说明](THIRD_PARTY_NOTICES.md)

## 项目关系与许可

这是社区项目，不是 OOPZ 官方 macOS 发行版。OOPZ 服务和相关标识属于其权利人。本项目原创源码采用 [MIT](LICENSE) 许可；保留官方原始图标和提示音，其权利归原权利人所有，第三方资源、SDK 和服务不因此变为 MIT 授权，详见第三方说明。
