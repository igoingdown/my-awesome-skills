#!/bin/bash
#
# discover_printer.sh — 在当前局域网内发现网络打印机候选 IP
#
# 原理：
#   1. 并发 nc 扫描指定 /24 网段的 9100(JetDirect) 和 631(IPP) 端口；
#   2. 用 dns-sd 做 Bonjour(mDNS) 发现 _ipp._tcp 服务作为补充参考。
#
# 兼容 macOS 自带 bash 3.2，全部依赖（nc/dns-sd/route/ifconfig）为系统自带。

set -euo pipefail

usage() {
    cat <<'EOF'
用法: discover_printer.sh [网段前缀]

参数:
  网段前缀    可选，形如 "192.168.1"（即扫描 192.168.1.1-254）。
              不传时自动从默认路由接口推导本机所在 /24 网段。

示例:
  ./discover_printer.sh              # 自动推导网段
  ./discover_printer.sh 192.168.1    # 指定网段

说明:
  打印机 IP 常因 DHCP 变化，群里/通告里的旧 IP 很可能已失效，
  发现候选 IP 后建议用 check_printer.sh <IP> 进一步确认。

退出码:
  0  找到至少一个候选打印机 IP
  1  未找到（常见原因：Mac 没连到和打印机相同的局域网）
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 1 ]; then
    echo "错误: 参数过多" >&2
    usage >&2
    exit 1
fi

PREFIX="${1:-}"

# ---------- 1. 确定网段前缀 ----------
if [ -z "$PREFIX" ]; then
    echo "==> 未指定网段，从默认路由接口自动推导 ..."
    IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [ -z "$IFACE" ]; then
        echo "错误: 拿不到默认路由接口，本机可能没有联网。请检查网络后重试。" >&2
        exit 1
    fi
    LOCAL_IP="$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')"
    if [ -z "$LOCAL_IP" ]; then
        echo "错误: 接口 $IFACE 上没有 IPv4 地址。请检查网络后重试。" >&2
        exit 1
    fi
    PREFIX="$(echo "$LOCAL_IP" | cut -d. -f1-3)"
    echo "    接口: $IFACE  本机 IP: $LOCAL_IP  =>  扫描网段: $PREFIX.0/24"
fi

if ! echo "$PREFIX" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "错误: 网段前缀格式不对: \"$PREFIX\"（应形如 192.168.1）" >&2
    exit 1
fi

WORKDIR="$(mktemp -d /tmp/ipp_discover.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------- 2. 并发端口扫描 9100 / 631 ----------
SCAN_RESULTS="$WORKDIR/scan.txt"
: > "$SCAN_RESULTS"

echo "==> 并发扫描 $PREFIX.1-254 的 9100(JetDirect) / 631(IPP) 端口（约需数秒）..."
# 每个 IP 写各自的临时文件，wait 后再合并，避免 254 个并发子进程写同一文件的交错风险
for i in $(seq 1 254); do
    (
        ip="$PREFIX.$i"
        for port in 9100 631; do
            if nc -z -G 1 "$ip" "$port" >/dev/null 2>&1; then
                echo "$ip $port" >> "$WORKDIR/hit.$i"
            fi
        done
    ) &
done
wait

for f in "$WORKDIR"/hit.*; do
    if [ -f "$f" ]; then
        cat "$f" >> "$SCAN_RESULTS"
    fi
done

# 按第 4 段数字排序去重，得到候选 IP 列表
CANDIDATES="$(awk '{print $1}' "$SCAN_RESULTS" | sort -t. -k4 -n | uniq)"

# ---------- 3. Bonjour(mDNS) 发现 _ipp._tcp ----------
# 注意: dns-sd 不会自己退出，必须后台跑 + sleep + kill
BONJOUR_OUT="$WORKDIR/bonjour.txt"
echo "==> Bonjour(mDNS) 发现 _ipp._tcp 服务（监听 5 秒）..."
dns-sd -B _ipp._tcp local. > "$BONJOUR_OUT" 2>&1 &
DNSSD_PID=$!
sleep 5
kill "$DNSSD_PID" 2>/dev/null || true
wait "$DNSSD_PID" 2>/dev/null || true

# dns-sd -B 输出的是服务实例名（第 7 列起，可能含空格），不含 IP，仅作参考
BONJOUR_SERVICES="$(awk '$2 == "Add" { for (n = 1; n <= 6; n++) $n = ""; sub(/^ +/, ""); print }' "$BONJOUR_OUT" | sort -u)"

# ---------- 4. 汇总输出 ----------
echo ""
if [ -n "$BONJOUR_SERVICES" ]; then
    echo "Bonjour 发现的 IPP 服务（服务名，仅供对照）:"
    echo "$BONJOUR_SERVICES" | sed 's/^/  - /'
    echo ""
fi

if [ -z "$CANDIDATES" ]; then
    echo "未发现任何开放 9100/631 端口的候选打印机。" >&2
    echo "" >&2
    echo "最常见原因: Mac 没有连到和打印机相同的局域网。请检查:" >&2
    echo "  1. 当前 Wi-Fi 是否是办公室打印机所在的那个网络（连错 Wi-Fi 是头号原因）；" >&2
    echo "  2. 打印机是否开机、是否处于休眠断网；" >&2
    echo "  3. 若确认同网段但仍扫不到，试试指定其他网段前缀重扫，" >&2
    echo "     例如: $0 192.168.1" >&2
    exit 1
fi

echo "候选打印机 IP 列表:"
echo "$CANDIDATES" | while read -r ip; do
    ports=""
    if grep -q "^$ip 631\$" "$SCAN_RESULTS"; then
        ports="$ports 631(IPP)"
    fi
    if grep -q "^$ip 9100\$" "$SCAN_RESULTS"; then
        ports="$ports 9100(JetDirect)"
    fi
    printf "  %-16s 开放端口:%s\n" "$ip" "$ports"
done

echo ""
echo "下一步: 用 check_printer.sh <IP> 确认打印机型号与健康状态，例如:"
echo "  $(dirname "$0")/check_printer.sh $(echo "$CANDIDATES" | head -n 1)"
exit 0
