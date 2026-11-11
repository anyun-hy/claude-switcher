#!/bin/bash
# Claude 保镖 (参考模板) —— 安装程序会把 __HOME__ / __PROXY_MODE__ 替换为实际值后安装
# 作用: 代理(内核或TUN)离线时,自动关闭 Claude(桌面版与 Claude Code CLI),杜绝裸连重试
LOG="__HOME__/Library/Logs/claude-bodyguard.log"
MODE="__PROXY_MODE__"
HOME_DIR="__HOME__"
HEALTH_SCHEMA=1
HEALTH_ERROR=0
HEALTH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
HEALTH_FILE="$HEALTH_DIR/claude-bodyguard-health"

# A completion heartbeat is published next to the installed root-owned script,
# never in a user-writable home directory. Fixture copies write beside themselves.
record_health() {
    local rc=$? result=ok tmp
    trap - EXIT
    [ "$rc" -eq 0 ] && [ "$HEALTH_ERROR" -eq 0 ] || result=error
    tmp=$(mktemp "$HEALTH_DIR/.claude-bodyguard-health.XXXXXX") || exit 1
    if ! {
        printf 'schema=1\ntime=%s\nmode=%s\nresult=%s\n' "$(date +%s)" "$MODE" "$result" > "$tmp" &&
        chmod 644 "$tmp" &&
        mv -f "$tmp" "$HEALTH_FILE"
    }; then
        rm -f "$tmp"
        exit 1
    fi
    exit "$rc"
}
trap record_health EXIT

# 安装用户 UID: root 守护从 __HOME__ 属主推导,只处理该用户的受保护进程。
# 推导失败宁可不杀,也不按进程名全系统扫描(避免误伤其他用户与 claude-switcher 自身)。
if [ "$(id -u)" -eq 0 ]; then
    INSTALL_UID=$(stat -f %u "$HOME_DIR" 2>/dev/null || id -u "${HOME_DIR##*/}" 2>/dev/null)
else
    INSTALL_UID=$(id -u)
fi
case "$INSTALL_UID" in ''|*[!0-9]*) HEALTH_ERROR=1 ;; esac

# Keep the process probe and classifier in sync with core/claude-switch.sh.
# macOS ps comm can report argv[0]. Use the kernel's executable path instead.
macos_process_paths() {
    /usr/bin/python3 -I -S -B - <<'PY'
import ctypes
import sys

lib = ctypes.CDLL("/usr/lib/libproc.dylib")
lib.proc_listallpids.argtypes = (ctypes.c_void_p, ctypes.c_int)
lib.proc_listallpids.restype = ctypes.c_int
lib.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
lib.proc_pidpath.restype = ctypes.c_int
count = lib.proc_listallpids(None, 0)
if count <= 0:
    sys.exit(1)
pids = (ctypes.c_int * (count + 256))()
count = lib.proc_listallpids(pids, ctypes.sizeof(pids))
if not 0 < count < len(pids):
    sys.exit(1)
buf = ctypes.create_string_buffer(4096)
readable = False
for pid in pids[:count]:
    if pid <= 0 or lib.proc_pidpath(pid, buf, len(buf)) <= 0:
        continue
    path = buf.value
    if path.startswith(b"/") and not any(c in path for c in (b"\t", b"\r", b"\n")):
        sys.stdout.buffer.write(str(pid).encode() + b"\t" + path + b"\n")
        readable = True
sys.exit(0 if readable else 1)
PY
}

proxy_processes() {
    local paths
    paths=$(macos_process_paths 2>/dev/null) || return 1
    printf '%s\n' "$paths" | awk -F '\t' '
        NF == 2 && $1 ~ /^[1-9][0-9]*$/ && $2 ~ /^\// {
            name = $2; sub(/^.*\//, "", name)
            if ($2 == "/Applications/TAG.app/Contents/Resources/bin/mihomo-universal-tag-darwin") mode = "tag"
            else if (name ~ /^verge-mihomo(-[[:alnum:]_.-]+)?$/) mode = "clash-verge"
            else if (name == "FlClashCore" || name == "FlClash") mode = "flclash"
            else if (name == "BettboxCore" || name == "Bettbox") mode = "bettbox"
            else if (name == "sing-box") mode = "sing-box"
            else if (name ~ /^ClashX( Pro| Meta)?$/) mode = "clashx"
            else if (name == "Surge" || $2 ~ /\/Surge[.]app\/Contents\//) mode = "surge"
            else next
            printf "%s\t%s\n", mode, $1
        }'
}

proxy_seen() {
    [[ $'\n'$1 == *$'\n'"$2"$'\t'* ]]
}

reasons=""
guard_reason() { reasons="${reasons:+$reasons;}$1"; }

# Retain the existing one-TUN rule. Probe failure is distinct from missing TUN.
if interfaces=$(ifconfig 2>/dev/null); then
    tcnt=$(printf '%s\n' "$interfaces" | grep -c 'inet 198\.18\.')
    case "$tcnt" in
        1) ;;
        0) guard_reason 'TUN未在线' ;;
        *) guard_reason "多TUN=$tcnt" ;;
    esac
