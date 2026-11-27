# G1 原生基线实测记录

日期：2026-11-26（北京时间）。设备：DESKTOP-MK0M4SP。工作目录：D:/demo2/rustdesk。
源码基线：a0c0963c483fc8f1aeed4547787d1673adcb583c；分支：feature/bk-remote-foundation-20261126。
本记录不代表 G1 全部通过，不代表发布包可用，不代表真机验收完成。

## 本轮真实执行

- 需求 Markdown 归档原件与仓库副本 SHA-256 一致：C2EECD27DC124B43AEC333ABC44D0FCEC91ACA8882C45D9661FB051893C487D3。
- 以官方工作流固定的 Flutter（跨平台开发框架）3.24.5 / Dart（开发语言）3.5.4 运行四组原生回归，未执行依赖下载。
- 测试文件：server_settings_dialog_test.dart、account_password_login_test.dart、request_approval_menu_test.dart、android_file_transfer_setup_test.dart。
- 结果：22 通过、0 失败，退出码 0，工具报告总耗时 129.54 秒。
- Windows 原生调试库首次构建退出码 101，bindgen（代码绑定生成器）找不到 libclang.dll；定位到现有 C:/Users/ai/scoop/apps/llvm/current/bin/libclang.dll，使用进程级 LIBCLANG_PATH，不修改系统全局环境，不修改上游源码。
- 重新执行 cargo build --locked --offline --lib --features flutter --jobs 1，退出码 0，耗时 64.72 秒。生成 target/debug/librustdesk.dll，83,328,000 字节，修改时间 21:58:25。存在上游编译警告（含 LNK4098），未声称正式发布编译通过。
- vcpkg（原生依赖管理器）固定提交 9e593bb18ea69cc5095e012465dcd675a822ed0d，与官方工作流一致。
- 独立安卓 SDK（开发工具包）目录：D:/demo2/bk-remote-android-sdk。从 D:/demo1/BKSOP-tools/android-sdk 复制平台 36（11,343 文件）、构建工具 35.0.0（170 文件）、设备调试工具（15 文件）、许可证文件（8 文件）；所有文件逐一比对 SHA-256，一致，退出码 0。未改动来源目录。
- scripts/bk-remote/test-baseline.ps1 已创建，语法检查及 Check（预检）模式通过；用于复现固定版本、源码检查、四组测试和原生调试构建。正式发布构建不是该脚本的通过范围。
- Windows 图形客户端执行 flutter build windows --debug --no-pub，退出码 0，工具报告耗时 42.40 秒。复用已有图形可执行文件（3,040,768 字节；最后修改时间 21:38:14；SHA-256：181A72184E721C56C40B4D1BD016FF745BC464995241C3864B316D932DE1CBF6），安装目录中的 librustdesk.dll 与本轮 21:58:25 重新编译的原生库哈希一致。此结果为增量调试构建，不是全量干净发布构建。现场已有 RustDesk 服务运行，因此未启动同品牌原版调试程序，避免干扰现有服务。

## 尚未通过的门禁

- Windows 原版调试程序实际运行验收、原生完整功能测试、含硬件编解码的发布构建。
- Android（安卓）NDK（原生开发工具包）r28c 已安装；仍缺 Rust（核心开发语言）aarch64-linux-android 目标库、cargo-ndk（交叉编译工具）及安卓架构原生依赖。未构建安卓安装包、未真机连接验收。
- 正式品牌原始图片、正式自建服务器地址及公钥、签名材料仍未核实。
- 当前 D 盘可用空间低于 50GB；用户允许继续使用现有空间，优先复用缓存。单任务编译避免与其他项目争抢内存。不删除其他项目文件，不擅自迁移源码或工具。
- 不修改现有生产服务，不把原生调试构建结果冒充完整双端发布验收。


- 安卓独立 SDK 管理器 --list_installed 退出码 0，确认平台 36、构建工具 35.0.0、设备调试工具 37.0.1 已被识别。

