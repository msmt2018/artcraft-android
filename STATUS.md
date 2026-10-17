# ArtCraft → Android arm64-v8a：试点移植状态

工作区 `~/artcraft-android/`。目标：把 `github.com/storytold` 的 Craft 系列（纯 Rust + egui/eframe）
移植到 Android arm64-v8a，先打通一个试点，再把方法复制到其余应用。

**试点：GridCraft v0.7.0**（`storytold/gridcraft`，Excel 风格电子表格）。
**第二个目标：craft-launcher v0.4.1**（ArtCraft Launcher，套件启动器）。

上游 commit：`f1894c6da64d4326022ae644c767581816a23c2c`

---

## 0. 一句话结论

GridCraft 的 Android 移植**编译链路已完全打通**：Rust `cdylib` → `libmain.so`(34.7 MB) → APK(31.0 MB)，
0 error、16 KB 页对齐通过、`aapt2` 校验通过。**唯一未完成的环节是真机安装截图——设备处于锁屏，
vivo 会静默丢弃安装，而解锁手势（双指上滑）无法用 adb 合成。见 §6。**

---

## 1. 环境事实（与任务简报不同，已实测修正）

| 项 | 简报说的 | 实测 |
|---|---|---|
| rustup | **没有**，缺 `aarch64-linux-android` std | **本来就有**。默认 toolchain 是 `nightly`(1.91) 且**确实**缺该 target；但 `stable` = **cargo/rustc 1.99.0**，**已经装了 `aarch64-linux-android` std**。→ 全流程只要 `cargo +stable`，**不需要安装任何东西** |
| cargo-ndk | 4.1.2 已装 | ✅ `cargo-ndk 4.1.2` |
| NDK | `~/Library/Android/sdk/ndk/28.2.13676358` | ✅（r28 是 16 KB 页对齐的前提） |
| adb | 未提 | `~/Library/Android/sdk/platform-tools/adb`，**不在非交互 shell 的 PATH 里** |
| gh | 「已以 tzhazuma 登录」 | ✅ 在 `/opt/homebrew/bin/gh`，**也不在 PATH 里** |
| JDK | 未提 | 系统 `java` 是 **27**，AGP 9.1 **会拒绝**。必须 `JAVA_HOME=/opt/homebrew/opt/openjdk@21` |
| Gradle | 未提 | `gradle-9.3.1` 已在 `~/.gradle/wrapper/dists`，**离线可用**，无需下载 |
| python3 | 坏的 | ✅ 确认；脚本里一律 `/usr/bin/python3` |
| 内存 | 未提 | **18 GB，可用常年在 100 MB 量级**。并发 rustc 会 OOM → 见 §4 的构建锁 |

验证命令：

```bash
rustc +stable --print target-libdir --target aarch64-linux-android
# /Users/azuma/.rustup/toolchains/stable-aarch64-apple-darwin/lib/rustlib/aarch64-linux-android/lib
```

---

## 2. 完整可复现步骤

```bash
cd ~/artcraft-android
source scripts/env.sh && artcraft_check_env      # 缺什么会明确报出来

# 1) 上游（浅克隆即可）
mkdir -p src && git clone --depth 1 https://github.com/storytold/gridcraft.git src/gridcraft

# 2) Rust cdylib → apps/gridcraft-android/jniLibs/arm64-v8a/libmain.so
scripts/build-so.sh gridcraft

# 3) Gradle 外壳（模板 + 该 app 的图标集）
scripts/make-shell.sh "$PWD/src/gridcraft" gridcraft-android \
    ai.storyteller.gridcraft GridCraft 0.7.0 gridcraft

# 4) APK → out/GridCraft-0.7.0-android-arm64.apk
scripts/build-apk.sh gridcraft

# 5) 真机（需要设备解锁，见 §6）
scripts/device-smoke.sh ai.storyteller.gridcraft .MainActivity GridCraft
```

`scripts/env.sh` 里 export 的关键变量（不 source 它必然踩坑）：

```bash
export PATH="$HOME/.cargo/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:/opt/homebrew/bin:$PATH"
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/28.2.13676358"
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export CARGO_BUILD_JOBS=4          # 18 GB 内存下的上限
```

---

## 3. 产物与证据

