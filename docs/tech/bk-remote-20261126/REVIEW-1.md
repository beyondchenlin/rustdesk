# BK Remote 技术基线第一轮审查

**审查范围：** PRD 与源码一致性、组件边界、版本基线、默认配置实现路径。  
**审查结论：** 发现 6 项需在实现前修正的技术假设，已写入技术基线和实施门禁。

## 1. 发现与修订

| 编号 | 审查发现 | 修订决定 |
|---|---|---|
| R1-01 | 当前选定的 rustdesk-server 1.1.16 源码中不存在 MUST_LOGIN/JWT 强制登录门禁；该功能属于 nntu 1.1.15 集成分支 | 首版不移植强制登录门禁；保留原生无账号手动连接。PRD 中 MUST_LOGIN=N 应理解为“不启用强制登录策略”，不是当前服务端实际配置项 |
| R1-02 | RustDesk 已有 signed custom client config（签名定制客户端配置）机制，default-settings 可提供默认值，override-settings 会强制覆盖 | 通过 default-settings 设置新安装默认值；不使用 override-settings；为 BK Remote 增加独立公钥，同时保留官方公钥 |
| R1-03 | 现有 ServerConfig 只维护一套活动配置，setServerConfig 逐项写入四个选项，并在 API 地址变化时退出旧账号 | 新增三档服务器配置档案；切换时先保存档案快照，再切换配置；账号、地址簿、设备身份按档案隔离 |
| R1-04 | nntu API 的 DeployToken 有 30 分钟有效期，但 Deploy 不自动消费；Consume 是查询后更新，存在并发重复消费窗口 | 增加原子消费、同设备幂等和审计；不能把现有流程直接称为一次性令牌 |
| R1-05 | Deploy 接口只检查设备 ID 归属并接收 UUID/Pk，没有证明请求者持有对应设备私钥 | 增加短时挑战和 Ed25519 私钥持有证明；UUID、公钥和设备 ID 冲突必须拒绝 |
| R1-06 | API 首次迁移会创建 admin 用户并把 8 位随机密码写入日志 | 删除默认管理员自动创建；改为一次性本机 bootstrap-admin 命令，密码不写日志 |

## 2. 组件边界核对

- 客户端继续以 beyondchenlin/rustdesk 的 a0c0963c 基线开发。
- 服务端继续以 beyondchenlin/rustdesk-server 的 680b603 基线开发，不把 nntu 1.1.15 服务端整体移植进来。
- 账号服务只提取 nntu 固定提交中的 rustdesk-api 后端；不部署 rustdesk-api-web，也不复制完整 Docker 栈。
- SQLite WAL、busy_timeout 和单连接池作为首版小规模部署基线；真实容量通过压测确定。
- app.register=false 必须显式设置并测试；注册路由位于后台认证中间件之前，不能只隐藏前端入口。
- AddressBook.Password 会被解码为明文存储；BK Remote 固定密码不得走地址簿密码同步链路。

## 3. 默认配置核对

现有 password_security 逻辑在配置缺省时返回：
- approve-mode：Both（密码与点击确认）。
- verification-method：UseBothPasswords（固定密码与临时密码）。

custom client config 的 default-settings 会在用户没有本地选项时生效；用户已保存的选项优先。该机制满足“新安装使用默认值、用户后续可修改、升级不覆盖”的需求。override-settings 不符合本项目要求。

## 4. 第一轮通过条件

- 当前服务端没有 MUST_LOGIN，已在基线中明确不移植该门禁。
- 账号注册、管理员初始化、设备登记和远控密码拆分为独立安全边界。
- 三种服务器档案及数据隔离列入客户端实现。
- 中继管理必须同时更新持久化配置和运行时状态。
- 所有上述修订已进入技术基线；无生产代码修改。

**第一轮结论：通过，进入第二轮安全与运维审查。**