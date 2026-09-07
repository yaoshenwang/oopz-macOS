# 开发配置

## 无凭据构建

`bootstrap.sh` 从 tools/dependencies.json 的固定 URL 下载 SDK，并在解压之前核对 SHA-256。缓存命中也重新检查压缩包，重新提取框架。SwiftPM 依赖采用精确版本和 Package.resolved。下载失败保留部分文件供断点续传，校验不符立即失败。

大文件在服务端支持时使用校验响应范围的分段下载。可通过 `OOPZ_SDK_CACHE_DIR` 共享原始下载压缩包以减少重复网络传输；缓存不会跳过官方哈希验证，也不会复用其他工程的编译产物。

`check_fast.sh` 不联网、不启动 App、不读取签名身份。`build.sh --compile` 只编译当前架构；`--assemble` 编译两个架构并组装 App。只有显式 `--local` 才读取仓库外的 Developer ID 配置。

## 连接官方服务

这个版本不内嵌共享生产协议签名材料。源码、CI 和安装包都不包含它；它也不是维护者 Apple 签名私钥。

已有本机应用数据中的协议材料仍可使用。新环境需要从有权使用的来源取得 PKCS#1 / PKCS#8 DER 文件，并通过下述无头命令导入，或通过 `OOPZ_PROTOCOL_KEY_FILE` 指定外部文件。仓库不提供抓取密钥的工具。

```sh
build/latest/Oopz.app/Contents/MacOS/Oopz --import-protocol-key "$OOPZ_PROTOCOL_KEY_FILE"
```

导入不会把密钥写进 App，它仅进入应用私有数据文件。然后由用户启动 GUI，通过官方网页登录完成自己的账号登录。新环境没有协议材料时，编译与离线测试正常，连接功能会提示尚未配置。

维护者也可以用 `--import-session FILE` 导入自己的会话，JSON 字段为 `uid`、`jwt`、`deviceId`，可选 `userCommonId`、`name` 和 `avatar`。不要把此 JSON 放在仓库或 Issue 中，也不要把密码/JWT 写进命令行参数。

应用数据目录可以由 `OOPZ_DATA_DIR` 或 `--data-dir` 指定。独立目录不意味着可以绕过同账号单实例限制；同账号锁跨数据目录生效于现行验证入口。

## 对协议材料的后续处理

如果维护者确认一种可公开分发的官方社区认证方式，应将其完整实现提交到公开仓库并补测试。不要用 CI Secret 编译注入生产密钥后宣称它没有被分发，也不要长期维护私有核心源码补丁。