| 产物 | 路径 | 大小 | SHA-256 |
|---|---|---|---|
| Rust 动态库 | `src/gridcraft/apps/gridcraft-android/jniLibs/arm64-v8a/libmain.so` | 34,719,928 B | `9d42492d7e29776cf81382d98c2d5955915d1b8f1c51adabe6ec2121227b5a38` |
| APK | `out/GridCraft-0.7.0-android-arm64.apk` | 31,046,808 B | `e2844f5c4ae92cac595fe139be586e13af2662715cf23afb7bdde055f11a431a` |

```
$ cargo +stable ndk -t arm64-v8a build --release -p gridcraft-android
== cargo exit code: 0
== artifact: .../libmain.so (34719928 bytes)          # 0 error, 0 warning

$ aapt2 dump badging out/GridCraft-0.7.0-android-arm64.apk
package: name='ai.storyteller.gridcraft' versionCode='1' versionName='0.7.0' ...
targetSdkVersion:'35'
application-label:'GridCraft'
launchable-activity: name='ai.storyteller.gridcraft.MainActivity'
native-code: 'arm64-v8a'
application-icon-480:'res/BW.xml'                      # 矢量 adaptive icon

$ zipalign -c -P 16 -v 4 out/GridCraft-0.7.0-android-arm64.apk
== zipalign -P 16: OK (16 KB page aligned)

$ llvm-readelf -lW libmain.so | grep LOAD
  LOAD 0x000000  0x0000000000000000 ... 0x66ddb0  R   0x4000
  LOAD 0x66ddb0  0x0000000000671db0 ... 0x108c150 R E 0x4000
  LOAD 0x16f9f00 0x0000000001701f00 ... 0x0b3988  RW  0x4000
  LOAD 0x17ad890 0x00000000017b9890 ... 0x001d20  RW  0x4000
```

---

## 4. 方法：加一个平台 crate，不动上游

上游已经为多平台准备好像素的抽象缝——每个 app 都有 `apps/<app>-web`（WASM），所以代码本身平台
抽象是干净的。移植照抄这个先例：**新建一个 L6 app crate**，复用 engine + ui-egui，只补平台壳。

```
ports/gridcraft-android/          ← 移植源码（source of truth）
  Cargo.toml                      [lib] name="main" crate-type=["cdylib"]
  src/lib.rs                      android_main + TouchShell + 字体 + 偏好
  README.md                       集成步骤 + 已知缺口
```

`build-so.sh` 每次构建前把 `ports/<pkg>/` **rsync 覆盖**进克隆的 `apps/<pkg>/`，所以移植源码永远
是权威，克隆里手改的东西不会静默生效。

### 关键实现点

1. **入口**（edition 2024 下 `#[no_mangle]` 必须写成 `#[unsafe(no_mangle)]`）：

```rust
#[allow(unsafe_code)]                       // 上游 workspace 是 unsafe_code="forbid"，
#[unsafe(no_mangle)]                        // 本 crate 用 deny + 入口处 allow，
fn android_main(app: AndroidApp) {          // 与 crates/platform 的既有先例一致
    let options = eframe::NativeOptions { android_app: Some(app), ..Default::default() };
    eframe::run_native("GridCraft", options, Box::new(|cc| Ok(Box::new(TouchShell::new(...))))).unwrap();
}
```

2. **eframe features 必须按目标拆分**：
   `["default_fonts","wgpu","android-game-activity"]`
   - `accesskit` + `android-native-activity` 是 eframe 的硬 `compile_error!`；
   - NativeActivity 没有软键盘/IME，ribbon + 公式栏这种要打字的 app **必须 GameActivity**。
   - 不要直接依赖 `android-activity`，用 winit 再导出的
     `winit::platform::android::activity::AndroidApp`。

3. **Gradle 外壳**：`templates/android-shell/`（AGP 9.1.0 / Gradle 9.3.1 / JDK 21 / minSdk 31 /
   compileSdk 35）。`app/build.gradle` 的 `jniLibs.srcDirs = ['../../jniLibs']` 指向 `cargo ndk -o`
   的输出目录。release 用 **debug 签名**，这样 release APK 能直接 `adb install`。
   `MainActivity extends GameActivity` + `static { System.loadLibrary("main"); }`，
   manifest 里 `android.app.lib_name = "main"` 必须与 `[lib] name = "main"` 一致。

4. **构建锁**（本机特有）：18 GB 内存 + 多个 agent 并发 cargo 会 OOM。`scripts/build-lock.sh`
   用 `/usr/bin/python3` 的 `fcntl.flock`（macOS 没有 `flock(1)`）把整机构建串行化，并配
   `CARGO_BUILD_JOBS=4`。

