# Vocalocal

**按住 Fn 说话，松开即输入。** 一个完全在本机运行的 macOS 语音输入法：识别、纠错都用本地大模型，不联网、不限额度，录音和屏幕内容不离开你的 Mac。

- 🎙 **本地语音识别**：Qwen3-ASR 1.7B（MLX），中英混说准确，识别一句约 0.2 秒
- 🖥 **读懂屏幕上下文**：自动读取当前窗口文字（辅助功能 / OCR），把里面的术语当作识别热词——屏幕上有 `Ollama`，你说"欧拉玛"就会打出 Ollama
- 👂 **听着录音纠错**：Qwen3-Omni 对照原始录音和屏幕上下文，只修正听错的词，不改写、不"回答"你说的话
- ⌨️ **任意输入框**：剪贴板 + ⌘V 写入，写完恢复原剪贴板；支持 Dvorak 等键盘布局

## 用法

| 操作 | 效果 |
|---|---|
| 按住 Fn 说话，松开 | 识别 → 纠错 → 输入到当前光标位置 |
| 双击 Fn | 免按住模式（橙色圆点），再按一次 Fn 结束 |
| 录音中按 Esc / Fn+其它键 | 取消 |
| 先选中一段文字再说话 | 语音作为改写指令（"翻译成英文""改正式一点"），结果替换选中内容 |

> 系统设置 → 键盘 →"按下 🌐 键时"请改为 **"无操作"**，否则会同时弹出表情面板或系统听写。

## 工作原理

```
按下 Fn ──┬─ 录音（系统降噪 / 回声消除）
          └─ 后台读取屏幕：辅助功能读窗口文字，读不到时截图 OCR → 提取术语
松开 Fn ──→ Qwen3-ASR（热词 = 词汇表 + 屏幕术语）→ 初稿
          → Qwen3-Omni 听录音 + 看初稿和屏幕 → 只输出 {from, to} 修改列表
          → 客户端逐条校验（只许改短词、只许删语气词、总改动 ≤ 40%）→ 套用
          → 剪贴板 + ⌘V 输入
```

为什么纠错只允许输出"修改列表"：评测中让模型整句重写时，它会**回答**录音里的问题（"写一首诗"真的写了一首）或改写过度；限制为"把哪个词改成哪个词"后，这两类问题都不再出现。

## 评测（M5 Pro，本机运行）

识别（9 句，含中英混说和"陷阱句"）：

| 方案 | 字错率 | 全对 | 耗时 |
|---|---|---|---|
| **Qwen3-ASR + 词汇表** | **1.0%** | 8/9 | 0.22 s |
| Qwen3-ASR | 3.7% | 6/9 | 0.22 s |
| macOS SpeechAnalyzer（新版） | 7.7% | 4/9 | 0.13 s |
| macOS SFSpeechRecognizer（旧版） | 17.1% | 3/9 | 0.22 s |
| Qwen3-Omni 一步出结果 | 21.6% | 8/9 | 0.52 s，但会"回答问题" ⚠️ |

纠错（12 句真实录音初稿）：

| 方案 | 字错率 | 全对 | 内存 |
|---|---|---|---|
| 不纠错 | 6.7% | 4/12 | — |
| **Qwen3-Omni 听录音纠错** | **3.7%** | **8/12** | 约 21 GB |
| 纯文本 LLM + 拼音（qwen2.5:7b） | 6.3% | 4/12 | 5.7 GB |

评测脚本在 [`bench/`](bench)：`make_audio.sh` 生成测试音频，`qwen_bench.py` / `two_step.py` / `omni_bench.py` / `corrector_bench.py` 跑各方案，`summarize.py` 汇总。

## 安装

需要 Apple Silicon、macOS 14+、Xcode Command Line Tools、[uv](https://github.com/astral-sh/uv)。

```bash
git clone https://github.com/eggfly/Vocalocal.git && cd Vocalocal
./server/setup.sh          # 创建虚拟环境并下载模型；只要识别可用 ./server/setup.sh asr
./server/install.sh        # 注册为登录自启的后台服务（识别 :8765，纠错 :8766）
./build.sh                 # 编译 Vocalocal.app 到 ~/Applications 并启动
```

首次启动需要授予三项权限：

| 权限 | 用途 |
|---|---|
| 辅助功能 | 监听 Fn 键、读取输入框和窗口文字、模拟 ⌘V |
| 麦克风 | 录音 |
| 屏幕录制 | 辅助功能读不到文字时（虚拟机、远程桌面、图片）截图做 OCR；只在本机处理，不保存 |

代码签名：默认 ad-hoc 签名，每次重新编译后系统会让已授予的权限失效。建议用固定证书签名：把证书 SHA-1 写进 `.sign-id`（已在 `.gitignore`），或 `SIGN_ID="证书名" ./build.sh`。

## 配置

`~/.config/vocalocal/config.json`，也可以在菜单栏 → 设置中修改：

- `vocabulary`：常用专有名词（逗号分隔），会和屏幕术语一起作为热词
- `correctorEnabled`：关闭后只用识别 + 屏幕热词，约 0.3 s/句，内存约 2.5 GB
- `asrProvider`：`local`（默认）/ `apple-new` / `apple` / `openai`（任意 OpenAI 兼容接口）
- `saveRecordings`：保存每次录音到 `~/Library/Application Support/Vocalocal/recordings`，方便用自己的声音做评测

本地识别服务不可用时会自动退回 macOS 系统识别。

## 资源占用

| 组件 | 内存 | 说明 |
|---|---|---|
| Vocalocal.app | < 100 MB | |
| 识别服务（Qwen3-ASR） | 约 2.5 GB | 常驻 |
| 纠错服务（Qwen3-Omni） | 约 21 GB | 常驻，可关闭 |

模型跑在 GPU（统一内存）上。活动监视器只有"% GPU"和"GPU 时间"，没有每个进程的 GPU 内存，"内存"列对这部分也统计不全。用自带的小工具查看真实占用：

```bash
./tools/gpumem.sh          # 按总内存排序，单独列出 GPU 内存，约 5 秒
sudo ./tools/gpumem.sh     # 包括 WindowServer 等系统进程
```

```
   总内存    GPU内存     PID  进程
  20.61 GB   20.38 GB   12272  correct_server.py
   2.44 GB    2.33 GB   12255  asr_server.py

GPU 合计已分配: 37.4 GB
```

原理是一次调用 `footprint` 分析所有进程，把 `IOAccelerator` 类别（通过 Metal 申请的内存）计为 GPU 内存。

## 项目结构

```
Sources/   Swift 菜单栏 App：Fn 监听、录音、屏幕上下文、识别 / 纠错客户端、文本输入、HUD
server/    本地模型服务（Python + MLX）及安装脚本
bench/     评测脚本和标注
tools/     辅助工具（gpumem.sh：按进程查看 GPU 内存）
```
