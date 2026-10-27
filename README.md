# macOS Input Volume Lock (macOS 麦克风输入音量锁定工具)

[English](#english) | [中文说明](#chinese)

---

<a name="chinese"></a>
## 中文说明

### 解决的痛点问题 (The Problem)

在 Mac 上使用会议或通话软件（如 **腾讯会议、微信语音/视频、Zoom、Google Meet、Microsoft Teams、Discord** 等）时，常常会遇到一个极其烦人的问题：

> **讲话时麦克风输入音量会自动被系统或软件调小，而且再也不会自动调回去！**

这会导致对方听到的声音越来越微弱，直到对方提醒“喂？听不见你说话了”，你才不得不手动打开“系统设置 -> 声音 -> 输入”把滑块拉满。过一会儿，这个滑块又被偷偷压下去了。

### 解决方案 (The Solution)

**`input-volume-lock`** 是一个专为 macOS 设计的轻量级原生音频守护工具：
* **零 CPU 占用**：使用 macOS 原生 `CoreAudio` 事件驱动监听（`AudioObjectAddPropertyListenerBlock`），不是高耗电的轮询脚本。
* **毫秒级极速拉回**：一旦有任何软件或系统算法把麦克风输入音量下调，立即在毫秒内拉回到 **100%**。
* **智能识别内建设备**：默认只锁定 Mac 自带的内建麦克风（`kAudioDeviceTransportTypeBuiltIn`），不会干扰专业外接声卡或 USB 耳麦。
* **静默开机自启**：配置为系统标准的 `LaunchAgent`，开机即在后台静默护航。

---

### 适配机型与系统 (Supported Mac Models & OS)

本工具基于 macOS 底层 CoreAudio 架构开发，全面支持以下机型与架构：

| 类别 | 详细支持范围与实测机型 |
| :--- | :--- |
| **实测通过机型** | • **MacBook Pro 16" (M1 Pro, Model identifier: `MacBookPro18,1`)**<br>• **MacBook Pro (Apple Silicon M5, Darwin 27.x / Kernel arm64 T6050)** |
| **理论全面兼容机型** | • **MacBook Pro** 全系列（Apple Silicon M1 / M2 / M3 / M4 / M5 及 Intel 架构机型）<br>• **MacBook Air** 全系列（M1 / M2 / M3 及 Intel 机型）<br>• **Mac mini / Mac Studio / iMac / Mac Pro** |
| **macOS 系统版本** | macOS Monterey (12.x)、macOS Ventura (13.x)、macOS Sonoma (14.x)、macOS Sequoia (15.x) 及更高版本 |
| **音频通道要求** | 支持任意搭载内建麦克风（Built-in Microphone）的 Mac 设备 |

---

### 快速安装 (Installation)

只需打开 Mac 终端执行以下步骤：

```bash
# 1. 克隆代码仓库
git clone https://github.com/ng-technology-llc/input-volume-lock.git
cd input-volume-lock

# 2. 一键编译并安装（自动配置开机自启）
./install.sh install
```

> **注意**：编译需要系统自带的 Swift 命令行工具。如果从未安装过 Xcode 命令行工具，终端会自动弹出提示，点击“安装”即可，无需完整版 Xcode。

---

### 日常管理命令 (Usage)

在项目目录下，`install.sh` 提供了便捷的管理指令：

```bash
# 查看当前麦克风音量与守护进程运行状态
./install.sh status

# 临时暂停锁定（允许其他软件自由调节音量）
./install.sh pause

# 恢复锁定（重新将麦克风拉回并死锁在 100%）
./install.sh resume

# 彻底卸载（停止服务并清理开机自启配置）
./install.sh uninstall
```

#### 查看运行日志
你可以随时在终端查看锁定日志：
```bash
tail -f ~/Library/Logs/InputVolumeLock.log
```

#### 运行自动化回归测试
```bash
./regression-test.sh
```

---

<a name="english"></a>
## English

A lightweight, zero-CPU background daemon for macOS that automatically prevents meeting software and macOS Auto Gain Control (AGC) from decreasing your microphone input volume.

### Why do you need this?
When using meeting apps on Mac (**Zoom, Microsoft Teams, Google Meet, WeChat, Tencent Meeting, Discord**), macOS or application AGC frequently suppresses the microphone input gain when you speak loudly or background noise occurs. Crucially, **it never restores the input volume back up**, causing other attendees to say "We can barely hear you!".

### Features
* **Zero CPU / Battery Overhead**: Leverages native macOS `CoreAudio` event listener callbacks (`AudioObjectAddPropertyListenerBlock`) instead of polling.
* **Instant Millisecond Restoration**: Restores built-in input volume to 100% the moment any software pulls it down.
* **Smart Device Filter**: Only locks the Mac's built-in microphone (`kAudioDeviceTransportTypeBuiltIn`). External USB audio interfaces and wireless headsets are ignored by default.
* **Clean LaunchAgent**: Runs natively as a standard user-space daemon across reboots.

### Hardware & Model Compatibility
Tested and confirmed on:
* **MacBook Pro 16" (Apple Silicon M1 Pro, Model identifier: `MacBookPro18,1`)**
* **MacBook Pro (Apple Silicon M5, Darwin kernel arm64 T6050)**
* Compatible with all Apple Silicon (M1/M2/M3/M4/M5) and modern Intel Macs running macOS 12 Monterey or later.

### Installation
```bash
git clone https://github.com/ng-technology-llc/input-volume-lock.git
cd input-volume-lock
./install.sh install
```

### License
MIT License. Feel free to use, modify, and distribute.
