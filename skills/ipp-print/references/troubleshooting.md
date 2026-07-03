# IPP 打印故障排查手册（macOS）

实测环境：macOS 26.x + Canon iR-ADV C5250（imageRUNNER ADVANCE 系列）。方法对任何支持 IPP Everywhere 的网络打印机通用。

文中示例统一使用占位 IP `192.168.1.100`、占位 SSID `YourOfficeWiFi`，请替换为你的实际值。

---

## 1. CUPS 显示 completed，但打印机没出纸（假成功，最大的坑）

### 现象

通过本机 CUPS 队列打印（`lp -d 队列名 file.pdf`）后，`lpstat -W completed` 显示任务已完成，但打印机一张纸都没出。

### 机制

CUPS 的 "completed" 只表示**本机队列成功把数据发给了打印机**，不代表打印机成功处理了任务。实测中，加密 PDF 经 CUPS 队列打印：本机报 `completed`，但打印机侧该任务实际是 `aborted`（`job-state-reasons = document-format-error`），出纸 0 页。

**结论：验证必须查打印机侧，本机 CUPS 状态不可信。**

### 打印机侧验证方法（IPP Get-Job-Attributes）

判定标准：只有 `job-state = completed(9)` **且** `job-media-sheets-completed > 0` 才算真打出来了。

1. 生成查询用 `.test` 文件（全文如下，可直接保存为 `/tmp/get-job.test`）：

```
{
  NAME "Get job attributes"
  OPERATION Get-Job-Attributes
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR naturalLanguage attributes-natural-language en
  ATTR uri printer-uri $uri
  ATTR integer job-id $jobid
  DISPLAY job-state
  DISPLAY job-state-reasons
  DISPLAY job-impressions-completed
  DISPLAY job-media-sheets-completed
}
```

2. 用 `ipptool` 查询（`N` 替换为发送打印时返回的 `job-id`）：

```bash
ipptool -tv -d jobid=N ipp://192.168.1.100/ipp/print /tmp/get-job.test
```

3. 读结果：

| job-state | 含义 |
|---|---|
| `pending(3)` / `pending-held(4)` | 排队中 |
| `processing(5)` | 处理中；`job-state-reasons` 常见 `job-transforming`（正在转码），继续轮询 |
| `completed(9)` | 完成 —— 还要看 `job-media-sheets-completed > 0` 才是真出纸 |
| `aborted(8)` | 打印机中止任务（见第 2 节） |
| `canceled(7)` | 任务被取消 |

注：`job-id` 从哪来 —— 直连 IPP 打印时 `ipptool -tv -f file.pdf ipp://192.168.1.100/ipp/print print-job.test` 的输出里有 `job-id (integer) = N`。若走 CUPS 队列打印，CUPS 的 job 号与打印机侧 job-id 不是一回事，需在打印机 Web 管理页或用 IPP Get-Jobs 查打印机侧任务列表。重要文件建议直接用 `print_pdf.sh`（直连 IPP + 自动打印机侧验证）。

---

## 2. 任务 aborted，job-state-reasons = document-format-error

### 原因

打印机虽然在 `document-format-supported` 中声明支持 `application/pdf`，但**会拒收加密 PDF**（即使 PDF 的加密策略允许打印），以及内容流不规范的 PDF。表现为 `job-state = aborted`、`job-state-reasons = document-format-error`、出纸 0 页。

### 预检：pdfinfo 判断是否加密

```bash
pdfinfo /path/to/file.pdf | grep -i encrypted
```

输出 `Encrypted: yes` 即需要重写（`pdfinfo` 来自 Homebrew 的 poppler：`brew install poppler`）。

### 修复：pdftocairo 重写为干净 PDF

```bash
pdftocairo -pdf /path/to/file.pdf /path/to/file-clean.pdf
```

重写为未加密的 PDF 1.7 后重发即成功。此方法对"未加密但内容流不规范"的 PDF 同样有效，遇到 `document-format-error` 可无脑先重写一遍再试。

---

## 2b. 任务卡在 processing-stopped，reasons=none，永远不出纸

### 现象

任务提交成功（successful-ok），但轮询时 `job-state` 停在 `processing-stopped`、`job-state-reasons = none`，出纸 0 页，且**打印机整机状态仍显示 idle/none**——从 IPP 属性上完全看不出哪里出了问题。

### 原因（实测）

PDF 纸张尺寸与打印机纸盒不匹配。实测把 Letter 尺寸（612×792 pt）的 PDF 发给只装了 A4 纸的打印机，打印机不报错、不中止，而是在面板上静默等待人工确认换纸，IPP 侧只表现为 `processing-stopped`。

### 预检与修复

```bash
# 预检：看 PDF 纸张尺寸（595x842=A4, 612x792=Letter）
pdfinfo /path/to/file.pdf | grep -i "page size"

# 打印机默认纸张看 check_printer.sh 输出的 media-default（如 iso_a4_210x297mm）
```

修复三选一：
1. 重新生成 A4 尺寸的 PDF（推荐，一劳永逸）；
2. 到打印机面板上确认换纸/继续的提示；
3. 取消任务后换文件重打。卡住的任务会占住队列，务必取消：`print_pdf.sh` 超时后会自动发 IPP Cancel-Job 清理；手动清理方法是用 Cancel-Job 操作的 `.test` 文件（`OPERATION Cancel-Job` + `ATTR integer job-id N`）跑 `ipptool -d jobid=N`。

---

## 3. 打印机 IP 连不上 / IP 失效