5. **剥掉构建机身份**：`RUSTFLAGS="--remap-path-prefix=$HOME=/build --remap-path-prefix=<clone>=/src"`。
   不加的话 rustc 会把 `/Users/azuma/...` 的 panic 路径烧进二进制，任何人 `strings libmain.so`
   都能看到（实测每包 632–1221 处）。

---

## 5. 踩坑清单

| # | 坑 | 现象 | 处理 |
|---|---|---|---|
| 1 | 默认 toolchain 是 nightly | `cargo build --target aarch64-linux-android` 报找不到 std | 全程 `cargo +stable` |
| 2 | 系统 java 是 27 | AGP 9.1 直接拒绝 | `JAVA_HOME=/opt/homebrew/opt/openjdk@21` |
| 3 | adb / gh 不在 PATH | `command not found` | 脚本显式 export |
| 4 | `bash -c "..."` 里嵌引号 | 外层展开把 PATH 搅坏，连 `cc` 都找不到 | 构建脚本用 **quoted heredoc + 占位符 + sed** 生成，绝不用 `bash -c` 传命令串 |
| 5 | 管道吃掉退出码 | `cargo ... \| tail` 让失败看起来成功 | 绝不把构建管道进 `tail`；`build-so.sh` 自己 `exit $rc` |
| 6 | `/sdcard` 安装 | SELinux 拒绝：system_server 读不了 fuse | `adb push` 到 **`/data/local/tmp/`** 再 `pm install -r -t` |
| 7 | 锁屏时安装 | `pm install` **无任何输出**，`lastUpdateTime` 不变，静默丢弃 | 装前查 `dumpsys window \| grep mDreamingLockscreen`；见 §6 |
| 8 | 无线调试端口漂移 | `adb devices` 空 | 先试 `<IP>:5555`（经典 adbd 端口，本会话两次救场），再 `adb mdns services \| grep _adb-tls-connect` |
| 9 | 大 APK 走无线 adb | `adb install` 永久挂住（包其实已装上） | 所有 adb 调用加 `timeout`；超时后改用「查包名是否存在」判定 |
| 10 | `mipmap-*dpi/*.webp` 继承自别的 app | 非 FilmCraft 的 app 显示 FilmCraft 图标 | 模板不带图标；每个 app 装自己的矢量集 |
| 11 | egui 默认字体无 CJK | 中文渲染成方块 | 运行时挂 `/system/fonts/NotoSansCJK-Regular.ttc` 到 family 末尾 |
| 12 | `dirs` 在 Android 返回 `None` | `Paths::new()` 掉进 `temp_dir()`（Android app 写不了 `/tmp`） | 需给 native crate 加 host 注入 data root 的口子（launcher 部分待做） |

---

## 6. 阻塞项：真机锁屏（需要人类）

设备 **vivo PA2573 / Android 16 / arm64-v8a**，`10.20.102.152:5555`。

```
$ adb -s 10.20.102.152:5555 shell dumpsys window | grep mDreamingLockscreen
    mShowingDream=false mDreamingLockscreen=true
$ adb -s 10.20.102.152:5555 shell dumpsys power | grep mWakefulness=
  mWakefulness=Asleep
```

- vivo 在**锁屏**时会**静默丢弃** `pm install`（无输出、`lastUpdateTime` 不变），所以装不上。
- 解锁手势是**双指上滑**，`adb shell input swipe` 合成不出来。
- `input keyevent KEYCODE_WAKEUP` 只能把 `mWakefulness` 变成 `Awake`，锁屏依旧在。

**请人类解锁手机并保持亮屏**，然后：

```bash
cd ~/artcraft-android
scripts/device-smoke.sh ai.storyteller.gridcraft .MainActivity GridCraft gridcraft-real
# 期望：PASS: launched, no crash / PASS: activity is focused
#       shots/gridcraft-real.png
```

`device-smoke.sh` 检测到锁屏会**直接报「HUMAN ACTION REQUIRED」并 exit 5**，不会空转重试。

旁证：设备上已装有 `ai.storyteller.{filmcraft,lightcraft,photocraft,effectcraft,printcraft}`
五个包，说明「push → pm install」这条路在本机是走通过的。

---

## 7. 还没做的 / 已知缺口

