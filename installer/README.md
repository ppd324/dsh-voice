# DSH Voice — 打包与安装

把"语音控制电脑"这一层分发给别人。

## 目录

```
voice/
├── installer/
│   ├── install-voice.ps1      # 安装器(自动探测 + 模型下载 + profile + 插件 + 自启)
│   ├── build-package.ps1      # 打包:生成 dist/DSHVoice-<ver>.zip(有 Inno 时生成 setup.exe)
│   ├── DSHVoice.iss           # Inno Setup 脚本(单文件 exe 安装包)
│   └── voice-profile/         # 可移植 profile 模板(headless + 账号 + 桌面控制 + 全权限)
└── first-run.ps1              # 首次运行向导(电平 + 识别 + 朗读)
```

## 构建分发包

```powershell
pwsh -File installer/build-package.ps1
# 产出 dist/DSHVoice-0.1.0.zip(约 38MB,含 ffmpeg)

# 想做成离线包(把 228MB 模型一起打进去)
pwsh -File installer/build-package.ps1 -WithModels

# 如果装了 Inno Setup 6,同一个脚本会自动再产出 dist/DSHVoice-Setup-0.1.0.exe
winget install JRSoftware.InnoSetup
```

## 对方怎么装

1. 装好 **DeepSeek Harness Desktop** 并登录
2. 解压 ZIP,双击 `install.cmd`
3. 按提示跑一次 `first-run.ps1`(也可以从开始菜单打开)
4. 说 **「你好电脑」**

`install.cmd` 会优先用 `pwsh`,没有再退回 `powershell`。

## 安装器做了什么

| 步骤 | 内容 |
|---|---|
| 探测 | DSH 安装路径、Python、ffmpeg、既有 profile |
| 复制 | 语音层 → `%LOCALAPPDATA%\DSHVoice` |
| 配置 | 写入 `config.json`(路径全部按本机探测结果重写) |
| 模型 | 三个文件按 SHA256 + 大小校验下载,hf-mirror 优先、HF 兜底 |
| Profile | 从模板创建 `~/.dsh/profiles/voice` |
| 插件 | 用 DSH 自带 pnpm 安装 `dsh-windows-mcp`,并写 bridge 行 |
| 语音 | 用 DSH 的 Python 安装 `edge-tts` |
| 自启 | 写三条 HKCU Run:守护进程+球、看门狗、DSH 本身 |

`-Check` 只体检不改动;`-SkipModels` / `-SkipStart` / `-InPlace` 用于特殊场景。

## 首次运行向导

```
1/2  Say the wake word out loud now. Recording for 5 seconds...
     >>> 你好电脑 <<<
     peak = -25.3 dBFS
  OK   level is healthy
  OK   recognized: 你好，电脑。
2/2  Voice output
  OK   neural voice played
```

判定阈值(峰值,已含 +20dB 增益):

| 峰值 | 结论 |
|---|---|
| < -40 dB | 基本静音:选错设备或麦克风被静音 |
| -40 ~ -30 | 太小声:靠近麦克风或调高输入音量 |
| -30 ~ -18 | 可用但偏轻 |
| ≥ -18 | 正常 |

## 无法自动化的部分

| 项 | 原因 |
|---|---|
| 安装 DSH Desktop | 别人的产品 |
| 登录 DSH 账号 | 必须本人扫码/登录 |
| 首次装 Windows-MCP 依赖 | 需要联网下载 uv + Python 环境(DSH 插件页一次点击) |

## 已知限制

- 仅 Windows 10/11 x64
- 未签名:SmartScreen 会提示,需右键"解除锁定"或加信任
- 安装器假设 DSH 的 `resources\app.asar\dsh` 布局(0.2.2-rc.x 验证过);DSH 大版本升级后需复核 profile 配置键
- 识别为本地 CPU 推理,常驻约 450MB 内存
- 首次运行需要下载 228MB 模型(除非用 `-WithModels` 打离线包)

## 系统音频检测(避免外放被当成唤醒)

守护进程通过 CoreAudio 峰值表判断扬声器是否在出声;正在播放视频/音乐时自动暂停唤醒检测。

| 配置 | 默认 | 说明 |
|---|---|---|
| `muteWhenSystemAudio` | true | 是否启用该保护 |
| `systemAudioThreshold` | 0.03 | 峰值阈值(0~1),越高越容易判为"安静" |
| `followUpMs` | 0 | 回答后免唤醒窗口;0 表示每次都需唤醒词 |
| `wakeLeadChars` | 2 | 唤醒词前允许的杂字数量 |
| `allowBareWake` | false | 是否允许只喊"电脑" |
