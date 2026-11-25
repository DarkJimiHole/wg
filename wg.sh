#!/usr/bin/env bash
# wg.sh - 交互式 WireGuard 组网脚本（Debian / Ubuntu）
#
#   curl -fsSL https://raw.githubusercontent.com/DarkJimiHole/wg/main/wg.sh -o wg.sh && sudo bash wg.sh
#
# 一台有公网 IP 的服务器做「服务端」，其它服务器（有没有公网 IP 都行）做「客户端」连上来。
# 每台机器自己生成密钥，私钥不离开本机；双方只交换公钥，用两段「邀请码 / 回复码」复制粘贴完成：
#   1. 服务端：添加客户端 -> 显示邀请码          （含服务端地址、公钥、分配给客户端的隧道 IP）
#   2. 客户端：安装客户端 -> 粘贴邀请码 -> 显示回复码（含客户端公钥）
#   3. 服务端：粘贴回复码 -> 完成
# 客户端主动连接并保持心跳，所以客户端在 NAT 后面（没有公网 IP）也能用。
set -euo pipefail

VERSION=1.0.0
WG_DIR=/etc/wireguard
MARK="# managed-by: wg.sh"
KEEPALIVE=25

# ---------------------------------------------------------------- 输出
if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else R=; G=; Y=; B=; N=; fi
info() { echo "${G}==>${N} $*"; }
warn() { echo "${Y}警告：${N}$*" >&2; }
die()  { echo "${R}错误：${N}$*" >&2; exit 1; }
hr()   { echo "------------------------------------------------------------"; }

# 交互输入：stdin 是终端就读 stdin；用 curl | bash 运行时 stdin 是脚本本身，改读 /dev/tty
if [ -t 0 ]; then IN=/dev/stdin
elif { : < /dev/tty; } 2>/dev/null; then IN=/dev/tty
else IN=/dev/stdin; fi