### GridCraft 首版缺的
- **文件打开/保存**：`rfd` 没有 Android 后端，`Services` 的 `pick_open`/`pick_save`/`pick_picture`
  全是 `None`。UI 对 `None` 有降级路径（不崩，只是选择器不可用）。要真可用得写 SAF 桥
  （`ACTION_OPEN_DOCUMENT` / `ACTION_CREATE_DOCUMENT`）。
- **剪贴板**：`arboard` 无 Android 后端；跨应用粘贴需要 JNI 调 `ClipboardManager`。
- **触屏布局**：ribbon 是按鼠标设计的。`TouchShell` 只把命中目标放大到 40 pt（
  `interact_size = 40×40`、`show_tooltips_only_when_still = true`）；真正的触控布局是产品级工作量。
- **中文界面**：CJK **字形**已回退，中文单元格能正常显示；界面语言仍是英文。

### craft-launcher（进行中）
已实测 **编译**通过（`cargo +stable ndk check --target aarch64-linux-android`，0 error）：
- `artcraft-launcher-ui-egui` —— 真正的启动器 egui UI
- `artcraft-launcher-native` —— 真正的下载/安装后端（含 ureq + rustls）

剩余运行时问题：
1. **`rustls-platform-verifier 0.7.1` 在 Android 需要额外 Kotlin 组件**，并且要从 GitHub Packages
   拉 Maven 包（`org.rustls:rustls-platform-verifier-android`），需要 token。**绕开方案**：改
   `crates/native/src/http.rs` 里唯一那处 `RootCerts::PlatformVerifier`，Android 上改成
   `RootCerts::new_with_certs(...)` 读系统 CA 目录——设备上实测有 **149 个**
   `/system/etc/security/cacerts/*.0`。仍然是「OS 决定信任什么」，且不引入新的 Gradle/Maven 依赖。
2. **`dirs` 在 Android 返回 `None`** → `Paths::new()` 需要 host 注入 data root
   （`AndroidApp::internal_data_path()`）。
3. 桌面壳的 `notify-rust` / `rfd` / `tray-icon` / `zbus` / `single_instance` 在 Android 上要
   么 cfg 掉、要么换成 Android 等价物（通知、SAF、Intent）。**注意**：因为移植是**新建 crate**
   而不是改 `apps/artcraft-launcher`，这些依赖根本不会被引入，桌面 app crate 一行都不用动。
4. `single_instance` 用 loopback TCP 47413 端口做单实例握手——Android 沙盒内可用，无需改。

### 其他
- 每个移植要**独立 GitHub 仓库**并带 release（见 §8）。
- craft-launcher 的下载地址要指向我们自己的 release（见 §9）。

---

## 8. 仓库与发布

命名跟已有惯例（`tzhazuma/freecad-android`、`blender-android`、`octave-android`、`dsh-android`）：

| 仓库 | 内容 |
|---|---|
| `tzhazuma/gridcraft-android` | GridCraft 的 Android 移植（port crate + 脚本 + STATUS） |
| `tzhazuma/craft-launcher-android` | ArtCraft Launcher 的 Android 移植 |

APK 走 **GitHub Releases**，不进 git 历史（31 MB 二进制）。

---

## 9. craft-launcher 的下载地址

启动器的下载 URL 由 `crates/core/src/catalog.rs` 里每个 app 的 `repo` 字段决定：

```
crates/core/src/release.rs:65   format!("https://github.com/{repo}/releases/download/")
crates/core/src/feed.rs:191     format!("https://github.com/{repo}/releases/")
```

所以「指向我们自己移植的 GitHub 下载链接」= 把 release 查询的 repo 从 `storytold/<app>`
换成 `tzhazuma/<app>-android`，同时**保留** `repo_url()` / `website()` 指向上游（文档/官网链接
不该被改）。做法与验证见 `docs/LAUNCHER-DOWNLOAD-URLS.md`。

---

## 10. 目录结构

```
~/artcraft-android/
├── STATUS.md                  ← 本文件
├── README.md
├── scripts/
│   ├── env.sh                 共享环境（PATH/NDK/JDK/lock/设备）
│   ├── build-lock.sh          整机构建串行化（fcntl）
│   ├── build-so.sh            <app> → libmain.so
│   ├── build-apk.sh           <app> → out/<Label>-<ver>-android-arm64.apk
│   ├── make-shell.sh          生成 Gradle 外壳 + 装该 app 的图标
│   └── device-smoke.sh        装机/启动/logcat/截图（含锁屏门禁）
├── templates/android-shell/   Gradle 骨架（AGP 9.1.0 / Gradle 9.3.1 / JDK 21）
├── icons/<app>/res/           每个 app 的矢量 adaptive icon（来自 icon-designer）
├── ports/<app>-android/       移植源码（source of truth）
├── src/<app>/                 上游浅克隆（.gitignore 掉）
├── out/                       APK
├── shots/                     真机截图
└── logs/                      构建日志
```

