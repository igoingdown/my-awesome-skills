# ipp-print

macOS 上**免驱动**通过 IPP 协议向网络打印机打印 PDF，并在**打印机侧验证真实出纸**的脚本工具集 / Claude Code skill。

核心理念一句话：**本机说"打印完成"不算数，只有打印机亲口承认 `job-state=completed` 且 `job-media-sheets-completed > 0`，纸才是真的出来了。**

## 背景故事

这套脚本来自一次真实的办公室打印调试，一路踩了三个坑：

1. **群里通告的打印机 IP 早就过期了。** 打印机走 DHCP，IP 随时会变，按旧 IP 发什么都是超时。
2. **CUPS 谎报军情。** 换对 IP 后走本机 CUPS 队列打印，本机显示 job "completed"，人走到打印机前——一张纸都没有。用 IPP `Get-Job-Attributes` 查打印机侧才发现：任务实际是 `aborted`，出纸 0 页。CUPS 的 "completed" 只表示"数据发出去了"。
3. **根因是加密 PDF 被打印机拒收。** 打印机明明声明支持 `application/pdf`，但对加密 PDF（即使其加密策略允许打印）一律 `document-format-error` 拒收。用 `pdftocairo` 重写成干净的未加密 PDF 后一次成功。

这套脚本把当时人肉走过的**发现 IP → 检查打印机 → 打印 → 打印机侧验证**全流程固化了下来，加密 PDF 自动检测、自动重写重试。

## 依赖与安装

**macOS 自带，无需安装**：`ipptool`、`lpadmin`、`lp`、`lpstat`、`nc`、`dns-sd`、`networksetup`、`security`。

**需要 Homebrew 安装**（仅加密 PDF 预检/重写用到）：

```bash
brew install poppler   # 提供 pdfinfo / pdftocairo
```

也可以直接跑依赖体检脚本，一次看清缺什么：

```bash
./install.sh          # 检查全部依赖 + 修复脚本可执行位
./install.sh --fix    # 自动安装缺失的 poppler（需要 Homebrew）
```

所有脚本兼容 macOS 默认的 bash 3.2，均支持 `-h`/`--help` 打印 usage。打印机 IP 通过第一个位置参数或 `PRINTER_IP` 环境变量传入（`discover_printer.sh` 例外：它的位置参数是网段前缀，不传时自动取本机网段直接扫描），仓库中不含任何真实 IP。

## Quick Start

四个脚本，按典型顺序走一遍（示例 IP `192.168.1.100` 请替换为你的实际值）：

### 1. 发现打印机 —— `scripts/discover_printer.sh`

不知道 IP、或旧 IP 连不上时先跑这个（并发端口扫描 + Bonjour 发现）：

```bash
./scripts/discover_printer.sh              # 自动推导本机所在 /24 网段
./scripts/discover_printer.sh 192.168.1    # 或指定网段前缀
```

示例输出：

```
==> 并发扫描 192.168.1.1-254 的 9100(JetDirect) / 631(IPP) 端口（约需数秒）...
==> Bonjour(mDNS) 发现 _ipp._tcp 服务（监听 5 秒）...

Bonjour 发现的 IPP 服务（服务名，仅供对照）:
  - Canon iR-ADV C5250

候选打印机 IP 列表:
  192.168.1.100    开放端口: 631(IPP) 9100(JetDirect)
```

### 2. 检查打印机 —— `scripts/check_printer.sh`

确认候选 IP 就是目标打印机，且当前健康可打印：

```bash
./scripts/check_printer.sh 192.168.1.100
```

示例输出（关键字段）：

```
printer-make-and-model = Canon iR-ADV C5250
printer-state          = idle
printer-state-reasons  = none
document-format-supported 包含 application/pdf
结论: 打印机可达且状态健康，可以发起打印。
```

`printer-state-reasons` 出现 `media-jam`（卡纸）/`toner-empty`（缺粉）/`media-empty`（缺纸）等时脚本以退出码 2 退出，先去打印机前处理故障。

