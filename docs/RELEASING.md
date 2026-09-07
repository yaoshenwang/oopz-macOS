# 签名与发布

## 本机配置

把 JSON 配置放在仓库外、权限设为 0600，通过 `OOPZ_SIGNING_CONFIG` 指定。字段如下；具体姓名、Team ID、密钥 ID 和路径不要写入本文或任何跟踪文件。

| 字段 | 用途 |
| --- | --- |
| private_key | 既有 Developer ID PEM 私钥文件，0600 |
| certificate_chain | 与私钥对应的 PEM 证书链 |
| team_id | 证书团队标识，用于校验签名身份 |
| notary_key | 公证 API 的 p8 私钥文件，0600 |
| notary_key_id / notary_issuer | 公证 API 身份参数 |
| allow_public_certificate_identity | 是否明确允许公开安装包暴露该证书的主体身份，默认不允许 |

普通编译不读取配置。`build.sh --local` 使用固定校验版本的 rcodesign；签名子进程禁止网络、securityd 和钥匙串文件读取，关闭时间戳。签名工具的详细输出保存在忽略目录的私有日志，不进入公共 CI。

Developer ID 的签名者名称可从安装包提取。去掉 README 中的姓名不能消除这一信息。要求隐藏个人身份时，需要先确定合适的分发签名身份；不要把个人签名产物公开上传。

## 发布步骤

1. 修改 Info.plist 的版本只通过 `tools/bump.sh`；更新 CHANGELOG，提交确定的发布源码。工作区必须干净。
2. `./tools/verify.sh --media`：构建一次并验证。build.json 绑定源码清单和完整 App；validation.json 绑定同一文件清单。
3. 完成 docs/TESTING.md 中的人工检查，将验收 JSON 放在仓库外。
4. `./tools/release.sh --preflight --acceptance "$OOPZ_ACCEPTANCE"` 检查所有前置条件，不上传、不签名。
5. `./tools/release.sh --acceptance "$OOPZ_ACCEPTANCE"` 在单独分发副本上添加联网时间戳、公证 App 和 DMG，保留已测试的原 App。
6. 最终公共载荷仅选择版本 DMG、SHA256SUMS、release.json 和人工撰写的发布说明。不要上传整个 build 目录、日志、配置、验证收据或 .distribution。

脚本保留公证提交 ID 和提交文件哈希，超时不自动重新上传相同文件。恢复运行时仍检查产物归属。一个已完成的发布版本禁止覆盖，修复应升新版本。

## GitHub 上线

首次创建远端前确定公开账号／组织；GitHub 仓库归属本身公开可见。本地初始提交采用项目集体署名和 noreply 地址，不导入旧历史。

上传前执行 `python3 tools/audit_public.py --history`，有私有 denylist 时同时启用。不要在命令行、Issue 或聊天中发送访问 token。GitHub 操作使用维护者明确指定的本机 gh 登录；构建、签名和测试不读取 GitHub 凭据。

仓库建立后，启用 Issues、GitHub 私密漏洞报告和自动删除合并分支；主分支要求 `Check` 状态通过，禁止 force push。先让第一次 Actions 实际运行成功，再设置对应必需检查，避免把空仓库锁死。

`python3 tools/publish_source.py OWNER/REPOSITORY` 只做本地预检。确定公开身份并完成本机 gh 登录或环境变量认证后，添加 `--publish` 才会创建公开仓库、推送源码、等待真实 Actions 成功并设置保护。脚本先用 GitHub API 确認当前登录账号与目标仓库所有者一致；不要把 token 写进仓库或发送到聊天中。

`./tools/export_source.sh` 可从干净提交生成仅含源码的 ZIP，供离线审查；不包含旧 Git 历史和被忽略文件。

发布标签使用 `v<Info.plist 版本>`，指向 build.json 中的源码提交；从该提交创建 GitHub Release。源码公开不代表必须同时公开安装包。公开分发 SDK 前确认实际组件许可和随附声明。