---

## 第 48 轮：13 个 APK 全部就位；6 个新 app 在模拟器上装机验证

### release 清单（13 个资产，全部 zipalign -P 16 通过）

| APK | 大小 |
|---|---|
| ArtCraftLauncher-0.4.1 | 22 MB |
| CADCraft | 30 MB |
| DeckCraft | 44 MB |
| DesignCraft | 65 MB |
| EffectCraft-0.4.0 | 65 MB |
| FigCraft | 47 MB |
| FilmCraft-0.2.1 | 42 MB |
| GridCraft-0.7.0 | 29 MB |
| LightCraft-0.2.1 | 33 MB |
| PhotoCraft-0.3.0 | 44 MB |
| PrintCraft-0.2.1 | 47 MB |
| SoundCraft | 27 MB |
| WordCraft | 55 MB |

### 模拟器装机验证（emulator-5554 / API 36）

**注意：真机当时锁屏，vivo 会静默丢弃安装，所以这批验证是在模拟器上做的。**

6 个新 APK 全部 `pm install` → `Success`，13 个 storyteller 包全部在设备上。
逐个冷启动 12 秒后看进程是否存活：

| app | 结果 |
|---|---|
| DesignCraft | ✅ 存活 pid=4993 |
| WordCraft | ✅ 存活 pid=5093 |
| DeckCraft | ✅ 存活 pid=5141 |
| CADCraft | ✅ 存活 pid=5178 |
| **SoundCraft** | ✅ **存活 pid=5233**（cpal/AAudio 那条链真的能跑） |
| FigCraft | ❌ `Process ... failed to attach` |

**FigCraft 的失败形态与其他都不同**：进程确实起来了（pid=5286），
但日志是 `W ActivityManager: Process ... failed to attach`，且
`SurfaceSyncGroup: Failed to receive transaction ready in 1000ms`。
没有 FATAL / SIGSEGV，所以不是崩溃 —— 更像是**初始化耗时超过 splash 窗口**
导致 attach 超时。下一步该看它启动时卡在哪一步（可能和它比别的 app 多做
collab-net / layout 初始化有关）。

### SoundCraft 的教训（已单独提交）

`ld.lld: error: unable to find library -laaudio` 的根因不是 oboe，是
**cargo-ndk 用了 Rust target triple 里的 API 级别（android24）**，而 AAudio 从
API 26 才有。Gradle 的 minSdk 是 31，原生侧却按更低级别构建。
修法：`cargo +stable ndk -t arm64-v8a -P 31 ...`（**`-P` 大写** = --platform；
小写 `-p` 是 --package，传数字会 panic）。

---

## 第 49 轮：FigCraft 的「attach 超时」其实是模拟器的 SwiftShader 限制

上一轮我把它记成「初始化超出 splash 窗口」。拿到完整日志后，真实原因完全不同：

```
I FigCraft: egui_wgpu: There are 2 available wgpu adapters:
            {backend: Vulkan, device_type: Cpu, name: "SwiftShader Device (LLVM 10.0.0)"}
W FigCraft: wgpu_hal::gles::egl: Error in create_window_surface: BadAlloc
I RustStdoutStderr: thread '<unnamed>' (5389) panicked at wgpu-30.0.1/src/backend/wgpu_core.rs:3981:
I RustStdoutStderr: wgpu error: Validation Error
I RustStdoutStderr: Caused by:
I RustStdoutStderr:   In Surface::configure
I RustStdoutStderr:     Invalid surface
```

**不是崩溃，也不是初始化慢，是 `create_window_surface` 拿不到 GPU surface。**
模拟器只有 SwiftShader 软件渲染（`device_type: Cpu`），`BadAlloc` 就是分配失败。
wgpu 默认把这类错误当 fatal，于是 panic，进程随后被 ActivityManager 回收，
表面现象就成了 `Process ... failed to attach`。

### 两台设备的 GPU 对比（实测）

