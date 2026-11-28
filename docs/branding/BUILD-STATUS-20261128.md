# BK Remote（远控品牌）双端打包接续记录

## 真实状态

记录日期：2026-11-28。用户本次明确要求使用新上传图标、名称保持 BK Remote（远控品牌），生成微软电脑端和安卓端安装包。范围仍然只有品牌名称和图标，其他功能、默认设置、账号入口、服务器配置和内部身份保持官方版本。

新图标已替换、核验、提交并推送。共享原生接口文件和子模块已准备好，两端工具链预检已完成。

**电脑端、安卓端正式编译均未启动；没有生成本次提交对应的新安装包。**

阻断原因：远程电脑连接器返回本月额度耗尽、工具暂停，并要求停止重试。已经停止远程调用，没有重新配对或绕过限制。恢复可用额度后，从本记录继续构建，不再重复需求研究或素材查找。

本记录通过代码托管连接保存；开发电脑上的源码提交仍是下列指定构建提交。同步本记录时仅快进更新文档，不改变固定构建输入，不处理旧项目的未提交修改。

## 固定构建输入

| 项目 | 已核验内容 |
|---|---|
| 开发电脑 | 64 吉字节内存的 DESKTOP-C0GEQDQ（主开发机） |
| 主源码目录 | D:\demo2\bk-remote-branding |
| 品牌分支 | feature/bk-remote-brand-only-20261128（仅改品牌分支） |
| 构建源码提交 | 17acec5b49e071f738051491abaa8ead90b8672c |
| 官方稳定版本 | 1.5.3 |
| 官方基线提交 | 95cca3f661f635b3cc85c04935fe8d96d8f432ef |
| 共享子模块提交 | fae47e024dd83cef6aaecde0aa7d11731df11649 |
| 原图 | assets/brand/BK-Remote-Official-Logo.png（新正式图标） |
| 原图大小 | 1254 × 1254 像素，725,681 字节，带透明通道 |
| 原图 SHA-256（安全散列校验值） | a14aa2a192bf888bb63b0658b7459e1884b1e49f042d5be486c2feaa8404e7cb |
| 原图电脑副本 | D:\demo2\bk-remote-input\BK-Remote-Logo-20261128.png |
| 计划交付目录 | D:\demo2\bk-remote-delivery\20261128-brand-only |
| 构建证据根目录 | D:\demo2\bk-remote-toolchains\validation\brand-build-20261128 |

主图按字节原样保存；21 项衍生资源的尺寸和校验值全部核对通过，包含多尺寸桌面图标、安卓启动及圆形图标、白色通知图标和通用界面图像。原图未被重绘、调色或覆盖。

旧项目 D:\demo2\rustdesk 保持原状态，不复用其旧功能版最终二进制。

## 四个本地接口文件

以下文件真实存在于主源码目录，受版本控制忽略规则覆盖，源码归档不会自动携带。建立两端独立构建目录时必须显式复制并核验。

| 相对路径 | 字节数 | SHA-256（安全散列校验值） |
|---|---:|---|
| src/bridge_generated.rs | 165654 | 867ca139462466a27c8a57909adb0e337c46bae0d5afd7daf8ebc815492ad663 |
| src/bridge_generated.io.rs | 59686 | 1942c8fd52aa3a76a0950ed90aeb45dfedbf0134669a6b29e69c6bd3a0353f8f |
| flutter/lib/generated_bridge.dart | 453126 | e5857edffd205adada58f70ab38a032d12ca8e15e6f01582c1f7833db237b088 |
| flutter/lib/generated_bridge.freezed.dart | 25201 | 5c41889f95d46ef4b57eba34fc4c29b51e76efaada2abf51e6c0cbbc112ae3d4 |

旧接口文件与官方基线的 317 个共同公开函数签名一致；官方只新增系统安全模块状态查询。本地已手工补齐真实同步包装与导出，318 个官方公开接口均有对应桥接。没有使用伪造返回值，也没有运行执行规范禁止的接口代码生成器。