# ask "提示" "默认值" -> 结果在 $REPLY
ask() {
    local prompt="$1" def="${2:-}"
    if [ -n "$def" ]; then printf '%s [%s]: ' "$prompt" "$def"; else printf '%s: ' "$prompt"; fi
    IFS= read -r REPLY < "$IN" || REPLY=""
    REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"; REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
    [ -n "$REPLY" ] || REPLY="$def"
}
confirm() {   # confirm "问题" y|n(默认)
    local def="${2:-y}"
    ask "$1 (y/n)" "$def"
    [[ "$REPLY" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------- 环境
need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash $0"; }

install_wg() {
    if ! command -v wg >/dev/null || ! command -v wg-quick >/dev/null; then
        info "安装 wireguard-tools"
        if command -v apt-get >/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools iproute2 >/dev/null
        elif command -v dnf >/dev/null; then dnf install -y -q wireguard-tools iproute
        elif command -v yum >/dev/null; then yum install -y -q wireguard-tools iproute
        else die "不认识的系统：请先手动安装 wireguard-tools"; fi
    fi
    command -v curl >/dev/null || { command -v apt-get >/dev/null && apt-get install -y -qq curl >/dev/null; } || true
    if ! ip link add wgshtest0 type wireguard 2>/dev/null; then
        die "内核不支持 WireGuard（容器 / OpenVZ / 太老的内核）。Debian 11+ / Ubuntu 20.04+ 的 KVM 机器都支持"
    fi
    ip link del wgshtest0
}

managed_ifaces() {
    local f
    for f in "$WG_DIR"/*.conf; do
        [ -f "$f" ] && grep -qx "$MARK" "$f" && basename "$f" .conf
    done
    return 0
}
meta() { sed -n "s/^# wg.sh $2=//p" "$WG_DIR/$1.conf" | head -1; }

free_iface() {
    local i
    for i in 0 1 2 3 4 5 6 7 8 9; do
        [ -e "$WG_DIR/wg$i.conf" ] || ip link show "wg$i" >/dev/null 2>&1 || { echo "wg$i"; return; }
    done
    echo "wg-x"
}

valid_iface() { [[ "$1" =~ ^[a-zA-Z0-9_-]{1,15}$ ]]; }
iface_taken() { [ -e "$WG_DIR/$1.conf" ] || ip link show "$1" >/dev/null 2>&1; }

# 选一个本机托管的接口（只有一个就直接用）
pick_iface() {   # pick_iface server|client|any -> $IFACE
    local want="$1" list=() f
    for f in $(managed_ifaces); do
        if [ "$want" = any ] || [ "$(meta "$f" role)" = "$want" ]; then list+=("$f"); fi
    done
    case ${#list[@]} in
        0) return 1 ;;
        1) IFACE="${list[0]}" ;;
        *) echo "本机有多个接口：${list[*]}"
           while :; do ask "选择接口" "${list[0]}"; for f in "${list[@]}"; do [ "$f" = "$REPLY" ] && { IFACE="$f"; return 0; }; done; echo "没有这个接口"; done ;;
    esac
}

local_addrs() { ip -o -4 addr show | awk '{print $4}'; }

net_in_use() {   # net_in_use 10.66.66 -> 本机已有这个 /24 里的地址或路由
    local p="$1"
    local_addrs | grep -q "^$p\." && return 0
    ip -4 route show | awk '{print $1}' | grep -q "^$p\." && return 0
    return 1
}

port_in_use() { [ -n "$(ss -Hlun "sport = :$1" 2>/dev/null)" ]; }

detect_public_ip() {
    local ip="" u
    for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
        ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]') || true
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
    done
    echo ""
}

open_firewall() {   # open_firewall 51820
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$1/udp" comment "wg.sh" >/dev/null && info "ufw 已放行 UDP $1"
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd -q --permanent --add-port="$1/udp" && firewall-cmd -q --reload && info "firewalld 已放行 UDP $1"
    fi
}
close_firewall() {
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "$1/udp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd -q --permanent --remove-port="$1/udp" 2>/dev/null && firewall-cmd -q --reload || true
    fi
}

valid_key() { [[ "$1" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$ ]]; }

# 邀请码 / 回复码：前缀 + base64(key=value 行)
encode() { local pre="$1"; shift; printf '%s\n' "$@" | base64 -w0 | sed "s/^/$pre/"; }
decode() {   # decode 前缀 码 -> 把 key=value 设成 C_key 变量
    local pre="$1" code="$2" body line k v
    code="${code//[[:space:]]/}"
    [[ "$code" == "$pre"* ]] || return 1
    body=$(printf '%s' "${code#"$pre"}" | base64 -d 2>/dev/null) || return 1
    while IFS= read -r line; do
        k="${line%%=*}"; v="${line#*=}"
        [[ "$k" =~ ^[a-z_]+$ ]] || continue
        printf -v "C_$k" '%s' "$v"
    done <<< "$body"
    [ "${C_v:-}" = 1 ]
}

apply_conf() { wg syncconf "$1" <(wg-quick strip "$1"); }

start_iface() {
    systemctl enable "wg-quick@$1" >/dev/null 2>&1
    systemctl restart "wg-quick@$1"
}

handshake_age() {   # handshake_age 接口 公钥 -> 秒数，没握手过输出空
    local t
    t=$(wg show "$1" latest-handshakes 2>/dev/null | awk -v k="$2" '$1==k {print $2}')
    [ -n "$t" ] && [ "$t" != 0 ] && echo $(( $(date +%s) - t ))
    return 0
}

wait_handshake() {   # wait_handshake 接口 公钥 秒数
    local i
    for ((i = 0; i < $3; i += 2)); do
        [ -n "$(handshake_age "$1" "$2")" ] && return 0
        sleep 2
    done
    return 1
}

human_age() {
    local s="$1"
    if [ -z "$s" ]; then echo "从未"; elif [ "$s" -lt 60 ]; then echo "${s} 秒前"
    elif [ "$s" -lt 3600 ]; then echo "$((s / 60)) 分钟前"; else echo "$((s / 3600)) 小时前"; fi
}

# ---------------------------------------------------------------- 服务端
install_server() {
    install_wg
    hr; echo "${B}安装服务端${N}（本机需要有公网 IP，其它服务器连到这里）"; hr

    local def; def=$(free_iface)
    while :; do
        ask "接口名称" "$def"; IFACE="$REPLY"
        valid_iface "$IFACE" || { echo "只能用字母数字 _ -，最长 15 个字符"; continue; }
        iface_taken "$IFACE" && { echo "$IFACE 已存在，换一个"; continue; }
        break
    done

    local p cand=""
    for p in 10.66.66 10.77.77 10.88.88 10.99.99 172.29.29 192.168.233; do net_in_use "$p" || { cand="$p"; break; }; done
    while :; do
        ask "隧道网段（/24）" "${cand:-10.66.66}.0/24"
        p="${REPLY%.0/24}"; p="${p%/24}"
        [[ "$p" =~ ^(10|172|192)\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { echo "请输入形如 10.66.66.0/24 的私有网段"; continue; }
        net_in_use "$p" && { echo "$p.0/24 和本机已有的地址或路由冲突，换一个"; continue; }
        NET="$p"; break
    done

    local port=51820
    while port_in_use "$port"; do port=$((port + 1)); done
    while :; do
        ask "监听 UDP 端口" "$port"
        [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le 65535 ] || { echo "端口无效"; continue; }
        port_in_use "$REPLY" && { echo "UDP $REPLY 已被占用"; continue; }
        PORT="$REPLY"; break
    done

    info "检测公网 IP…"
    local pub; pub=$(detect_public_ip)
    while :; do
        if [ -n "$pub" ]; then ask "客户端用来连接本机的公网 IP 或域名" "$pub"
        else ask "客户端用来连接本机的公网 IP 或域名（没检测到，请手动填写）" ""; fi
        [ -n "$REPLY" ] && break
    done
    local host="$REPLY"
    [[ "$host" == *:* && "$host" != \[* ]] && host="[$host]"   # IPv6

    umask 077
    mkdir -p "$WG_DIR"
    local priv; priv=$(wg genkey)
    cat > "$WG_DIR/$IFACE.conf" <<EOF
$MARK
# wg.sh role=server
# wg.sh endpoint=$host:$PORT
# wg.sh net=$NET
[Interface]
Address = $NET.1/24
ListenPort = $PORT
PrivateKey = $priv
EOF
    chmod 600 "$WG_DIR/$IFACE.conf"
    open_firewall "$PORT"
    start_iface "$IFACE"

    hr
    info "服务端已启动：接口 $IFACE，本机隧道地址 ${B}$NET.1${N}，监听 UDP $PORT"
    echo "  ${Y}别忘了在云厂商的安全组 / 防火墙放行 UDP $PORT 入站${N}"
    hr
    if confirm "现在添加第一个客户端？" y; then add_client; else echo "以后添加：sudo bash $0 → 选「添加客户端」"; fi
}

next_free_ip() {   # next_free_ip 接口 -> 下一个未分配的隧道 IP
    local net used i
    net=$(meta "$1" net)
    used=$(grep -o "^AllowedIPs *= *$net\.[0-9]*" "$WG_DIR/$1.conf" | grep -o '[0-9]*$' || true)
    for ((i = 2; i < 255; i++)); do
        grep -qx "$i" <<< "$used" || { echo "$net.$i"; return; }
    done
    return 1
}

add_client() {
    pick_iface server || die "本机还不是服务端：先选「安装服务端」"
    local net endpoint pub ip
    net=$(meta "$IFACE" net); endpoint=$(meta "$IFACE" endpoint)
    pub=$(wg show "$IFACE" public-key 2>/dev/null) || pub=$(sed -n 's/^PrivateKey *= *//p' "$WG_DIR/$IFACE.conf" | wg pubkey)
    ip=$(next_free_ip "$IFACE") || die "$net.0/24 已经分配满了"

    local code; code=$(encode WGI1: v=1 endpoint="$endpoint" pubkey="$pub" server_ip="$net.1" client_ip="$ip")
    hr
    echo "${B}第 1 步：${N}在客户端服务器上运行 ${B}sudo bash wg.sh${N}，选「安装客户端」，粘贴下面的${B}邀请码${N}："
    echo
    echo "$code"
    echo
    echo "（邀请码只含服务端地址和公钥，不含私钥。这个客户端将分配到隧道地址 $ip）"
    hr
    echo "${B}第 2 步：${N}把客户端显示的${B}回复码${N}粘贴到这里（直接回车 = 稍后再加）"
    local reply
    while :; do
        ask "回复码" ""; reply="$REPLY"
        [ -z "$reply" ] && { echo "已取消。以后重新选「添加客户端」即可（邀请码可以重新生成）"; return 0; }
        unset C_v C_pubkey C_ip C_name
        decode WGR1: "$reply" || { echo "回复码不对：请复制客户端上以 WGR1: 开头的整行"; continue; }
        valid_key "${C_pubkey:-}" || { echo "回复码里的公钥无效"; continue; }
        [ "${C_ip:-}" = "$ip" ] || [[ "${C_ip:-}" =~ ^${net//./\\.}\.([0-9]+)$ ]] || { echo "回复码里的地址 ${C_ip:-?} 不在 $net.0/24 里"; continue; }
        if grep -q "^PublicKey *= *${C_pubkey}$" "$WG_DIR/$IFACE.conf"; then echo "这个客户端已经添加过了"; return 0; fi
        if grep -q "^AllowedIPs *= *${C_ip}/32" "$WG_DIR/$IFACE.conf" || [ "$C_ip" = "$net.1" ]; then
            echo "地址 $C_ip 已被占用：回到上面重新生成邀请码"; return 1
        fi
        break
    done
    local name="${C_name:-client}"
    name="${name//[^A-Za-z0-9._-]/}"
    cat >> "$WG_DIR/$IFACE.conf" <<EOF

[Peer]
# name: ${name:-client}
PublicKey = $C_pubkey
AllowedIPs = $C_ip/32
EOF
    apply_conf "$IFACE"
    info "已添加客户端 ${name}（$C_ip），等待它连上来…"
    if wait_handshake "$IFACE" "$C_pubkey" 60; then
        info "${G}握手成功${N}：服务端 $net.1 <-> 客户端 $C_ip"
        ping -c 1 -W 2 "$C_ip" >/dev/null 2>&1 && info "ping $C_ip 正常" || true
    else
        warn "60 秒内没有握手。客户端每 ${KEEPALIVE} 秒会重试一次，稍后用「查看状态」确认。仍不通请检查：安全组是否放行 UDP、邀请码里的地址 $endpoint 是否正确"
    fi
}

remove_client() {
    pick_iface server || die "本机没有服务端接口"
    local keys=() names=() ips=() k i
    while IFS='|' read -r k n a; do keys+=("$k"); names+=("$n"); ips+=("$a"); done < <(
        awk '/^\[Peer\]/{n="";k="";a=""} /^# name:/{sub(/^# name: */,"");n=$0}
             /^PublicKey/{sub(/^PublicKey *= */,"");k=$0} /^AllowedIPs/{sub(/^AllowedIPs *= */,"");a=$0; print k"|"n"|"a}' \
        "$WG_DIR/$IFACE.conf")
    [ ${#keys[@]} -gt 0 ] || { echo "还没有客户端"; return 0; }
    for i in "${!keys[@]}"; do echo "  $((i + 1))) ${names[$i]:-?}  ${ips[$i]}"; done
    ask "删除第几个（回车取消）" ""
    [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le ${#keys[@]} ] || { echo "已取消"; return 0; }
    i=$((REPLY - 1))
    confirm "确认删除 ${names[$i]:-?}（${ips[$i]}）？" n || return 0
    awk -v key="${keys[$i]}" '
        function flush() { if (buf != "" && !drop) printf "%s", buf; buf = ""; drop = 0 }
        /^\[Peer\]/ { flush() }
        { buf = buf $0 "\n"; if ($0 ~ "^PublicKey *= *" && index($0, key)) drop = 1 }
        END { flush() }' "$WG_DIR/$IFACE.conf" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$WG_DIR/$IFACE.conf.new"
    chmod 600 "$WG_DIR/$IFACE.conf.new"
    mv "$WG_DIR/$IFACE.conf.new" "$WG_DIR/$IFACE.conf"
    wg set "$IFACE" peer "${keys[$i]}" remove 2>/dev/null || true
    info "已删除 ${names[$i]:-?}"
}

# ---------------------------------------------------------------- 客户端
install_client() {
    install_wg
    hr; echo "${B}安装客户端${N}（本机有没有公网 IP 都可以）"
    echo "先在服务端运行 sudo bash wg.sh →「添加客户端」，拿到以 WGI1: 开头的邀请码"; hr

    while :; do
        ask "粘贴邀请码" ""
        unset C_v C_endpoint C_pubkey C_server_ip C_client_ip
        decode WGI1: "$REPLY" || { echo "邀请码不对：请复制服务端显示的以 WGI1: 开头的整行"; continue; }
        valid_key "${C_pubkey:-}" && [ -n "${C_endpoint:-}" ] && [ -n "${C_server_ip:-}" ] && [ -n "${C_client_ip:-}" ] \
            || { echo "邀请码内容不完整"; continue; }
        break
    done
    echo "  服务端：$C_endpoint（隧道地址 $C_server_ip）  本机将使用隧道地址：$C_client_ip"

    local existing; existing=$(grep -l "^PublicKey *= *${C_pubkey}$" "$WG_DIR"/*.conf 2>/dev/null | head -1 || true)
    [ -z "$existing" ] || die "本机已经连着这个服务端了（$existing）。要重装先「卸载」它"
    local_addrs | grep -q "^${C_client_ip}/" && die "本机已经有地址 $C_client_ip：服务端换个网段重新安装"
    local route; route=$(ip -4 route show to match "$C_server_ip" | grep -v '^default' || true)
    [ -z "$route" ] || die "到 $C_server_ip 已经有路由（$route），会冲突：服务端换个网段重新安装"

    local def; def=$(free_iface)
    while :; do
        ask "接口名称" "$def"; IFACE="$REPLY"
        valid_iface "$IFACE" || { echo "只能用字母数字 _ -，最长 15 个字符"; continue; }
        iface_taken "$IFACE" && { echo "$IFACE 已存在，换一个"; continue; }
        break
    done
    ask "本机名称（服务端列表里显示）" "$(hostname -s 2>/dev/null || echo client)"
    local name="${REPLY//[^A-Za-z0-9._-]/}"

    umask 077
    mkdir -p "$WG_DIR"
    local priv pub
    priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)
    cat > "$WG_DIR/$IFACE.conf" <<EOF
$MARK
# wg.sh role=client
[Interface]
Address = $C_client_ip/32
PrivateKey = $priv

[Peer]
# name: server
PublicKey = $C_pubkey
Endpoint = $C_endpoint
AllowedIPs = $C_server_ip/32
PersistentKeepalive = $KEEPALIVE
EOF
    chmod 600 "$WG_DIR/$IFACE.conf"
    start_iface "$IFACE"

    hr
    echo "把下面的${B}回复码${N}粘贴回服务端（只含本机公钥，不含私钥）："
    echo
    encode WGR1: v=1 pubkey="$pub" ip="$C_client_ip" name="${name:-client}"
    echo
    hr
    info "等待服务端添加本机…（最多 5 分钟，Ctrl+C 退出不影响，之后会自动连上）"
    if wait_handshake "$IFACE" "$C_pubkey" 300; then
        info "${G}握手成功${N}：本机 $C_client_ip <-> 服务端 $C_server_ip"
        ping -c 1 -W 2 "$C_server_ip" >/dev/null 2>&1 && info "ping $C_server_ip 正常" || true
        echo "只有发往 $C_server_ip 的流量走隧道，本机默认路由不变。"
    else
        warn "还没有握手。确认服务端已粘贴回复码、安全组放行了 UDP；配置已保存，连通后自动生效。稍后用「查看状态」确认"
    fi
}

# ---------------------------------------------------------------- 状态 / 卸载
status() {
    local ifs; ifs=$(managed_ifaces)
    [ -n "$ifs" ] || { echo "本机还没有用 wg.sh 安装的接口"; return 0; }
    local f role addr up
    for f in $ifs; do
        role=$(meta "$f" role); addr=$(sed -n 's/^Address *= *//p' "$WG_DIR/$f.conf" | head -1)
        if ip link show "$f" >/dev/null 2>&1; then up="${G}运行中${N}"; else up="${R}未运行${N}"; fi
        hr
        if [ "$role" = server ]; then
            echo "${B}$f${N}  服务端  $addr  $(meta "$f" endpoint)  $up"
        else
            echo "${B}$f${N}  客户端  $addr  $up"
        fi
        awk '/^\[Peer\]/{n="";k=""} /^# name:/{sub(/^# name: */,"");n=$0} /^PublicKey/{sub(/^PublicKey *= */,"");k=$0}
             /^AllowedIPs/{sub(/^AllowedIPs *= */,""); print k"|"n"|"$0}' "$WG_DIR/$f.conf" |
        while IFS='|' read -r k n a; do
            printf '    %-16s %-20s 最近握手：%s\n' "${n:-?}" "$a" "$(human_age "$(handshake_age "$f" "$k")")"
        done
    done
    hr
}

uninstall() {
    pick_iface any || { echo "本机没有用 wg.sh 安装的接口"; return 0; }
    local role port
    role=$(meta "$IFACE" role)
    confirm "确认卸载 $IFACE（$role）？配置和密钥会被删除" n || return 0
    port=$(sed -n 's/^ListenPort *= *//p' "$WG_DIR/$IFACE.conf" | head -1)
    systemctl disable --now "wg-quick@$IFACE" >/dev/null 2>&1 || true
    ip link del "$IFACE" 2>/dev/null || true
    rm -f "$WG_DIR/$IFACE.conf"
    [ -n "$port" ] && close_firewall "$port"
    info "已卸载 $IFACE（wireguard-tools 软件包保留）"
    [ "$role" = server ] && echo "客户端那边也要各自卸载对应的接口"
    return 0
}

# ---------------------------------------------------------------- 菜单
menu() {
    echo
    echo "${B}wg.sh $VERSION${N} - WireGuard 组网"
    echo "  1) 安装服务端（本机有公网 IP）"
    echo "  2) 安装客户端（本机有没有公网 IP 都行）"
    echo "  3) 添加客户端（在服务端上）"
    echo "  4) 删除客户端（在服务端上）"
    echo "  5) 查看状态"
    echo "  6) 卸载"
    echo "  0) 退出"
    ask "请选择" ""
    case "$REPLY" in
        1) install_server ;;
        2) install_client ;;
        3) add_client ;;
        4) remove_client ;;
        5) status ;;
        6) uninstall ;;
        0|q|"") exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

case "${1:-}" in
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -v|--version) echo "$VERSION"; exit 0 ;;
    status) need_root; status; exit 0 ;;
esac
need_root
menu