```
模拟器 emulator-5554 (API 36):
  wgpu 选到: SwiftShader Device (LLVM 10.0.0), device_type = Cpu
  create_window_surface -> BadAlloc

真机 vivo PA2573 (Android 16 / arm64-v8a):
  GLES: ARM, Mali-G925-Immortalis MC12, OpenGL ES 3.2
  vulkan_renderengine: false
```

真机有真实 GPU，FigCraft 在上面**应该正常** —— 但这台真机当时锁屏，
vivo 会拒绝安装（`INSTALL_FAILED_ABORTED: User rejected permissions`），
所以这一项还没能验证。

### 结论与后续

1. **FigCraft 的 APK 本身没有问题**（`zipalign` / `aapt2` / 链接都过了，
   编译 0 error），失败只发生在软件渲染的模拟器上。
2. 要验证它必须用真机（或带 GPU 加速的模拟器）。
3. 如果确实需要在模拟器上跑，可给 wgpu 设
   `WGPU_BACKEND=gl` 或降级 adapter 选择，但那只是让 CI 能截图，
   不代表真实表现。

**这是我之前误判的一次，记下来**：`failed to attach` 这种系统层的间接症状，
一定要先看应用自己的日志再做归因。

---

## 第 50 轮：SAF 桥接补齐后，FilmCraft 重装并跑到自检

### 发现了什么

`saf.rs` 一直在 `patches/filmcraft-android/src/` 里，它调用 Activity 上的六个方法：

```
safPickMedia()V   safIsDone()Z      safPickSave(String)V
safSaveDone()Z    safHasSaveUri()Z  safPublish(String)Z
```

**这六个方法一个都不存在。** 整个工程里没有任何 `.java` / `.kt` 文件 ——
manifest 里的 `.MainActivity` 解析到的是 `androidx.games:games-activity`
依赖自带的 `GameActivity`，桥接从来没实现。

后果是静默的：`saf.rs` 的 `call()` 返回 `Option`，上层 `unwrap_or(false)`
把「Java 方法不存在」变成了「用户取消了」，于是文件对话框什么都不做、也不报错。
这正是「打开关闭文件有问题」的真相。

### 补了什么

`MainActivity.java`（271 行），继承 `com.google.androidgamesdk.GameActivity`：

| 能力 | 实现 |
|---|---|
| 导入 | `ACTION_OPEN_DOCUMENT` + `EXTRA_ALLOW_MULTIPLE`；每个 `content://`
文档拷到 `filesDir/import/`，真实路径逐行写入 `filesDir/import-manifest.txt`
（Rust 侧本来就在轮询这个文件） |
| 保存 | `ACTION_CREATE_DOCUMENT`；URI 留在 Java 侧，`safPublish` 用
`openOutputStream` 流式写入 |
| 权限 | 两条路径都 `takePersistableUriPermission`，用 try/catch 包住 ——
provider 不支持持久授权时退回一次性授权，而不是抛异常 |
| 取消 | 写**空** manifest 而不是留着上一次的，避免「取消导入」反而重导上次的文件 |
| 重名 | 加 ` (2)` 后缀而不是覆盖 —— 从不同文件夹选两个同名文件是正常操作 |

已推广到 FilmCraft / LightCraft / PhotoCraft / EffectCraft / PrintCraft 五个 app。

### 验证到哪一步了

FilmCraft 重新构建（42.4 MB，`classes.dex` 存在，
`aapt2` 报 `launchable-activity ai.storyteller.filmcraft.MainActivity`），
装到 emulator-5554 并启动。日志显示**媒体自检真的跑通了**：

```
I main: filmcraft-android: H.264 自检: 解码器 MediaCodec H.264 | 样本 30 个
        → 解出 30 帧（320x240）| 硬件计数 帧 30 会话 1 拒绝 0 回退 0
W filmcraft_platform::hybrid: MediaCodec HEVC failed (decode error);
        continuing with the software decoder
```

HEVC 在模拟器上硬件解码失败但正确回退到软件解码器 —— 这个回退路径也是对的。

**还没验证的**：SAF 选择器本身。FilmCraft 跑完自检后 Activity 收到 `CLOSE`
（`Transition type = CLOSE`），窗口关闭、进程被 freeze，所以没法接着去点
「打开」按钮。要点的话得先让它进入正常编辑界面（有项目可开时），
或者用坐标点击。egui 渲染在 SurfaceView 里没有可访问性树，
`uiautomator dump` 拿不到它的控件，只能靠看截图算坐标。

