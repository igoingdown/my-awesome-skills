---
name: ipp-print
description: macOS 上通过 IPP 协议向办公室网络打印机打印 PDF 并做真实出纸验证。当用户要连接网络打印机、打印 PDF/文件、打印失败排查（发出去了但没出纸/CUPS 显示 completed 但打印机没反应）、发现或验证办公室打印机 IP、检查打印机状态/能力时使用。实测于 Canon iR-ADV C5250，通用于支持 IPP Everywhere 的网络打印机。
---

# IPP 网络打印机打印与验证

macOS 上用系统自带的 `ipptool` 直连打印机（`ipp://<IP>/ipp/print`，端口 631）打印 PDF，并在**打印机侧**验证任务真的出纸了。所有脚本兼容 bash 3.2（macOS 默认），打印机 IP 通过第一个位置参数或 `PRINTER_IP` 环境变量传入（`discover_printer.sh` 例外，它的位置参数是网段前缀）。

## 工作流

按顺序执行以下步骤。已知打印机 IP 且最近验证过时，可从第 3 步或第 4 步开始。

### 1. 前置检查

**同一局域网**：Mac 必须和打印机在同一局域网，这是最常见的失败原因（连错 Wi-Fi）。先确认当前网络：

```bash
networksetup -getairportnetwork en0        # 查看当前 Wi-Fi
ifconfig en0 | grep "inet "                # 查看本机 IP / 网段
```

如需切换到办公室 Wi-Fi，已保存过的密码可免 sudo 从系统钥匙串读出：

```bash
security find-generic-password -D "AirPort network password" -a "YourOfficeWiFi" -w /Library/Keychains/System.keychain
networksetup -setairportnetwork en0 "YourOfficeWiFi" "读出的密码"
```

**poppler 依赖**（加密 PDF 预检/重写需要，仅 `print_pdf.sh` 用到）：

```bash
command -v pdfinfo >/dev/null 2>&1 || brew install poppler
```

`ipptool`/`lpadmin`/`lp`/`nc`/`dns-sd` 均为 macOS 自带，无需安装。首次使用或环境不确定时可跑 `install.sh` 做一次完整依赖体检（`--fix` 自动装 poppler）。

### 2. 发现打印机

**注意：打印机 IP 常因 DHCP 变化，群里/通告里的旧 IP 很可能已失效。** 打印前如果直连超时，或不确定 IP 是否还有效，先跑发现脚本：

```bash
scripts/discover_printer.sh              # 自动取本机网段扫描
scripts/discover_printer.sh 192.168.1    # 指定网段前缀
```

脚本做两件事：并发扫描网段内开 9100（JetDirect）或 631（IPP）端口的主机 + Bonjour（`dns-sd -B _ipp._tcp local.`）浏览 IPP 服务。预期输出类似：

```
==> 并发扫描 192.168.1.1-254 的 9100(JetDirect) / 631(IPP) 端口（约需数秒）...
==> Bonjour(mDNS) 发现 _ipp._tcp 服务（监听 5 秒）...

Bonjour 发现的 IPP 服务（服务名，仅供对照）:
  - Canon iR-ADV C5250

候选打印机 IP 列表:
  192.168.1.100    开放端口: 631(IPP) 9100(JetDirect)
```

拿到候选 IP 后进入第 3 步确认。

### 3. 检查打印机能力与状态

```bash
scripts/check_printer.sh 192.168.1.100
# 或
PRINTER_IP=192.168.1.100 scripts/check_printer.sh
```

脚本用 `ipptool ... get-printer-attributes.test` 拉取整机属性并解读关键字段：

- `printer-make-and-model`：确认是目标打印机
- `printer-state`：`idle`（3）/ `processing`（4）为可用；`stopped`（5）为故障
- `printer-state-reasons`：`none` 为健康；`media-jam`（卡纸）/`toner-empty`（缺粉）/`media-empty`（缺纸）等为故障，需要人工处理后再打印
- `document-format-supported`：确认包含 `application/pdf`
- `media-default`：默认纸张

预期成功输出末尾为 `结论: 打印机可达且状态健康，可以发起打印。`（退出码 0）。若打印机 stopped、`printer-state-reasons` 含 `jam`/`empty` 等故障关键字或不支持 PDF，脚本会打印告警并以退出码 2 退出，末尾为 `结论: 打印机可达，但存在上述告警项，打印前请先处理。`。

### 4. 打印并验证（核心步骤）

```bash
scripts/print_pdf.sh 192.168.1.100 /path/to/file.pdf
# 或
PRINTER_IP=192.168.1.100 scripts/print_pdf.sh /path/to/file.pdf
```

脚本端到端完成四件事：

