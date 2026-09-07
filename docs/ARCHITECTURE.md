# 架构

| 模块 | 职责 |
| --- | --- |
| AppCore / AppModel | App 生命周期、菜单、窗口、账号和全局状态 |
| OopzAPI / OopzSign / OopzWS | REST、请求签名和 WebSocket 事件 |
| SessionStore | 本机账号文件与偏好隔离，支持无钥匙串运行 |
| VoiceSession / AgoraManager | 语音进退房、媒体状态、静音与音量重放 |
| ScreenShareSession | 独立共享鉴权、发布确认、取消、停止、观看 |
| SystemAudio / PCMConverter | 屏幕系统声音与 PCM 转换 |
| PermissionCenter / PermissionChecks | 权限入口状态机及可注入离线检查 |
| IMCenter / Models | 消息处理及业务数据 |
| DiagnosticMessage / DiagnosticLog | 不序列化动态值的本地阶段日志 |
| Verification / MediaTest | 维护者无头集成验证与合成视频发布检查 |

UI 使用 SwiftUI 和少量 AppKit／SDK 渲染视图。SDK 回调通过 MainActor 更新界面；进入 RTC 房间后重新应用账号的音量与静音配置。

共享连接独立于语音连接。鉴权、RTC 发布和服务端 OPEN 确认完成后，界面才进入共享中。取消与停止需要处理晚到回调；退出前停止共享、退语音房、断开 WS。

语音活跃时直接释放 SDK 曾造成退出死锁。退出保留 gracefulCleanup → _exit(0)，退房有超时兜底。不得通过放宽无头设备访问来测试这一行为。
