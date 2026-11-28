# 代码托管授权恢复与账号仓库推送核验

日期：2026-11-28，北京时间。此记录补充已有阶段交付报告；历史推送失败日志保留，本次核验已解除该项阻塞。

## 实际结果

- 指定64GB（内存容量）开发电脑已重新连接并完成实际命令读写；主机名称为 `DESKTOP-C0GEQDQ`。
- GitHub（代码托管平台）命令行的当前登录账号为 `beyondchenlin`；授权检查退出码0，现有权限包含 `repo`（仓库访问）及 `workflow`（工作流文件更新）。此处未读取或记录令牌值。
- 账号服务已向独立私有仓库 `https://github.com/beyondchenlin/bk-remote-account` 普通推送 `dev`（开发分支），推送退出码0。
- 本地提交与远端分支均为 `ad6db50b4be8cbfb42ca48223fbae4f82da58dd8`。主执行者另通过已连接平台接口读取远端分支，结果一致。
- 远端唯一分支及默认分支均为该开发分支；没有新增标签、触发工作流、合并、发布版本或部署生产服务。
- 账号服务源码工作区干净、暂存区为空；已审查输入与保存快照一致。

## 证据与回退依据

本次完整执行记录：

`D:\demo2\bk-remote-toolchains\logs\account-workflow-authorized-push-20261128-090705-59d035`

该目录 `verification.json`（核验结果）的 SHA-256（文件摘要）：

`6d979de58a8ba603815d4951573590ce3fec32b3e4874e958611b31cf6a821a7`

账号仓库全部已有引用的本地备份：

`D:\demo2\bk-remote-toolchains\logs\account-local-checkpoint-20261128-004149\bk-remote-account-all-refs.bundle`

备份文件 SHA-256（文件摘要）：

`127cbcbe9ab38fc16b6278cf292dc3382cbf1c22e4ae901bdb68c014d9ef483c`

此前权限不足记录：

`D:\demo2\bk-remote-toolchains\logs\account-private-origin-20261128-005217`

旧集成仓库 `beyondchenlin/rustdesk-zhanghao` 未修改。本次没有强制推送、重写历史、修改全局鉴权配置或改变生产环境。

## 验收边界

本次通过的是仓库授权和已审查账号服务代码推送核验。它不替代真实手机安装、发布签名、跨区域中继、多端控制、24小时待命、2小时会话、生产数据库迁移或正式产品验收。