else
    HEALTH_ERROR=1
    guard_reason 'TUN核验失败'
fi

# auto remains TUN-only. Other modes use the same executable inventory as core.
if [ "$MODE" != "auto" ]; then
    case "$MODE" in
        tag|clash-verge|flclash|bettbox|sing-box|clashx|surge) expected_mode="$MODE" ;;
        shadowrocket) expected_mode="" ;;
        *) expected_mode="clash-verge" ;;
    esac
    if processes=$(proxy_processes); then
        if [ -n "$expected_mode" ] && ! proxy_seen "$processes" "$expected_mode"; then
            guard_reason "代理内核未运行=$expected_mode"
        fi
        conflicts=""
        while IFS=$'\t' read -r client pid; do
            if [ -n "$client" ] && [ "$client" != "$MODE" ]; then
                conflicts="${conflicts:+$conflicts/}$client:$pid"
            fi
        done <<< "$processes"
        [ -z "$conflicts" ] || guard_reason "多代理=$conflicts"
    else
        HEALTH_ERROR=1
        guard_reason '代理进程核验失败'
    fi
    if [ "$MODE" = "shadowrocket" ]; then
        # If launchd cannot see the VPN row, retain the existing TUN fallback.
        nc=$(scutil --nc list 2>/dev/null)
        if printf '%s\n' "$nc" | grep -q 'com.liguangming.Shadowrocket'; then
            printf '%s\n' "$nc" | grep 'com.liguangming.Shadowrocket' | grep -q '(Connected)' ||
                guard_reason 'Shadowrocket未连接'
        fi
    fi
fi

# A fresh kernel path snapshot identifies actual targets. Only Node/Bun needs
# the command line, to match the existing Claude Code package entry point.
guard_targets() {
    local rows paths
    rows=$(ps -axww -o pid=,uid=,args= 2>/dev/null) || return 1
    paths=$(macos_process_paths 2>/dev/null) || return 1
    { printf '%s\n' "$paths"; printf '%s\n' '--'; printf '%s\n' "$rows"; } |
        awk -v uid="$INSTALL_UID" '
            $0 == "--" { args = 1; next }
            !args {
                tab = index($0, "\t")
                if (tab) paths[substr($0, 1, tab - 1)] = substr($0, tab + 1)
                next
            }
            $1 ~ /^[1-9][0-9]*$/ && $2 == uid && ($1 in paths) {
                path = paths[$1]
                name = path; sub(/^.*\//, "", name)
                if (path == "/Applications/Claude.app/Contents/MacOS/Claude")
                    printf "Claude\t%s\n", $1
                else if (name == "claude" || name == "claude.exe" ||
                         ((name == "node" || name == "bun") &&
                          $4 ~ /(^|\/)@anthropic-ai\/claude-code\/(bin\/claude(\.exe)?|cli\.js)$/))
                    printf "Claude Code CLI\t%s\n", $1
            }'
}

if [ -n "$reasons" ]; then
    case "$INSTALL_UID" in
        ''|*[!0-9]*) ;;
        *)
            if targets=$(guard_targets); then
                while IFS=$'\t' read -r target pid; do
                    [ -n "$pid" ] || continue
                    # Do not signal a vanished process or a different user's PID.
                    owner=$(ps -p "$pid" -o uid= 2>/dev/null) || continue
                    [ "${owner//[[:space:]]/}" = "$INSTALL_UID" ] || continue
                    if kill -TERM "$pid" 2>/dev/null; then
                        result='已发送终止信号'
                    else
                        HEALTH_ERROR=1
                        result='发送失败'
                    fi
                    printf '%s 保镖处置(%s),目标=%s,pid=%s,结果=%s\n' \
                        "$(date '+%Y-%m-%d %H:%M:%S')" "$reasons" "$target" "$pid" "$result" >>"$LOG" ||
                        HEALTH_ERROR=1
                done <<< "$targets"
            else
                HEALTH_ERROR=1
            fi
            ;;
    esac
fi
[ "$HEALTH_ERROR" -eq 0 ] || exit 1
exit 0