## 22:02 补充实测

- 全量 Flutter 测试命令 flutter test --no-pub --concurrency=1 --reporter expanded，182 通过、0 失败、2 跳过，退出码 0，耗时 42.79 秒。此结果包含此前四组测试，不重复累计。
- 独立 SDK 安装 NDK 28.2.13676358（r28c）退出码 0，耗时 38.08 秒；source.properties 版本正确、clang.exe 存在且 --version 返回 19.0.1。
- Rust 当前使用独立 MSVC 安装，aarch64-linux-android 目标库目录不存在，已核查的 rustup 与 cargo-ndk 路径不存在。原生安卓 vcpkg 依赖未安装；不能将 Windows 原生依赖直接用于安卓。
- 22:02:33 磁盘 C/D/E 分别剩余 31.96/42.42/32.77GB；内存可用 5.37GB。仍不清理其他项目，不动生产服务。
- G1 尚未整体通过；Windows 调试构建和 Flutter 回归通过，双端正式构建及真机测试仍需完成。

## 23:46 后补充实测

- 客户端、服务端均保持原固定提交。服务端 `libs/hbb_common` 初始未初始化，已按 Git 固定提交 69cea8dafee147848ae88702029f4bf7df7224c3 初始化，退出码 0；服务端工作区仍干净。Cargo.toml 声明版本 1.1.17，git describe 为 1.1.16-25-g680b603，不等同于生产 1.1.16 发布包。
- 独立 Rustup（工具链管理器）安装器使用官方 SHA-256 校验成功，安装 Rust 1.98.1 与 aarch64-linux-android 目标，退出码 0；未修改全局 PATH 或其他项目工具链。
- cargo-ndk（安卓交叉编译工具）3.1.2 安装成功，cargo ndk --version 实际验证通过。
- 最小原生库测试生成 ELF64/AArch64 动态库，编译及 llvm-readelf 检查退出码均为 0。输出 D:/demo2/bk-remote-smoke/android-arm64-20261126/libbk_remote_toolchain_smoke.so，SHA-256 51A6C2DD89310964146D195ADA9D4D88E76740C5B5E7A5BA037A998C988B5DA2。该测试不是完整客户端构建。
- Flutter doctor -v 的 Android toolchain 与 Visual Studio 项均通过；安卓平台 36、构建工具 35.0.0、Java 17 已识别，所有安卓许可证已接受。仍有 Flutter 来源渠道与未安装 Android Studio 的警告；没有发现安卓真机。
- 客户端 cargo fetch --locked --offline --target aarch64-linux-android 退出码 0。
- 服务端离线依赖检查先因缺少 async-speed-limit 固定提交而失败；随后 cargo fetch --locked --target x86_64-pc-windows-msvc 退出码 0，保留原锁文件；服务端原版测试尚未执行。
- vcpkg（原生依赖管理器）安卓 arm64-android 依赖安装预检退出码 0，固定上游覆盖端口共 19 个包，另建 vcpkg-android-installed/buildtrees/packages 目录，不覆盖 Windows 基线依赖；实际安装已启动，进程 PID 47308（PowerShell），最后记录到第 3/19 个包 aom 主机发布构建，未完成。构建并发限制为 2，不清理其他项目。
- 新增 scripts/bk-remote/test-android-baseline.ps1，语法检查、固定版本与工具链预检通过；明确输出 ANDROID_DEPS_NOT_READY。Native/Package 模式尚未执行，完整安卓库和 APK 未生成。脚本拒绝修改原版跟踪源码、覆盖不同的现存原生输入及未通过依赖检查的构建。
- 磁盘最新核查 C/D/E 约 31.68/41.17/32.77GB；后续可用内存降至 1.46GB，不并行启动另一项重型原生编译；保留已经执行的安卓依赖构建。
- 正式 Word 原件的项目文件原始字节导出失败；品牌原始母版在指定本地目录仍不存在。本轮不使用其他候选图冒充正式品牌，不重新绘制、不覆盖原始素材。
- G1 未全部通过，仍无业务源码变更、正式安装包、生产部署或验收通过结论。
## 2026-11-27 06:29 后实测