电脑端和安卓端不消费苹果端的桥接头文件，因此未创建额外头文件。

已保存的证据位于证据根目录的 native-bridge（原生接口）子目录：

- bridge-manifest.json（来源与哈希清单）。
- native-bridge-addition.patch（原生接口最小增量补丁）。

最后补写的准备总结因额度拒绝未落盘；本记录补充已实际核验的最终事实：新子模块已检出固定提交且干净，主仓库子模块指针不变，旧目录子模块仍在原提交且干净。

## 电脑端构建预检

目标为官方六十四位电脑端，保留硬件编解码及显存功能。下列工具与缓存已经核验存在，正式构建命令尚未执行。

| 用途 | 路径 |
|---|---|
| 原生编译器 | D:\demo2\bk-remote-toolchains\rustup-windows\toolchains\1.98.1-x86_64-pc-windows-msvc\bin |
| 原生依赖缓存 | D:\demo2\bk-remote-toolchains\cargo-windows |
| 编译器管理目录 | D:\demo2\bk-remote-toolchains\rustup-windows |
| 界面框架 3.24.5 | D:\demo2\bk-remote-toolchains\flutter-windows-3.24.5 |
| 界面依赖缓存 | D:\demo2\bk-remote-toolchains\pub-cache-windows |
| 微软编译环境入口 | C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat |
| 原生依赖视图 | D:\demo2\bk-remote-toolchains\vcpkg-windows-view |
| 原生依赖安装目录 | D:\demo2\bk-remote-toolchains\vcpkg-windows-installed |
| 绑定解析器 | D:\demo2\bk-remote-toolchains\libclang-windows\clang\native |
| 解析器头文件 | D:\demo2\bk-remote-toolchains\vcpkg-downloads\tools\clang\clang-15.0.6\lib\clang\15.0.6 |
| 电脑端独立编译缓存 | D:\demo2\bk-remote-toolchains\rust-target-windows |
| 官方额外组件 | D:\demo2\bk-remote-toolchains\windows-bundle-supplements |
| 官方下载包来源登记 | D:\demo2\bk-remote-toolchains\downloads\windows-upstream-assets |

界面框架已有官方下拉菜单补丁。原生依赖基线为 9e593bb18ea69cc5095e012465dcd675a822ed0d，与官方源码相同。界面依赖锁及原生依赖清单与旧项目一致，但原生语言依赖锁不同，必须使用本次提交自己的锁文件。

恢复后建立短路径独立源码目录，例如 D:\demo2\bkw-brand-17acec5，复制四个接口文件，初始化固定子模块，并配置以上工具链。其 target（构建目录）需要映射到电脑端编译缓存，供官方界面脚本通过相对路径找到新原生库。

正式构建顺序：

~~~powershell
cargo build --locked --release -p dylib_virtual_display
cargo build --locked --release --lib --features hwcodec,vram,flutter
cd flutter
flutter pub get --offline --enforce-lockfile
flutter build windows --release --no-pub
~~~

上述命令分别构建虚拟显示库、官方完整特性主库、锁定界面依赖和电脑界面。与安卓端使用不同源码目录和编译缓存。

界面成功后，取本次构建的新主程序、新原生主库及新虚拟显示库，补齐经过来源登记的官方驱动、打印组件、运行库和窗口辅助库，再调用本次源码的官方便携包负载生成脚本并重新编译自解压外壳。

不得直接运行旧的 build-windows-portable-candidate.py（旧品牌打包脚本）：它会把包内原程序重命名，改变解压目录身份。其他旧脚本也固定了旧功能版快照，只能参考工具链设置。

包内入口必须保留 rustdesk.exe（原内部程序名）。外层安装入口以 install.exe（安装后缀）结尾时会进入原安装界面；普通品牌外层文件名的完整配置解析链尚未验证，打包前继续核对，不能因命名改变配置身份。

