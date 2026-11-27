# 安卓安装身份与品牌静态兼容审查

日期：2026-11-27。仅在指定主机 DESKTOP-C0GEQDQ（64 GB 开发机）读取及修改项目。
客户端仓库：`D:\demo2\rustdesk`。
固定原生基线：`a0c0963c483fc8f1aeed4547787d1673adcb583c`。

## 范围与结论

本轮审查 `applicationId`（安装应用标识）改为 `com.bkremote.client`，同时保留 `com.carriez.flutter_hbb` 的 Kotlin（安卓语言）类命名空间及 `ffi.FFI` 的 JNI（原生接口）绑定类之后的静态兼容性。

发现并修复两类问题：原生通知/辅助功能说明残留上游展示品牌；模拟开机广播沿用上游安装标识，导致原版与本产品并装时同一调试动作同时匹配。没有改动真实系统开机动作、系统权限授予方式、原生绑定类或依赖版本，也没有启动额外构建。

本报告不是安装、合并清单、签名、系统授权或真机功能验收通过记录。最终安装包须再次核验生成后的完整清单、签名和实际设备行为。

## 已完成的精确修改

- `flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt`：通知渠道显示名改为 `BK Remote Service`（本产品服务），描述改为 `BK Remote Service Channel`（本产品通知渠道）。渠道内部标识继续使用历史值 `RustDesk`，不重置同一安装身份下的既有通知设置。默认通知标题已在上一项生命周期审查中改为本产品名称。
- `flutter/android/app/src/main/res/values/strings.xml`：应用名、辅助功能说明、前台服务用途说明采用本产品品牌。已检查全部 `res/values-*`（多语言资源目录），当前没有同名资源的其他语言覆盖文件。
- `flutter/android/app/src/main/AndroidManifest.xml`：调试开机动作为 `${applicationId}.DEBUG_BOOT_COMPLETED`（根据实际安装标识生成）。
- `flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/BootReceiver.kt`：按 `${context.packageName}.DEBUG_BOOT_COMPLETED`（运行时安装标识生成）匹配调试广播；删除旧包名常量。真实开机完成动作和主动停服检查保持原逻辑。

## 兼容边界与证据

| 检查项 | 本轮实际确认 | 源码证据入口 |
| --- | --- | --- |
| 安装标识与类命名空间 | 安装标识为本产品；类命名空间继续保留原生编译名称。二者没有在本轮统一重命名 | `flutter/android/app/build.gradle`、主清单、`flutter/android/app/src/main/kotlin/ffi.kt` |
| 原生绑定 | 导出符号继续使用 `Java_ffi_FFI_*`；媒体服务对象通过实际 Java（安卓运行时）对象引用传递，没有以旧安装包名查找该服务 | `libs/scrap/src/android/ffi.rs`、`src/flutter_ffi.rs` |
| 图片提供器 | 固定依赖的图片选择插件清单使用 `${applicationId}.flutter.image_provider`；其实现以 `activity.getPackageName()` 拼相同后缀，没有使用旧安装包名 | 已解析依赖 `image_picker_android-0.8.12+21` 中的 `android/src/main/AndroidManifest.xml` 与 `ImagePickerDelegate.java` |
| 文档及文件传输 | 使用真实系统文档选择器、持久化文档授权和应用专属目录。系统文档提供器名 `com.android.externalstorage.documents` 不属于本产品包名，须保留 | `DocumentPicker.kt`、`DocumentStorage.kt`、`DocumentLogs.kt`、`flutter/lib/utils/android_documents.dart` |
| 辅助功能状态 | 依据实际 `InputService`（输入服务）的连接/销毁状态回调，不通过硬编码旧包名判断已授权 | `InputService.kt`、`MainActivity.kt`、`MainService.kt`、`res/xml/accessibility_service_config.xml` |
| 悬浮窗及应用设置 | 应用专属设置跳转使用 `context.packageName`（实际安装标识）；辅助功能页保持系统通用入口；服务启动使用明确类引用 | `common.kt`、`FloatingWindowService.kt`、`MainActivity.kt` |
| 开机恢复 | 真实系统开机广播保持；调试动作现按实际安装标识隔离。主动停服标记、开机选项及系统权限检查仍先于启动 | `BootReceiver.kt`、`AndroidManifest.xml`、`MainService.kt` |
| 本产品深链接 | 清单注册 `bkremote` 协议；原生前缀返回 `bkremote://`；移动端处理仍走既有连接、文件、摄像头及终端分派 | `AndroidManifest.xml`、`src/common.rs`、`src/flutter_ffi.rs`、`flutter/lib/common.dart` |
| 悬浮窗品牌 | `Show RustDesk`（显示应用）是既有翻译键，原生翻译层会替换为本产品显示品牌；未误改该键导致翻译回退 | `FloatingWindowService.kt`、`src/lang.rs` |
| 通知点击 | 使用本应用内明确主界面类及系统待执行操作，没有硬编码旧安装标识 | `MainService.kt`、`FloatingWindowService.kt` |