打印机 IP 常因 DHCP 变化，群里、通告里的旧 IP 很可能已失效。两条重发现路径：

### 3a. 并发端口扫描当前网段

先确认本机所在网段（如 `192.168.1.x`），再扫 9100（JetDirect）端口：

```bash
PREFIX=192.168.1   # 换成你的网段前缀
for i in $(seq 1 254); do
  (nc -z -G 1 $PREFIX.$i 9100 >/dev/null 2>&1 && echo "$PREFIX.$i") &
done
wait
```

多数网络打印机同时开 631(IPP)、9100(JetDirect)、515(LPD)、80/443(Web 管理页)，扫到候选 IP 后可用浏览器打开 `http://候选IP` 看 Web 管理页确认型号。

### 3b. Bonjour 发现

```bash
dns-sd -B _ipp._tcp local. &
DNSSD_PID=$!
sleep 5
kill $DNSSD_PID 2>/dev/null
```

注意：`dns-sd -B` 不会自己退出，必须后台运行 + sleep + kill。

找到新 IP 后，重跑 `setup_cups_queue.sh <新IP>` 重建队列即可（脚本会自动删旧队列重建）。

---

## 4. 631 端口连不通：大概率是 Wi-Fi 连错了

Mac 必须和打印机在**同一局域网**。最常见的失败原因就是连到了别的 Wi-Fi（访客网/手机热点/另一楼层 SSID）。

### 查看当前网络

```bash
networksetup -getairportnetwork en0
ipconfig getifaddr en0   # 看本机 IP 是否与打印机同网段
```

### 免 sudo 从系统钥匙串读已保存的 Wi-Fi 密码

```bash
security find-generic-password -D "AirPort network password" \
  -a "YourOfficeWiFi" -w /Library/Keychains/System.keychain
```

（仅对本机保存过的 SSID 有效。）

### 切换 Wi-Fi

```bash
networksetup -setairportnetwork en0 "YourOfficeWiFi" "读出来的密码"
```

切网后等几秒再用 `nc -z -G 3 192.168.1.100 631` 确认端口可达。

---

## 5. macOS 脚本兼容坑

写自动化脚本时注意这几个 macOS 特有的坑：

| 坑 | 说明 | 替代方案 |
|---|---|---|
| 没有 `timeout` 命令 | GNU coreutils 的 `timeout` 在 macOS 上不存在 | 用工具自带的超时参数（如 `nc -G 秒数`），或后台运行 + sleep + kill（见第 3b 节 dns-sd 的用法） |
| 默认 `/bin/bash` 是 3.2 | 不支持 `mapfile`/`readarray`、关联数组（`declare -A`）、`${var,,}` 大小写转换等 bash 4+ 特性 | 只用 bash 3.2 兼容语法；数组用普通索引数组，遍历用 while read |
| `nc` 超时参数不同 | macOS 的 nc 用 `-G 秒数` 指定连接超时，不是 Linux 的 `-w` 语义 | 端口探测统一写 `nc -z -G 1 IP 端口` |

好消息：`ipptool`/`lpadmin`/`lp`/`lpstat`/`nc`/`dns-sd`/`networksetup`/`security` 全是 macOS 自带；只有 `pdfinfo`/`pdftocairo` 需要 `brew install poppler`。

---

## 6. printer-state-reasons 常见值对照表

查看打印机整机状态：

```bash
ipptool -tv ipp://192.168.1.100/ipp/print get-printer-attributes.test
```

重点看三个字段：

- `printer-state`：`idle`（空闲）/ `processing`（打印中）/ `stopped`（停止，通常有故障）
- `printer-state-reasons`：见下表
- 顺带可确认 `printer-make-and-model`（型号）、`document-format-supported`（支持的格式）、`media-default`（默认纸张）

| printer-state-reasons | 含义 | 处理 |
|---|---|---|
| `none` | 健康，无异常 | 无需处理 |
| `media-jam` | 卡纸 | 到打印机前清卡纸 |
| `media-empty` / `media-needed` | 缺纸 | 加纸 |
| `toner-empty` | 碳粉用尽 | 换碳粉 |
| `toner-low` | 碳粉不足（警告） | 尚可打印，尽快备粉 |
| `marker-supply-empty` | 耗材（墨/粉）用尽 | 更换耗材 |
| `cover-open` / `door-open` | 盖板/舱门未关 | 关好盖板 |
| `output-tray-missing` | 出纸托盘缺失 | 装回托盘 |
| `paused` | 打印机被暂停 | 在面板或管理页恢复 |
| `other`（常带 `-error`/`-warning` 后缀） | 厂商自定义状态 | 看打印机面板或 Web 管理页具体报错 |

后缀含义：`-report` 仅通报、`-warning` 警告（通常仍可打印）、`-error` 错误（打印会被阻塞）。

---

## 快速自检清单

打印失败时按顺序排查：

1. **网络对不对**：`networksetup -getairportnetwork en0`，本机与打印机同网段？（第 4 节）
2. **IP 活着吗**：`nc -z -G 3 192.168.1.100 631`，不通就重发现 IP（第 3 节）
3. **打印机健康吗**：get-printer-attributes 看 `printer-state-reasons`（第 6 节）
4. **PDF 加密了吗**：`pdfinfo` 预检，`Encrypted: yes` 先 `pdftocairo` 重写（第 2 节）
5. **真打出来了吗**：打印机侧 Get-Job-Attributes 验证 `job-state=completed` 且 `job-media-sheets-completed>0`，别信本机 CUPS 的 completed（第 1 节）