## 安卓端构建预检

目标为 ARM64（六十四位移动处理器架构），官方包名 com.carriez.flutter_hbb（应用内部标识）保持不变。

| 用途 | 已核验路径或版本 |
|---|---|
| 工具根目录 | /mnt/d/demo2/bk-remote-toolchains |
| 原生构建环境 | /mnt/d/demo2/bk-remote-toolchains/wsl-build-env |
| 原生语言编译器 | 1.98.1 |
| 安卓编译辅助工具 | cargo-ndk（安卓原生编译辅助工具）3.1.2 |
| 界面框架 | /mnt/d/demo2/bk-remote-toolchains/flutter-3.24.5 |
| 安卓原生开发工具包 | /home/ai/bk-remote-build/android-ndk-r28c |
| 原生开发工具包版本 | 28.2.13676358 |
| 安卓开发工具包 | /mnt/d/demo2/bk-remote-android-sdk |
| 原生依赖库 | /mnt/d/demo2/bk-remote-toolchains/vcpkg/installed/arm64-android/lib |
| 原生依赖缓存 | /mnt/d/demo2/bk-remote-toolchains/cargo-home |
| 安卓原生编译缓存 | /home/ai/bk-remote-build/rust-target |
| 界面依赖缓存 | /mnt/d/demo2/bk-remote-toolchains/pub-cache |
| 安卓构建缓存 | /mnt/d/demo2/bk-remote-toolchains/gradle-home |

旧链路的原生与未签名安装包构建成功记录只证明工具链曾工作，不证明新提交已构建。

当前主源码目录由微软系统创建工作树指针。应先由微软系统的版本管理工具分别归档指定主提交和固定子模块，再解压到独立的子系统源码目录，例如 /home/ai/bk-remote-build/brand-only-17acec5-source，并复制四个本地接口文件。不要让两个端同时写主工作树的界面构建目录。

沿用已成功工具链的环境设置，保持本次源代码和依赖锁，执行官方原生入口：

~~~bash
cargo ndk --platform 21 --target aarch64-linux-android \
  build --locked --release --features flutter,hwcodec
~~~

原生成功后，核验 /home/ai/bk-remote-build/rust-target/aarch64-linux-android/release/liblibrustdesk.so（新原生库），再与同版本运行库加入隔离快照。不能复制旧功能版成品库充当本次产物。

界面正式入口：

~~~bash
flutter pub get --offline --enforce-lockfile
flutter build apk --release --split-per-abi \
  --target-platform android-arm64 --no-pub
~~~

运行前需为快照配置工具包路径、固定原生开发工具包版本及既有项目签名。旧脚本固定旧基线和未签名专用逻辑，不能原样运行。

### 既有签名状态

本地既有项目密钥库与系统保护的口令文件均已找到。没有创建新密钥，没有输出密码或私钥，也没有把凭据放入源码。

安全解锁预检只返回 CommandNotFoundException（命令不可用异常），没有记录具体失败子命令。因此尚未证明解锁成功，也不能认定密码错误或密钥损坏。恢复后先增加不含秘密的步骤标记，定位命令问题，再使用既有密钥完成签名。不得用临时签名冒充原签名。

## 恢复后的完成标准

1. 核对主源码提交、子模块、四个本地接口文件和新图标。
2. 使用隔离构建目录完成双端原生及界面编译，保留每一步退出码与日志。
3. 电脑端完成真实自解压安装包；核对文件属性、图标、依赖及签名状态。
4. 安卓端完成既有项目签名；核对应用包名、名称、资源、原生架构、接口导出、对齐和签名。
5. 保存最终文件大小、校验值和来源提交，并确认产物真实存在后向用户提供路径。
6. 未经后续明确测试指令，不替换用户现用电脑远控服务，不卸载或安装用户手机软件。

截至本记录，没有后台正式构建任务，也没有可交付的新安装包。