- 06:29:25 可用内存 5.18/31.82GB，D 盘剩余 41.06GB，昨晚的安卓依赖进程已退出，非内存不足。
- 原 vcpkg 安装进程 47308 完整退出码 1，已装 3/19 个依赖。阻塞 aom:arm64-android 3.14.1，CMake 未找到 ASM 汇编编译器，回落到 as。保留现有 x64-windows-static 主机依赖，不降级编码库、不关闭汇编优化。
- 新增 scripts/bk-remote/triplets/arm64-android.cmake，继承固定上游 arm64-android 构建配置，显式指定已安装 NDK r28c 的 clang.exe 与 aarch64-linux-android21 汇编目标；不修改任何上游源码。命令行指定 overlay-triplets 后依赖计划退出码 0，3 个已安装依赖复用，剩余 16 个。
- 06:31:06 两种构建类型的 AOM 配置日志均显示 ASM compiler identification 为 Clang，正确识别 NDK 编译器，Configuring done、Generating done；已经进入安卓调试依赖编译。完整 16 个依赖尚未完成。进程 23960，日志 D:/demo2/bk-remote-toolchains/android-deps-retry-20261127.log。
- 服务端原版库测试编译首次调用被 Windows PowerShell 对标准错误流的 NativeCommandError 处理打断，并非 Rust 源码报错。已改为保存原生命令标准输出/错误流至独立日志后按真实退出码处理，重试进程 7916，单任务编译，日志 D:/demo2/bk-remote-smoke/server-baseline-20261127/build-retry.log。原版测试将在独立测试目录运行，核对原数据库哈希；未部署或运行生产服务。
- 06:31:51 可用内存 4.60GB，D 盘剩余 40.95GB；目前只运行本项目两项有限并发的构建工作，不再增加其他重型构建进程。
## 2026-11-27 06:40 实测

- 服务端原版库编译退出码 0，耗时 5 分 29 秒；独立目录执行 11 项库单元测试，11 通过、0 失败、0 跳过，退出码 0，测试耗时 4.40 秒。原有服务端数据库哈希不变（SERVER_EXISTING_DB_UNCHANGED）。此结果不包含 hbbr 二进制、全量集成测试、生产部署或真实远控连接。
- 安卓依赖编译修复已验证：aom 3.14.1、cpu-features 0.11.0、ffmpeg 7.1.1 的 arm64-android 依赖均成功安装；06:40:48 共 10/19 个依赖完成，正在重试阶段第 8/16 个 libjpeg-turbo 主机依赖（总体第 11/19 个）。构建进程仍运行；尚未产生完整安卓原生客户端库及 APK。
- 06:40:48 可用内存 5.71/31.82GB，C/D/E 盘剩余 31.52/38.85/32.77GB。两个仓库原有源码无修改，生产服务保持不变。
## 2026-11-27 06:50 实测

- 安卓原生依赖重试成功，19/19 个依赖已安装，ANDROID_DEPS_RETRY_EXIT=0。日志记录重试安装耗时 19 分钟。依赖预检退出码 0，确认全部所需安卓静态库存在，包括 libaom、libvpx、libyuv、libopus、libavcodec、libavutil、libndk_compat。
- 完整安卓原生基线构建首次启动因 Windows PowerShell 的默认 RepoRoot 参数解析失败，尚未进入实际编译；重试显式传入 RepoRoot，工具链与依赖预检均通过，已进入 cargo ndk ARM64 编译，进程 37472，日志 D:/demo2/bk-remote-smoke/android-native-baseline-retry-20261127.log。尚未验证完整原生库输出或安装包。
- 06:51:02 可用内存 6.11GB，D 盘剩余 36.21GB；客户端与服务端原有业务源码无修改。
## 2026-11-27 07:22 实测