### 待办

1. **7 个新 craft app 的 SAF**：VectorCraft / FigCraft / DesignCraft / WordCraft /
   DeckCraft / CadCraft / SoundCraft 连 `saf.rs` 都还没有。它们的 `Services`
   目前是 `Default`（即「未接文件对话框」），需要按 filmcraft 的模式补
   Rust 侧 + Java 侧。
2. **SAF 端到端**：需要在能进编辑界面的前提下点一次「打开」，看系统选择器是否弹出。
3. **Blender SAF**：打开/导入/导出/输出三条路径，工程量在 `BKE_file`/`BLI_file`
   只认 POSIX 路径。

### 教训

**静默失败比崩溃难查得多。** 跨语言桥接的代码，必须逐项确认对端真的存在 ——
`find . -name "*.java"` 这种一眼可见的检查，应该在写 `saf.rs` 那次就做，
而不是等到用户反馈「文件打不开」才回头查。

---

## 第 51 轮：7 个新 app 补齐 SAF 双半；VectorCraft 重建验证

### 补齐了什么

7 个新 app 之前既没有 `saf.rs` 也没有 Java。现在各自都有：
- `src/saf.rs`（Rust 侧 JNI 桥）
- `MainActivity.java`（271 行，继承 `com.google.androidgamesdk.GameActivity`）
- `Cargo.toml` 里的 `jni = "0.22"` + `ndk-context = "0.1"`
- `lib.rs` 里的 `mod saf;`
- `AndroidManifest.xml` 改成完整类名

全部 `cargo +stable ndk check` → **0 error**。

### 一个错位造成 15 个错误

第一次用 `sed '3a mod saf;'` 把 `mod saf;` 插到了第 3 行 —— **在模块级 `//!` 文档注释上面**：

```
error[E0753]: expected outer doc comment
  --> src/lib.rs:5:1
```

Rust 不允许 `//!` 出现在非注释项之后。每个 app 15 个错误，全部来自这一行错位。
正确位置是 `//!` 块之后、`#![...]` 内部属性之后。

### VectorCraft 重建验证

```
cargo +stable ndk ... build --release   →  libmain.so 89.0 MB
gradlew assembleRelease                 →  APK 79.6 MB
classes.dex: 1                          （Java 侧确实编进去了）
aapt2: launchable-activity ai.storyteller.vectorcraft.MainActivity
zipalign -c -P 16: PASS
```

### 还差什么

**接线**。`saf.rs` 和 `MainActivity.java` 都在，但 `Services` 仍然是 `Default`
（`services() { Services::default() }`），所以**没有任何代码调用 `saf::pick_media`**。
点「打开」仍然没反应。

接线需要的三块，本轮的探测已经确认都具备：
1. `activity` = `AndroidApp::activity_as_ptr()`
2. `data_dir` = `AndroidApp::internal_data_path()`
3. 回灌路径用的 control 通道 —— 7 个 app 都有（`ControlRequest` / `control_server`）

难点：`PickOpen = Box<dyn FnMut(&FilePick) -> Option<String>>` 是**同步**的，
在 UI 线程调用。SAF 选择器是异步的（Java 起 Intent，Rust 侧轮询 250ms）。
FilmCraft 的解法是返回 `None` 立刻返回、后台线程跑完再把路径经 `ControlRequest`
回灌，让引擎执行**正常的** open 命令。

**我没有只接一半**，因为那样比不接更糟：用户点了「打开」、系统选择器弹出来、
选完文件，然后什么都没发生。要做就做完整的那条回路。

每个 app 的 `ControlRequest` 形状都不同，所以这是逐个的活，不是机械复制。

---

## 第 52 轮：SAF 第一次真正接线（VectorCraft 作为示范）

前几轮把两半都补齐了（`saf.rs` + `MainActivity.java`），但 `services()` 一直是
`Services::default()`，所以没有任何代码调用 `saf::pick_media`。这轮把回路接上了。

### 接线的形状

难点在于两边的时序不匹配：

- `PickOpen = Box<dyn FnMut(&FilePick) -> Option<String>>` —— **同步**，在 UI 线程调用
- SAF 选择器 —— **异步**（Java 起 Intent，Rust 侧每 250ms 轮询一次标志）

如果 `pick_open` 里阻塞等选择器，整帧就冻住了。所以：