### 3. 打印并验证 —— `scripts/print_pdf.sh`（核心）

端到端完成：加密预检（加密则自动 `pdftocairo` 重写）→ IPP Print-Job 发送 → 轮询打印机侧任务状态 → 出纸验证：

```bash
./scripts/print_pdf.sh 192.168.1.100 /path/to/file.pdf
# 或
PRINTER_IP=192.168.1.100 ./scripts/print_pdf.sh ~/Documents/example.pdf
```

示例输出（遇到加密 PDF 时）：

```
==> 预检：pdfinfo 检查 PDF 是否加密...
==> 检测到加密 PDF（打印机会拒收，即使加密策略允许打印），正在解密重写...
==> 重写完成，后续将发送重写后的文件。
==> 发送打印任务：... -> ipp://192.168.1.100/ipp/print
==> 任务已提交，job-id = 42
==> 轮询打印机侧任务状态（每 5s 一次，最多 24 轮）...
    [第 1/24 轮] job-state=processing reasons=job-transforming sheets=? impressions=?
    [第 2/24 轮] job-state=completed reasons=无 sheets=2 impressions=2

✅ 打印成功，实际出纸 2 页（job-id=42，打印机侧确认 job-state=completed）
```

只有 `job-state=completed` **且**实际出纸页数 > 0 才判定成功；`aborted + document-format-error` 时自动重写重试一次；其余失败场景非零退出并给出排查建议。

### 4. 可选：建 CUPS 常驻队列 —— `scripts/setup_cups_queue.sh`

日常频繁打印可以建一个系统队列（IPP Everywhere，免驱动）：

```bash
./scripts/setup_cups_queue.sh 192.168.1.100 office-printer
lp -d office-printer /path/to/file.pdf
```

**注意**：走 CUPS 队列打印后，本机 `lpstat` 报 completed 依然不可信（见背景故事第 2 坑）。重要文档请用 `print_pdf.sh` 打印，或至少用 IPP `Get-Job-Attributes` 查打印机侧状态（方法见[排查手册](references/troubleshooting.md)）。

## 作为 Claude Code skill 使用

把本目录复制到 Claude Code 的 skills 目录即可：

```bash
# 用户级（所有项目可用）
cp -r skills/ipp-print ~/.claude/skills/ipp-print

# 或项目级（仅当前项目可用）
cp -r skills/ipp-print <你的项目>/.claude/skills/ipp-print
```

之后在 Claude Code 里直接说"帮我把 xxx.pdf 打出来"、"打印机连不上了帮我看看"、"打印显示成功但没出纸"，Claude 会按 [SKILL.md](SKILL.md) 中的工作流自动调用这些脚本完成发现、检查、打印和验证。

## 兼容性说明

- **实测环境**：macOS 26.x + Canon imageRUNNER ADVANCE 系列（iR-ADV C5250）。
- **理论适用**：所有支持 **IPP Everywhere** 的网络打印机——脚本只依赖标准 IPP 操作（Print-Job / Get-Job-Attributes / Get-Printer-Attributes），不含任何厂商私有协议。
- **Linux 用户改动点**：
  - `nc` 连接超时参数：macOS 用 `-G 秒数`，Linux 改为 `-w 秒数`；
  - `networksetup`（切 Wi-Fi）、`security`（读钥匙串）、`dns-sd`（Bonjour）为 macOS 专有，Linux 分别用 `nmcli`、自行管理密码、`avahi-browse -rt _ipp._tcp` 替代；
  - `ipptool` 在 Linux 上来自 CUPS 相关包（如 Debian/Ubuntu 的 `cups-ipp-utils`），需要另行安装；
  - Linux 的 bash 普遍是 4+，脚本的 bash 3.2 兼容写法在其上原样可用。

## 打印失败？

排查手册覆盖了 CUPS 假成功、`document-format-error`、IP 失效重发现、Wi-Fi 网络检查、macOS 脚本兼容坑和 `printer-state-reasons` 对照表：

👉 [references/troubleshooting.md](references/troubleshooting.md)