固定依赖读取来自：
`D:\demo2\bk-remote-toolchains\pub-cache\hosted\pub.dev\image_picker_android-0.8.12+21`。
本轮只读依赖源码，未修改依赖缓存或构建元数据。

### 必须写明的安装和链接行为

`com.bkremote.client` 与原版 `com.carriez.flutter_hbb` 是不同安装身份。本产品不能作为旧安装身份的覆盖升级；旧应用的数据、固定密码、设备私钥、辅助功能和文档授权不会因改品牌自动迁入。本轮没有增加自动读取或覆盖旧应用私有数据的代码。之后本产品自身的升级必须保持安装身份及兼容签名，并核验版本号递增和保留配置的行为。

本产品清单未把 `rustdesk://`（原版深链接）注册为别名。原版链接不会自动唤起本产品；应在交付说明使用 `bkremote://`（本产品深链接）。移动端连接处理和直接输入设备编号功能仍保留。`WebHomePage`（网页首页）的历史模拟链接和代码注释不属于本次安卓安装路径；没有因该字符串修改网页端或扩大任务范围。

内部文档路径前缀 `/@rustdesk/tree/`、历史日志文件名格式和通知渠道标识仍有上游字样。这些是协议/匹配格式或内部标识，不能仅为全仓文本替换而改名。图片、正式品牌主标来源、图标衍生哈希由品牌交付证据单独核验，本报告不代替该项验收。

## 本轮验证及原版功能证据入口

1. 主清单及原生字符串资源的 XML（标记语言）解析成功。
2. 四个改动文件的 `git diff --check`（差异检查）通过。
3. 主源码目录未残留旧的完整调试开机动作。
4. 与固定基线比较，`InputService.kt`（输入）、`DocumentPicker.kt`（文档选择）、`DocumentStorage.kt`（文档传输）、`AudioRecordHandle.kt`（音频）和 `libs/scrap/src/android/ffi.rs`（原生媒体接口）本轮核对时没有工作区差异。
5. 原版功能总体核验继续以 `PRD.md`（产品需求文档）的 T12（原生功能回归）及 `G1-EXECUTION-20261126.md`（原生基线执行记录）为入口；源文件保留不能替代真实操作验收。

正式待验证：生成清单中类完整名称、所有间接依赖的提供器权限名、最终包安装身份、原版并装、本产品覆盖升级、签名、系统设置展示、深链接冷启动/热启动、辅助功能重新授权、文档选择与传输、悬浮窗、通知点击、真实开机和调试开机。没有执行真实广播或更改全局系统权限。

## 本轮源文件 SHA-256（文件完整性校验值）

| 文件 | 校验值 |
| --- | --- |
| `AndroidManifest.xml` | `83A36622CCBB95B2E6994E3EC6E45E7C103133827D58AFF0779F6E7192DE7944` |
| `BootReceiver.kt` | `BC492852BB3767369DFD99FEB6C4E5644BEF00A6AA27D2DC8CEBCEDC796EF5EA` |
| `MainService.kt` | `B90AE1A0F343D811A8AA0ABFDF554758F838441BD4BB39C13867A8A1F00CAC53` |
| `res/values/strings.xml` | `DBBB3B06EDA5D9ED9A94DD59A5F90E4E9318C38906A49A353B7D494F99F6FE00` |

以上哈希对应本轮精确修改后的工作区字节，供后续最终打包快照核对；没有声称旧构建快照已包含本轮增量。