```rust
services.pick_open = Some(Box::new(move |_pick: &FilePick| {
    let Some(dir) = open_dir.clone() else { return None };
    let ctrl = open_ctrl.clone();
    std::thread::spawn(move || {
        let paths = saf::pick_media(activity, &dir, Duration::from_secs(300));
        let Some(path) = paths.into_iter().next() else { return };
        let (req, _rx) = ControlRequest::new("app.open", json!({ "path": path }));
        let _ = ctrl.send(req);
    });
    None   // 选择器已经弹出去了，这一帧继续渲染
}));
```

配套改动：
1. `android_main` 里建 `mpsc::channel::<ControlRequest>()`
2. `app.activity_as_ptr() as usize` 拿 Activity 指针（在 `app` 被 move 进
   `NativeOptions` 之前）
3. `VectorcraftApp::new(...).with_control(ctrl_rx)` —— app 每帧从通道里取请求执行
4. 回灌的 `app.open` 走的是**桌面同款**命令（`control.rs` 里本就映射到
   `file.open`），所以打开路径完全一致

`cargo +stable ndk check` → **0 error**；APK 79.6 MB 重建、装机、启动（pid 6171）。

### `pick_save` 故意没接

保存走的是「应用自己的 export 目录 + SAF 发布」两段式（FilmCraft 的模型：
先写到临时文件，`safPublish` 再搬到用户选的位置）。VectorCraft 的 export
目录和临时文件流程我还没查清，所以 `pick_save` 只是记一条日志并返回 `None`，
**没有假装能用**。

### 其余 6 个 app

接线模式完全一样，但每个 app 的 `ControlRequest` 方法名和 `Services` 字段
需要各自确认（VectorCraft 是 `app.open` + `pick_open`）。逐个做，不批量 sed ——
批量改跨语言回调是最容易留下静默失败的方式。

---

## 第 53 轮：SAF 接线扩展到另外 3 个 app

### 每个 app 的 `Services` 签名都不同

这是本轮最花时间的部分 —— 同一个 `pick_open`，六个 app 四种签名：

| app | `pick_open` 类型 |
|---|---|
| VectorCraft | `Box<dyn FnMut(&FilePick) -> Option<String>>`（`FilePick` 是结构体） |
| **designcraft / deckcraft** | `Box<dyn FnMut(&str) -> Option<String>>`（purpose 字符串） |
| **cadcraft** | `Box<dyn Fn() -> Option<String>>`（无参数） |
| wordcraft / soundcraft | 有 `pick_open`，但 control 里没有 `app.open` |
| figcraft | `Services` 是 **trait**，设计不同 |

我先按 VectorCraft 的形状写了一版通用接线脚本，然后被 `error[E0425]: cannot find
type FilePick` 一次性打回三个 app。查明后按各自签名重写，全部 0 error。

### 接好的三个

```rust
services.pick_open = Some(Box::new(move |_purpose: &str| {
    let Some(dir) = open_dir.clone() else { return None };
    let ctrl = open_ctrl.clone();
    std::thread::spawn(move || {
        let paths = saf::pick_media(activity, &dir, Duration::from_secs(300));
        let Some(path) = paths.into_iter().next() else { return };
        let (req, _rx) = ControlRequest::new("app.open", json!({ "path": path }));
        let _ = ctrl.send(req);
    });
    None
}));
```

designcraft / deckcraft / cadcraft 三个 `cargo +stable ndk check` → **0 error**。

### 进度

| app | SAF 双半 | 接线 |
|---|---|---|
| VectorCraft | ✅ | ✅ |
| **DesignCraft** | ✅ | ✅ **本轮** |
| **DeckCraft** | ✅ | ✅ **本轮** |
| **CadCraft** | ✅ | ✅ **本轮** |
| WordCraft | ✅ | ❌ 缺 `app.open` 方法名 |
| SoundCraft | ✅ | ❌ 缺 `app.open` 方法名 |
| FigCraft | ✅ | ❌ `Services` 是 trait，设计不同 |
| FilmCraft/LightCraft/PhotoCraft/EffectCraft/PrintCraft | ✅ | ✅（老 app 已接） |

### 教训

**「同一个接口」在跨 6 个代码库时并不存在。** `pick_open` 这个名字一样，
类型却四种。批量 sed 在这里一定会失败 —— 而且失败方式很危险：
如果签名恰好兼容但语义不同，就会编过、跑错、静默失败。
必须逐个看真实的类型定义。
