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