1. **加密 PDF 预检/自动重写**：先 `pdfinfo` 检查，若 `Encrypted: yes`（或内容流不规范），自动用 `pdftocairo -pdf` 重写为干净的未加密 PDF 1.7 再发送。打印机声明支持 `application/pdf` 但**会拒收加密 PDF**（即使加密策略允许打印），直接发送会 aborted、0 页出纸。
2. **发送**：`ipptool -tv -f file.pdf ipp://IP/ipp/print print-job.test`，成功输出含 `status-code = successful-ok` 和 `job-id (integer) = N`。
3. **轮询任务状态**：用自定义 Get-Job-Attributes 测试文件轮询 `job-state`，直到终态（completed / aborted / canceled）。processing 阶段 `job-state-reasons` 常见 `job-transforming`，属正常。
4. **打印机侧出纸验证**：只有 `job-state = completed`（9）**且** `job-media-sheets-completed > 0` 才判定真打出来了。任一不满足即失败退出并打印 `job-state-reasons` 供排查（`document-format-error` = 格式被拒，通常是加密/损坏 PDF）。

预期成功输出末尾类似：

```
✅ 打印成功，实际出纸 2 页（job-id=42, 打印机侧确认 job-state=completed）
```

### 5. 可选：建 CUPS 常驻队列

日常频繁打印可以建一个系统队列，之后普通（未加密）PDF 可直接 `lp` 打印：

```bash
scripts/setup_cups_queue.sh 192.168.1.100 office-printer
lp -d office-printer /path/to/file.pdf
```

**但注意**：CUPS 队列打印后本地 `lpstat` 报 completed 不可信（见下方陷阱一），重要文档仍应走 `scripts/print_pdf.sh` 或至少用其中的 Get-Job-Attributes 方法查打印机侧状态。

## 关键陷阱（排查打印问题必读）

1. **CUPS 假成功（最大的坑）**：走本机 CUPS 队列打印时，CUPS 本地会报 job "completed"，但打印机侧任务实际是 aborted、0 页出纸。**验证必须查打印机侧**：用 IPP Get-Job-Attributes 查 `job-state` 和 `job-media-sheets-completed`，只有 `job-state=completed(9)` 且 `job-media-sheets-completed>0` 才算真打出来了。用户说"显示打印成功但没出纸"时，第一反应就是这个。
2. **加密 PDF 被拒收**：打印机声明支持 `application/pdf`，但加密 PDF（即使加密策略允许打印）会被拒：`job-state=aborted`、`job-state-reasons=document-format-error`、出纸 0 页。修复：`pdftocairo -pdf in.pdf out.pdf` 重写后重发（`print_pdf.sh` 已内置此逻辑）。`pdfinfo` 输出中 `Encrypted: yes` 即需要重写。
3. **纸张尺寸不匹配 = 静默卡死**：PDF 纸张尺寸与打印机纸盒不符（如 Letter 发给只装了 A4 纸的打印机）时，任务不报错、不中止，而是卡在 `job-state=processing-stopped`、`reasons=none`，打印机在面板上静默等人工确认，整机状态还显示 idle。打印前可用 `pdfinfo file.pdf | grep -i "page size"` 预检（595x842=A4，612x792=Letter），对照 `check_printer.sh` 输出的默认纸张。`print_pdf.sh` 轮询超时后会自动取消卡住的任务，避免堵住队列。
4. **IP 过期**：打印机 IP 常因 DHCP 变化，别信旧记录/群公告里的 IP，连不上先跑 `scripts/discover_printer.sh` 重新发现。
5. **macOS 环境限制**：没有 `timeout` 命令（脚本内用 `nc -G 秒数` 和轮询计数替代）；默认 `/bin/bash` 是 3.2，禁用 `mapfile`/`readarray`/关联数组/`${var,,}` 等 bash4+ 特性。手写补充命令时也要遵守。
6. **不在同一局域网**：所有 IPP 请求超时的另一常见原因是 Mac 连错了 Wi-Fi，先做第 1 步的网络检查。

更完整的排查手册（含 `printer-state-reasons` 对照表、Get-Job-Attributes 手工验证方法）见 [references/troubleshooting.md](references/troubleshooting.md)。

## 脚本清单

| 脚本 | 作用 |
|------|------|
| `scripts/discover_printer.sh` | 端口扫描 + Bonjour 发现网段内打印机 |
| `scripts/check_printer.sh` | 查打印机型号/状态/能力，判断是否可打印 |
| `scripts/print_pdf.sh` | 预检加密 → 发送 → 轮询 → 打印机侧出纸验证，端到端打印 |
| `scripts/setup_cups_queue.sh` | 建 CUPS 常驻队列（IPP Everywhere） |

所有脚本都支持 `-h`/`--help` 打印 usage；`check_printer.sh`/`print_pdf.sh`/`setup_cups_queue.sh` 的打印机 IP 可用第一个位置参数或 `PRINTER_IP` 环境变量传入，`discover_printer.sh` 的位置参数是网段前缀（不传时自动取本机网段直接扫描）。