- 完整安卓原生编译原进程退出：openssl-sys 0.9.104 使用锁定的 openssl-src 3.5.4 进行交叉编译时，Windows 原生 Perl 不支持 Unix 路径语义，配置失败，退出码 101。不是内存耗尽。
- 复用 vcpkg 已安装的 MSYS2 Perl/Make，Perl osname=cygwin，IPC::Cmd 加载通过。仅对本次进程设置 OPENSSL_SRC_PERL、PATH、MAKEFLAGS=-j1，保留依赖锁、加密功能和源码不变。
- 07:23:21 重试已进入 openssl-sys 实际编译，进程 14276，日志 D:/demo2/bk-remote-smoke/android-native-baseline-msys-20261127.log，尚未通过完整原生库验收。
- 可用内存 5.72GB，D 盘剩余 35.66GB。未修改原业务源码或生产服务。
## 2026-11-27 07:27 后实测

- MSYS Perl 重试通过 OpenSSL 配置，但 cargo-ndk 的 Windows 编译器包装路径被 Unix shell 错误解析，make 退出 2，完整安卓编译退出 101。根因不涉及业务源码及内存。
- 单独使用已锁定的 openssl-src 300.5.3+3.5.4 源码和 NDK r28c，显式指定 Clang、llvm-ar、llvm-ranlib 的 Unix 兼容路径；保留 vendored 选项及硬件优化，构建成功，PINNED_OPENSSL_EXIT=0。缓存 crate SHA-256 与 Cargo.lock 一致：DC6BAD8CD0233B63971E232CC9C5E83039375B8586D2312F31FDA85DB8F888C2。构建脚本及日志在 D:/demo2/bk-remote-toolchains/ssl-android-3.5.4/。
- OpenSSL 3.5.4 版本头文件检查通过。libssl.a SHA-256 4003D6C2E15AFCEEF06CFE0142E8724DAEB643480DCCCB889E5A649E2806106C；libcrypto.a SHA-256 AD5C9BAD915A77624EC3F46025266DF2E6554FF9E1C1C20D6C51780047A748C1。NDK 链接测试生成 AArch64 ELF64，退出 0。仅验证链接和架构，未在安卓设备运行该测试程序。
- 修订 test-android-baseline.ps1 的 RepoRoot 初始化及目标专用 OpenSslRoot 参数；使用目标专用 OPENSSL_NO_VENDOR/OPENSSL_DIR/OPENSSL_STATIC，不改变 Windows 或其他项目的全局环境。脚本语法检查与依赖预检通过。07:32 已启动 Package 模式，进程 48960，日志 D:/demo2/bk-remote-smoke/android-baseline-package-20261127.log。已越过 openssl-sys 失败点，完整安卓库及 APK 尚未通过验收。
- 为避免客户端原版编译阻塞所有开发，服务端通过其独立基线后，在独立分支 feature/bk-remote-relay-20261127 实施中继健康探测首个业务增量。两轮代码自审及最终核心库/中继模块全量回归均通过（15+15=30，0 失败），实际管理命令的错误输入与不健康节点测试通过。本地检查点 734b3c2，未推送、未合并、未部署；原有数据库哈希不变。服务端证据 docs/bk-remote/relay-probe-20261127.md。
- 中继探测仅验证转发与公开准入密钥匹配，不是密码学服务器身份认证，不代表 R07 完整通过；持久化节点池、集中切换和回滚仍待实施。客户端跟踪业务源码仍保持原版固定提交。
## 2026-11-27 08:08 补充实测

