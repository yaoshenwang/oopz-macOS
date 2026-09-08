# 签名与发布

## Dev 内测通道

持续开发用 dev；beta / RC 适合功能冻结后的候选发布，目前不引入这两种通道。日常 main 更新自动产出 dev 安装包，正式版本仍由维护者明确创建 `vX.Y.Z` 标签。

1. main 更新（或手动运行 Dev workflow）后，先审计该提交及历史，再创建不可变标签 `v<Info.plist 版本>-dev.<run_id>.<attempt>.g<12 位提交>`。
2. Dev workflow 使用 GitHub 自带的 GITHUB_TOKEN 显式 dispatch 同一份 Release workflow 到该标签。仅创建标签不会触发下一条 workflow，因此不能省略 dispatch；无需新增 PAT。Dev 请求成功只表示已派发，安装包状态以对应 `Installers · v…-dev.…` 运行的结果为准。
3. 标签提交必须属于 main。无凭据任务运行完整离线检查、universal 构建及 App 审计；签名任务仍只在现有 release environment 的 `v*` 标签范围运行。没有放开分支签名、PR 签名或使用本机钥匙串。
4. 同一脚本执行 Developer ID 签名、App / DMG Apple 公证、双架构签名验证、DMG 实际挂载验证及无头启动。任何一步失败都不上传安装包，不降级为临时签名。
5. dev 的 publish 任务跳过，发布脚本也拒绝 dev 标签。安装包保存在 Actions Artifacts，保留 90 天；不会创建 GitHub Release、占用 Latest 或触发正式更新。公共仓库的 artifact 不是私密分发渠道，登录并有仓库读取权限者可以下载。

下载：进入 [安装包运行列表](https://github.com/yaoshenwang/oopz-macOS/actions/workflows/release.yml)，选择成功的 `Installers · v…-dev.…`，在 Summary 下载链接或 Artifacts 中取得 `Oopz-v…-dev.…-universal`。其中仅包含 DMG、ZIP、SHA256SUMS、release.json 与说明；不包含账号、私有日志或验证收据。

```sh
gh workflow run dev.yml --ref main              # 重建当前 main，无需改版本
gh run list --workflow release.yml --limit 10   # 找对应 dev 标签的安装包运行
gh run watch RUN_ID --exit-status              # 等待安装包真正完成
gh run download RUN_ID --pattern 'Oopz-v*-dev.*-universal' --dir /tmp/oopz-dev-download
```

下载后在解出的安装包目录执行 `shasum -a 256 -c SHA256SUMS`，退出旧 App，再用 DMG 替换 Applications 中的 Oopz。dev 与 stable 保留相同 bundle ID、URL scheme、数据和权限，不支持并行运行或数据隔离。App 的数值版本仍来自 Info.plist；分发副本的“关于”显示完整 dev 标识，release.json 记录基础版本、通道与完整源码提交。没有自动升级服务，也不承诺未来的数据结构可向旧版回退；当前可手动替换为仍保留的已知可用安装包。

失败恢复：构建或公证失败可重跑安装包 workflow 的失败任务；unsigned 中间产物保留 1 天，过期后重跑全部任务。Dev 请求在创建标签后 dispatch 失败时，可运行 `gh workflow run release.yml --ref EXACT_DEV_TAG`；也可重新运行 Dev 请求（新的 attempt 标签）。artifact 过期后可针对仍存在的原 dev 标签重跑全部任务，得到相同源码的新签名构建；签名、公证时间与安装包哈希可能变化，不保证二进制逐字节复现。不要移动或复用 dev 标签指向其他源码。

稳定 Release 资产继续禁止覆盖。自动化不执行真实麦克风、桌面采集或官方 Web 验收；内测包也必须按 TESTING.md 由用户确认真实使用效果。

### GitHub 标签保护配置

首次启用需要区分两条 tag ruleset：原 `v*` 规则排除 `refs/tags/v*-dev.*`，其余标签的创建、更新和删除仍仅维护者可执行；新增 dev 规则匹配 `refs/tags/v*-dev.*`，禁止更新和删除（保留维护者恢复权限）。dev 的创建使用普通仓库写权限，因此 Dev workflow 的 GITHUB_TOKEN 可以创建，但不能改写或删除 dev 标签。拥有仓库写权限的协作者也可以创建 dev 标签；签名任务仍强制检查该提交属于 main。不要给 Actions 整体绕过稳定标签保护，也不要放开 release environment 到分支。

如果创建 dev 标签失败，先确认 ruleset 范围是否仍把 dev 纳入“仅维护者可创建”。不要通过添加长期 PAT 或关闭所有标签保护来修复。

## 自动发布（默认）

修改版本与 CHANGELOG，经过 PR / CI 合入 main，然后推送对应版本标签：

```sh
git switch main
git pull --ff-only
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
git tag "v$VERSION"
git push origin "v$VERSION"
```

Release workflow 自动执行三个独立任务：无凭据构建和审计；Developer ID 文件签名、App / DMG 公证和挂载启动验证；发布 DMG、ZIP、SHA256SUMS、release.json 到 GitHub Release。只有最后一步有 contents: write 权限。版本与标签必须一致，提交必须已合入 main。失败不会公开不完整草稿。

签名使用 release environment 的六项加密 Secrets：MACOS_SIGNING_KEY、MACOS_CERTIFICATE_CHAIN、MACOS_TEAM_ID、NOTARY_KEY、NOTARY_KEY_ID、NOTARY_ISSUER。环境仅允许 v* 标签；普通 PR 没有凭据。文件只在临时目录以 0600 权限创建，签名密钥在公证后删除；API 私钥在 DMG 公证后删除；不缓存、不上传私有日志，不使用系统钥匙串。维护者已允许公开证书主体身份。

同一版本的已公开资产禁止覆盖。临时失败可在 Actions 中重跑失败任务；签名已成功时只重跑 publish，可复用该次签名产物。修复已发布版本应升新版本。公证队列最长每次等待 40 分钟，超过时失败，不无限等待。

正式安装包始终要求 Developer ID 和 Apple 公证，不提供自动降级签名。云端只证明离线、签名、公证和安装结构检查，真实官方 Web 及听感验收仍单列。

## 本机配置（可选本地发布）

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

## 本地发布步骤

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