- 安卓 libsodium-sys 0.2.7 在 Windows 主机交叉编译时选中了桌面架构库；从锁定 crate 源码编译安卓 libsodium 1.0.18，源包 SHA-256 6B779387CD56ADFBC02EA4A668E704F729BE8D6A6ABD2C27CA5EE537849A92FD 与依赖锁一致。产物 D:/demo2/bk-remote-toolchains/sodium-android-1.0.18/install/lib/libsodium.a，SHA-256 A152DC57A133D81328CE39EBA0B19F5FF0739F251385070DAAF8ECB2B9271667。版本头和 NDK AArch64 ELF64 链接测试通过，未执行安卓真机测试。
- test-android-baseline.ps1 添加目标专用 SodiumRoot 参数和链接搜索路径，不设置会影响宿主构建的全局 SODIUM_LIB_DIR。Package 重试越过 libsodium，但 oboe-sys 的 pthread_cond_clockwait 未声明。最小 C++ condition_variable 编译证明无版本 target 退出 1、明确 android21 目标退出 0。已在目标专用 CFLAGS/CXXFLAGS 明确 API 21，不提高最低版本。
- 08:07:26 最新 Package 重试已经越过 oboe-sys，失败于 hwcodec ec38ebaf 的 bindgen 生成步骤：common.h 找不到 stdint.h，原生编译退出 101，外层退出 1。日志 D:/demo2/bk-remote-smoke/android-baseline-package-api21-20261127.log。尚未生成完整原生库或 APK，不能标记客户端基线通过。保留硬件编解码，不改变上游源码或依赖锁。下一步针对 NDK sysroot 和宿主/目标构建差异排查。
- 服务端继续既定 R07：独立版本日志、健康检查、集中管理、并发冲突保护、运行时读回、全节点故障停止分配、回滚和重启恢复，保留原版默认模式。本地检查点 b80f2d9，分支 feature/bk-remote-relay-20261127。两轮自审后最终回归 22+18=40 项通过、0 失败；三个调试可执行文件构建成功。两个独立真实中继进程及一个设备识别进程隔离联调和最终复测均退出 0，原数据库哈希不变，测试进程已关闭。详见服务端 docs/bk-remote/relay-managed-20261127.md。未推送、未合并、未部署生产，Linux 与跨区域、真机远控尚待验收，R07 尚未整体通过。
- 08:07:55 可用内存 11.52GB，D 盘剩余 33.85GB；未清理其他项目。

## 2026-11-27 Linux 隔离构建补充记录

- 保持客户端固定提交 a0c0963c、子模块 450cc1d7 不变；Windows 原版测试182项通过，2项跳过。
- 新增独立安卓 Linux 编译与打包脚本：scripts/bk-remote/android-linux-native.sh、test-android-linux-baseline.ps1、test-android-package-from-linux.ps1。复用已有固定镜像的只读基础层，不改其他项目。工具链、原生依赖与输入归档哈希预检通过。
- 独立运行目录 D:/demo2/bk-remote-toolchains/linux-android-g1-20261127-081711；容器 bk-remote-g1-20261127-081711。安卓开发工具包 r28c 原始下载校验通过，11个目标静态库逐成员架构检查通过。
- 首次 Linux 编译到 hwcodec（硬件编解码）绑定生成阶段失败，退出码101：误用了宿主机 /usr/include/stdint.h。证据保留 native-build.attempt1.log、exit-code.attempt1.txt、android-linux-native.attempt1.sh、SHA256SUMS.attempt1。
- 已显式配置安卓目标系统根目录及绑定生成器目标参数，新增头文件预检；保持原编译缓存、固定依赖和原版硬件编解码，重试前验证输入和锁文件。最终退出码、动态库和完整安装包尚未验收。
- 同步推进独立账号后端：D:/demo2/bk-remote-account，账号安全阶段两轮回归通过（第二轮33主用例、含子用例43项）；完整G3未通过。中继服务端 b80f2d9 未修改。
- 当前不进入正式发布，不修改生产环境。G1 尚未通过，G2 客户端二次开发、G3 完整设备登记、真实双端互控和签名安装包仍待完成。
