#!/bin/sh
# proxy-net-tune 1.2.0 — Debian / Ubuntu / Alpine TCP servers; interactive menu or CLI.
# POSIX launcher; Python standard library only. No downloads or package upgrades.
if ! command -v python3 >/dev/null 2>&1; then
    echo '需要 Python 3.9+。Debian / Ubuntu: apt-get install python3 iproute2' >&2
    echo 'Alpine: apk add python3 iproute2' >&2
    exit 1
fi
# Stable path/locale for root and boot services. Download to a file before --apply.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# Keep the original stdin for menu input; Python reads its code from the heredoc.
exec python3 -X utf8 - "$0" "$@" 3<&0 <<'PROXY_NET_TUNE_PY'
import argparse
import base64
import contextlib
import datetime
import fnmatch
try:
    import fcntl
except ImportError:
    fcntl = None
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

VERSION = "1.2.0"
NAME = "proxy-net-tune"
MARKER = "Managed by proxy-net-tune"
STATE = "/var/lib/proxy-net-tune"
CONFIG = "/etc/proxy-net-tune.json"
SYSCTL = "/etc/sysctl.d/90-proxy-net-tune.conf"
PROGRAM = "/usr/local/sbin/proxy-net-tune"
UNIT = "/etc/systemd/system/proxy-net-tune.service"
INIT = "/etc/init.d/proxy-net-tune"
MODULES = "/etc/modules-load.d/proxy-net-tune.conf"
MIB = 1024 * 1024
SYSTEMD_DISTROS = {"debian", "ubuntu"}

# Exact legacy values only. Routing/swap/logging/process limits are excluded.
LEGACY_TEXT = """
net.core.rmem_max=536870912
net.core.wmem_max=536870912
net.core.optmem_max=67108864
net.core.netdev_max_backlog=4096000
net.core.default_qdisc=fq_pie
net.core.somaxconn=255840
net.ipv4.tcp_rmem=262144 4194304 536870912
net.ipv4.tcp_wmem=262144 4194304 536870912
net.ipv4.tcp_abort_on_overflow=1
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_mtu_probing=2
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_autocorking=0
net.ipv4.tcp_ecn=0
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=30
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_max_tw_buckets=63960
net.ipv4.tcp_notsent_lowat=16384
net.netfilter.nf_conntrack_generic_timeout=10
net.netfilter.nf_conntrack_icmp_timeout=2
net.netfilter.nf_conntrack_tcp_max_retrans=2
net.netfilter.nf_conntrack_tcp_timeout_close=2
net.netfilter.nf_conntrack_tcp_timeout_close_wait=2
net.netfilter.nf_conntrack_tcp_timeout_established=300
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=2
net.netfilter.nf_conntrack_tcp_timeout_last_ack=2
net.netfilter.nf_conntrack_tcp_timeout_max_retrans=2
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=2
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=2
net.netfilter.nf_conntrack_tcp_timeout_time_wait=60
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=2
net.netfilter.nf_conntrack_udp_timeout=2
net.netfilter.nf_conntrack_udp_timeout_stream=30
"""
# Conservative repair values, NOT a reconstruction of the original values.
REPAIR_TEXT = """
net.core.optmem_max=65536
net.core.netdev_max_backlog=1000
net.core.somaxconn=4096
net.ipv4.tcp_abort_on_overflow=0
net.ipv4.tcp_syn_retries=6
net.ipv4.tcp_synack_retries=5
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_no_metrics_save=0
net.ipv4.tcp_autocorking=1
net.ipv4.tcp_ecn=2
net.ipv4.tcp_fin_timeout=60
net.ipv4.tcp_keepalive_time=7200
net.ipv4.tcp_keepalive_intvl=75
net.ipv4.tcp_keepalive_probes=9
net.ipv4.tcp_slow_start_after_idle=1
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_max_tw_buckets=65536
net.ipv4.tcp_notsent_lowat=4294967295
net.netfilter.nf_conntrack_generic_timeout=600
net.netfilter.nf_conntrack_icmp_timeout=30
net.netfilter.nf_conntrack_tcp_max_retrans=3
net.netfilter.nf_conntrack_tcp_timeout_close=10
net.netfilter.nf_conntrack_tcp_timeout_close_wait=60
net.netfilter.nf_conntrack_tcp_timeout_established=432000
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=120
net.netfilter.nf_conntrack_tcp_timeout_last_ack=30
net.netfilter.nf_conntrack_tcp_timeout_max_retrans=300
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=60
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=120
net.netfilter.nf_conntrack_tcp_timeout_time_wait=120
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=300
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=120
"""
LEGACY = dict(line.split("=", 1) for line in LEGACY_TEXT.strip().splitlines())
REPAIR = dict(line.split("=", 1) for line in REPAIR_TEXT.strip().splitlines())
FINGERPRINT = {"net.core.netdev_max_backlog", "net.core.somaxconn",
               "net.core.optmem_max", "net.ipv4.tcp_rmem", "net.ipv4.tcp_wmem",
               "net.netfilter.nf_conntrack_tcp_timeout_established"}


# Captured from the URL supplied by the user, 2026-09-11. Require the full
# characteristic fixed subset AND consistent dynamic TCP/core buffer values.
UPSTREAM_FIXED = dict(line.split("=", 1) for line in """
net.core.default_qdisc=fq_pie
net.ipv4.tcp_abort_on_overflow=1
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=10
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_max_syn_backlog=16384
net.ipv4.tcp_congestion_control=bbr
net.netfilter.nf_conntrack_tcp_timeout_established=300
net.netfilter.nf_conntrack_udp_timeout=2
net.netfilter.nf_conntrack_udp_timeout_stream=30
""".strip().splitlines())
UPSTREAM_SAFE = dict(UPSTREAM_FIXED, **{
    "net.ipv4.tcp_slow_start_after_idle": "0", "net.ipv4.tcp_mtu_probing": "1",
    "net.ipv4.tcp_fack": "1"})


def legacy_rows(rows):
    exact = {k: v for _, k, v in rows}
    hits = {k for _, k, v in rows if LEGACY.get(k) == v}
    if len(hits & FINGERPRINT) >= 4:
        return {(k, v) for _, k, v in rows if LEGACY.get(k) == v}
    if not all(exact.get(k) == v for k, v in UPSTREAM_FIXED.items()):
        return set()
    for core, tcp, default in (("rmem", "tcp_rmem", "87380"), ("wmem", "tcp_wmem", "65536")):
        maximum = exact.get("net.core." + core + "_max", "")
        if not maximum.isdigit() or int(maximum) <= 0 or exact.get("net.ipv4." + tcp) != "4096 " + default + " " + maximum:
            return set()
    dynamic = {"net.core.rmem_max", "net.core.wmem_max", "net.core.netdev_max_backlog",
               "net.core.somaxconn", "net.ipv4.tcp_rmem", "net.ipv4.tcp_wmem", "net.ipv4.tcp_max_tw_buckets"}
    return {(k, v) for _, k, v in rows if UPSTREAM_SAFE.get(k) == v or
            (k in dynamic and v == exact[k] and all(x.isdigit() for x in v.split()))}


class Error(Exception):
    pass


def norm(value):
    return " ".join(str(value).split())


def run(args, check=True):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
    if check and p.returncode:
        raise Error("命令失败: {}\n{}".format(shlex.join(args), p.stderr.strip()))
    return p


def procpath(key):
    return Path("/proc/sys") / key.replace(".", "/")


def readkey(key):
    return norm(procpath(key).read_text())


def writekey(key, value):
    # Avoid differences between BusyBox and procps sysctl.
    procpath(key).write_text(str(value) + "\n")
    if readkey(key) != norm(value):
        raise Error("内核未接受参数 {}={}".format(key, value))


def os_id():
    data = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v.strip("\"'")
    distro = data.get("ID", "")
    if distro not in SYSTEMD_DISTROS | {"alpine"}:
        raise Error("仅支持 Debian / Ubuntu / Alpine；检测到 " + distro)
    return distro


def memory_bytes():
    total = int(re.search(r"^MemTotal:\s+(\d+)", Path("/proc/meminfo").read_text(), re.M)[1]) * 1024
    memberships = [line.split(":", 2) for line in Path("/proc/self/cgroup").read_text().splitlines()]
    mounts = []
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        left, right = line.split(" - ", 1)
        fields, fs = left.split(), right.split()
        if fs[0] == "cgroup2" or (fs[0] == "cgroup" and "memory" in fs[2].split(",")):
            decode = lambda s: re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), s)
            mounts.append((fs[0], PurePosixPath(decode(fields[3])), Path(decode(fields[4]))))
    for _, controllers, relative in memberships:
        version = "cgroup2" if not controllers else "cgroup"
        if controllers and "memory" not in controllers.split(","):
            continue
        for kind, root, base in mounts:
            if kind != version:
                continue
            member = PurePosixPath(relative)
            try:
                suffix = member.relative_to(root)
            except ValueError:
                # Namespaced cgroups expose membership / but a host-relative mount root.
                suffix = PurePosixPath(relative.lstrip("/"))
            parts = suffix.parts if ".." not in suffix.parts else ()
            filename = "memory.max" if kind == "cgroup2" else "memory.limit_in_bytes"
            for i in range(len(parts), -1, -1):
                try:
                    raw = base.joinpath(*parts[:i], filename).read_text().strip()
                    if raw.isdigit():
                        total = min(total, int(raw))
                except FileNotFoundError:
                    pass
    if total < 64 * MIB:
        raise Error("有效内存小于 64 MiB，不自动部署；请检查容器内存限制")
    return total

def make_profile(mem, bandwidth=None, rtt=None, cc="bbr"):
    if cc == "keep":
        cc = readkey("net.ipv4.tcp_congestion_control")
    # Per-socket ceilings, not reservations or a global network-memory budget.
    cap = min(32 * MIB, max(2 * MIB, mem // 32))
    warning = None
    if bandwidth is not None:
        target = math.ceil(bandwidth * 1_000_000 / 8 * rtt / 1000 * 2)
        ceiling = min(128 * MIB, max(2 * MIB, mem // 16))
        cap = min(ceiling, max(2 * MIB, target))
        if target > ceiling:
            warning = "2×带宽延迟积超过内存保护上限；高延迟单连接可能无法跑满带宽"
    cap = cap // 4096 * 4096
    return {
        "net.core.default_qdisc": "fq", "net.ipv4.tcp_congestion_control": cc,
        "net.core.rmem_max": str(cap), "net.core.wmem_max": str(cap),
        "net.ipv4.tcp_rmem": "4096 131072 " + str(cap),
        "net.ipv4.tcp_wmem": "4096 16384 " + str(cap),
        "net.ipv4.tcp_moderate_rcvbuf": "1",
    }, warning


def assignments(text):
    out = []
    for number, line in enumerate(text.splitlines()):
        m = re.match(r"^\s*-?\s*([A-Za-z0-9_./*?\[\]!-]+)\s*=\s*(.*?)\s*(?:[#;].*)?$", line)
        if m:
            out.append((number, m[1].replace("/", "."), norm(m[2])))
    return out


def config_sources():
    # Resolve same-basename precedence; still inspect /etc/sysctl.conf for both loaders.
    selected, found = {}, {}
    for directory in ("/lib/sysctl.d", "/usr/lib/sysctl.d", "/usr/local/lib/sysctl.d",
                      "/run/sysctl.d", "/etc/sysctl.d"):
        for path in sorted(Path(directory).glob("*.conf")):
            if path.is_file() or path.is_symlink():
                selected[path.name] = path
    for path in selected.values():
        if path.is_file():
            found[str(path.resolve())] = path.resolve()
    p = Path("/etc/sysctl.conf")
    if p.is_file():
        found[str(p.resolve())] = p.resolve()
    return list(found.values())


def scan_configs(desired, repair=False):
    edits, matched, warnings = {}, set(), []
    for path in config_sources():
        if path == Path(SYSCTL):
            if MARKER not in path.read_text():
                raise Error("已有同名非本脚本配置: " + str(path))
            continue
        text = path.read_text()
        rows = assignments(text)
        retired = legacy_rows(rows)
        recognized = bool(retired)
        if recognized and not repair:
            raise Error("识别到旧 optimize.sh / optimize_fix 配置: {}；请先 --plan --repair-legacy".format(path))
        lines = text.splitlines(keepends=True)
        for number, key, value in rows:
            removable = recognized and repair and (key, value) in retired
            if removable:
                if not str(path).startswith("/etc/"):
                    raise Error("旧配置位于非 /etc 路径，拒绝自动编辑: " + str(path))
                lines[number] = "# proxy-net-tune: retired legacy: " + lines[number]
                matched.add(key)
            elif any(fnmatch.fnmatchcase(k, key) and value != norm(v) for k, v in desired.items()):
                if str(path).startswith(("/usr/", "/lib/")) and path.name < Path(SYSCTL).name:
                    warnings.append("将覆盖优先级较低的发行版默认项: {}:{}".format(path, number + 1))
                    continue
                raise Error("存在冲突配置 {}:{}: {}={}；不会覆盖未知设置".format(path, number + 1, key, value))
        if lines != text.splitlines(keepends=True):
            edits[str(path)] = "".join(lines)
        if recognized:
            warnings.append("旧脚本的路由/转发、swap、全局文件限制、conntrack 容量及日志设置仍保留；不猜测原值。")
    runtime_hits = sum(procpath(k).exists() and readkey(k) == LEGACY[k] for k in FINGERPRINT)
    if runtime_hits >= 4 and not matched and not Path(CONFIG).exists():
        raise Error("运行值疑似旧脚本，但未找到可识别配置来源；拒绝猜测修复，请先定位配置")
    return edits, matched, warnings


def interfaces(explicit):
    names = list(explicit)
    if not explicit:
        for family in ("-4", "-6"):
            p = run(["ip", "-j", family, "route", "show", "table", "main", "default"])
            for route in json.loads(p.stdout):
                if route.get("dev"):
                    names.append(route["dev"])
                names.extend(h["dev"] for h in route.get("nexthops", []) if h.get("dev"))
    names = list(dict.fromkeys(names))
    if not names:
        raise Error("主路由表没有默认出口；请用 --interface 指定实际出口（可重复）")
    for name in names:
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", name) or name == "lo":
            raise Error("不支持的出口名称: " + name)
        if not (Path("/sys/class/net") / name).exists():
            raise Error("网卡不存在: " + name)
    return names


def qdisc_plan(dev, text):
    """Preserve mq and ingress. Refuse unknown/classful egress hierarchies."""
    rows = [shlex.split(line) for line in text.splitlines() if line.strip()]
    rows = [r for r in rows if len(r) >= 4 and r[0] == "qdisc"]
    egress = [r for r in rows if r[1] not in ("ingress", "clsact")]
    roots = [r for r in egress if "root" in r]
    if len(roots) != 1:
        raise Error(dev + ": 无法确定唯一根队列")
    root = roots[0]
    if root[1] == "mq":
        targets = [r for r in egress if r is not root]
        major = root[2].split(":")[0].lstrip("0")
        parents = set()
        if not targets:
            raise Error(dev + ": mq 没有可见叶子队列")
        for row in targets:
            if "parent" not in row or row[row.index("parent") + 1].split(":")[0].lstrip("0") != major:
                raise Error(dev + ": 非直接 mq 叶子，拒绝覆盖")
            parent = row[row.index("parent") + 1]
            if not re.fullmatch(r"[0-9a-fA-F]{0,4}:[0-9a-fA-F]{1,4}", parent):
                raise Error(dev + ": 无效的 mq 叶子编号")
            minor = int(parent.split(":")[1], 16)
            if not minor or minor in parents:
                raise Error(dev + ": mq 叶子编号为零或重复")
            parents.add(minor)
    else:
        if len(egress) != 1:
            raise Error(dev + ": 存在子队列，拒绝覆盖")
        targets = [root]
    actions = []
    for row in targets:
        kind, handle = row[1:3]
        if kind == "fq":
            if "nopacing" in row:
                raise Error(dev + ": 已有 fq 禁用了 pacing，请先人工检查")
            continue
        if kind not in ("fq_codel", "pfifo_fast", "noqueue"):
            raise Error(dev + ": 已有 " + kind + " 队列；保留限速/整形，停止执行")
        position = ["root"] if "root" in row else ["parent", row[row.index("parent") + 1]]
        base = ["tc", "qdisc", "replace", "dev", dev] + position
        apply = base + ["fq", "pacing"]
        if kind == "noqueue":
            if position != ["root"]:
                raise Error(dev + ": 不支持 mq 内的 noqueue")
            undo = ["tc", "qdisc", "del", "dev", dev, "root"]
        elif kind == "pfifo_fast":
            if "bands" in row and row[row.index("bands") + 1] != "3":
                raise Error(dev + ": 非标准 pfifo_fast bands，拒绝覆盖")
            if "priomap" in row and row[row.index("priomap") + 1:] != "1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1".split():
                raise Error(dev + ": 非标准 pfifo_fast，拒绝覆盖")
            undo = base + ["handle", handle, kind]
        else:
            start = row.index("root") + 1 if position == ["root"] else row.index("parent") + 2
            opts = row[start:]
            if opts[:1] == ["refcnt"]:
                opts = opts[2:]
            singles = {"ecn", "noecn"}
            pairs = {"limit", "flows", "quantum", "target", "interval", "memory_limit",
                     "ce_threshold", "drop_batch", "ce_threshold_selector"}
            i = 0
            while i < len(opts):
                if opts[i] in singles:
                    i += 1
                elif opts[i] in pairs and i + 1 < len(opts):
                    if opts[i] == "limit":
                        opts[i + 1] = opts[i + 1].removesuffix("p")
                    i += 2
                else:
                    raise Error(dev + ": 无法可靠恢复 fq_codel 参数: " + " ".join(opts))
            undo = base + ["handle", handle, kind] + opts
        actions.append({"dev": dev, "apply": apply, "undo": undo, "position": position})
    if root[1] == "mq" and not major and actions:
        # Built-in mq 0: is not in the qdisc handle lookup table: parent :N
        # is display output, not an address tc can use to graft a child.
        # Recreate mq with an unused handle AFTER setting default_qdisc=fq.
        # mq_init creates its children from that default; verify checks them.
        root_opts = root[root.index("root") + 1:]
        if root_opts[:1] == ["refcnt"]:
            root_opts = root_opts[2:]
        if root_opts:
            raise Error(dev + ": mq 根队列包含未知参数，拒绝重建")
        if len(actions) != len(targets):
            raise Error(dev + ": 默认 mq 0: 混有已配置的 fq；无法完整保留其参数，拒绝重建")
        used = {int(r[2].split(":")[0] or "0", 16) for r in rows}
        available = next((n for n in range(1, 0xffff) if n not in used), None)
        if available is None:
            raise Error(dev + ": 没有可用的 mq 根队列句柄")
        handle = format(available, "x") + ":"
        command = ["tc", "qdisc", "replace", "dev", dev, "root", "handle", handle, "mq"]
        restore = []
        for action in actions:
            undo = list(action["undo"])
            i = undo.index("parent") + 1
            undo[i] = handle + undo[i].split(":")[1]
            restore.append(undo)
        return [{"dev": dev, "apply": command, "undo": list(command),
                 "undo_followups": restore, "position": ["root"],
                 "filter_positions": [a["position"] for a in actions],
                 "expected_before": text, "requires_default_fq": True,
                 "note": "重建默认 mq 0: 为 mq " + handle +
                         "，子队列使用已设置的 default_qdisc=fq；保留多队列结构"}]
    return actions


def plan_qdiscs(devices):
    actions = []
    for dev in devices:
        if run(["tc", "filter", "show", "dev", dev, "root"]).stdout.strip():
            raise Error(dev + ": 存在 egress filter，拒绝替换队列")
        output = run(["tc", "qdisc", "show", "dev", dev]).stdout
        planned = qdisc_plan(dev, output)
        for action in planned:
            for position in action.get("filter_positions", [action["position"]]):
                if position[0] == "parent" and run(["tc", "filter", "show", "dev", dev] + position).stdout.strip():
                    raise Error(dev + ": mq 叶子存在 filter，拒绝替换")
        actions.extend(planned)
    return actions

def verify(desired, devices):
    errors = []
    for key, value in desired.items():
        if not procpath(key).exists() or readkey(key) != norm(value):
            errors.append("参数不一致: " + key)
    for dev in devices:
        try:
            if qdisc_plan(dev, run(["tc", "qdisc", "show", "dev", dev]).stdout):
                errors.append(dev + ": 仍有非 fq 出口队列")
        except Error as exc:
            errors.append(str(exc))
    if errors:
        raise Error("验证失败:\n" + "\n".join(errors))


def snap(path):
    p = Path(path)
    if p.is_symlink():
        return {"type": "link", "target": os.readlink(p)}
    if not p.exists():
        return {"type": "absent"}
    s = p.stat()
    if not stat.S_ISREG(s.st_mode):
        raise Error("不是普通文件: " + path)
    return {"type": "file", "data": base64.b64encode(p.read_bytes()).decode(),
            "mode": stat.S_IMODE(s.st_mode), "uid": s.st_uid, "gid": s.st_gid}


def atomic(path, data, mode=0o644, uid=0, gid=0):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".proxy-net-tune-", dir=p.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.chown(tmp, uid, gid)
        os.replace(tmp, p)
        directory_fd = os.open(str(p.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def restore_file(path, old):
    p = Path(path)
    if old["type"] == "file":
        atomic(path, base64.b64decode(old["data"]), old["mode"], old["uid"], old["gid"])
    else:
        if p.exists() or p.is_symlink():
            p.unlink()
        if old["type"] == "link":
            p.parent.mkdir(parents=True, exist_ok=True)
            p.symlink_to(old["target"])


class Transaction:
    def __init__(self, distro, persistent=True):
        self.data = {"version": VERSION, "os": distro, "files": {}, "sysctl": {},
                     "qdiscs": [], "status": "in-progress", "boot_id": boot_id(), "sysctl_after": {}}
        self.directory = None
        if persistent:
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
            self.directory = Path(STATE) / "backups" / (stamp + "-" + str(os.getpid()))
            self.directory.mkdir(parents=True, mode=0o700)
            self.save()

    def save(self):
        if self.directory:
            atomic(str(self.directory / "state.json"), json.dumps(self.data, indent=2).encode(), 0o600)

    def file(self, path, data, mode=None):
        old = snap(path)
        if old["type"] == "link":
            raise Error("拒绝覆盖符号链接: " + path)
        entry = self.data["files"].setdefault(path, {"before": old})
        entry["after"] = {"type": "file", "data": base64.b64encode(data).decode(),
                          "mode": (old.get("mode", 0o644) if mode is None else mode),
                          "uid": old.get("uid", 0), "gid": old.get("gid", 0)}
        self.save()
        if old["type"] == "file":
            atomic(path, data, old["mode"] if mode is None else mode, old["uid"], old["gid"])
        else:
            atomic(path, data, 0o644 if mode is None else mode)
        self.data["files"][path]["after"] = snap(path)
        self.save()

    def link(self, path, target):
        old = snap(path)
        if old != {"type": "absent"} and old != {"type": "link", "target": target}:
            raise Error("启动链接已被其他配置占用: " + path)
        entry = self.data["files"].setdefault(path, {"before": old})
        entry["after"] = {"type": "link", "target": target}
        self.save()
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        if old["type"] == "absent":
            Path(path).symlink_to(target)
        self.data["files"][path]["after"] = snap(path)
        self.save()

    def sysctls(self, desired):
        for key in desired:
            self.data["sysctl"][key] = readkey(key)
        self.data["sysctl_after"] = dict(desired)
        self.save()
        for key, value in desired.items():
            writekey(key, value)

    def qdiscs(self, actions):
        for action in actions:
            action = dict(action)
            action["before"] = run(["tc", "qdisc", "show", "dev", action["dev"]]).stdout
            if action.get("requires_default_fq"):
                if readkey("net.core.default_qdisc") != "fq":
                    raise Error(action["dev"] + ": 重建 mq 前 default_qdisc 必须为 fq")
                if canonical_qdisc(action["before"]) != canonical_qdisc(action["expected_before"]):
                    raise Error(action["dev"] + ": 预览后队列已变化，停止重建 mq")
            self.data["qdiscs"].append(action)
            self.save()
            run(action["apply"])
            action["after"] = run(["tc", "qdisc", "show", "dev", action["dev"]]).stdout
            self.save()

    def finish(self):
        self.data["qdisc_after"] = {
            dev: canonical_qdisc(run(["tc", "qdisc", "show", "dev", dev]).stdout)
            for dev in {a["dev"] for a in self.data["qdiscs"]}
        }
        self.data["status"] = "applied"
        self.save()

    def rollback(self, manual=False, files_only=False):
        if manual:
            if not files_only and self.data.get("boot_id") != boot_id():
                raise Error("备份来自另一次开机或旧版缺少启动标识；请用 --files-only 恢复持久配置后自行重启")
            for path, entry in self.data["files"].items():
                if snap(path) not in (entry["before"], entry.get("after")):
                    raise Error("回滚停止：应用后文件被修改: " + path)
            if not files_only:
                for key, before in self.data["sysctl"].items():
                    after = self.data.get("sysctl_after", {}).get(key)
                    if readkey(key) not in (norm(before), norm(after)):
                        raise Error("回滚停止：内核参数已被其他程序修改: " + key)
                for dev in {a["dev"] for a in self.data["qdiscs"]}:
                    current = run(["tc", "qdisc", "show", "dev", dev]).stdout
                    actions = [a for a in self.data["qdiscs"] if a["dev"] == dev]
                    positions = {("root",)}
                    for line in current.splitlines():
                        words = shlex.split(line)
                        if words[:1] == ["qdisc"] and words[1] not in ("ingress", "clsact") and "parent" in words:
                            positions.add(("parent", words[words.index("parent") + 1]))
                    for position in positions:
                        if run(["tc", "filter", "show", "dev", dev] + list(position)).stdout.strip():
                            raise Error("回滚停止：出口存在 filter，拒绝覆盖: " + dev)
                    expected = [actions[0]["before"]]
                    if self.data["status"] in ("rolling-back", "rollback-incomplete"):
                        expected += [a["before"] for a in actions]
                        expected += [a["rollback_after"] for a in actions if "rollback_after" in a]
                    if "after" in actions[-1]:
                        expected.append(actions[-1]["after"])
                    if not any(qdisc_restored(old, current) for old in expected):
                        raise Error("回滚停止：队列已变化或中断时状态不明确: " + dev +
                                    "；可用 --files-only 恢复持久配置后自行重启")
        errors = []
        self.data["status"] = "rolling-back"
        self.save()
        # Restore default_qdisc before undoing a noqueue replacement.
        for key, value in ([] if files_only else self.data["sysctl"].items()):
            try:
                if readkey(key) != norm(value):
                    writekey(key, value)
            except (OSError, Error) as exc:
                errors.append(str(exc))
        for action in ([] if files_only else reversed(self.data["qdiscs"])):
            try:
                current = run(["tc", "qdisc", "show", "dev", action["dev"]]).stdout
                if not qdisc_restored(action["before"], current):
                    for command in [action["undo"]] + action.get("undo_followups", []):
                        run(command)
                        action["rollback_after"] = run(["tc", "qdisc", "show", "dev", action["dev"]]).stdout
                        self.save()
            except (OSError, Error, subprocess.TimeoutExpired) as exc:
                errors.append(str(exc))
        if not files_only:
            originals = {}
            for action in self.data["qdiscs"]:
                originals.setdefault(action["dev"], action["before"])
            for dev, before in originals.items():
                try:
                    if not qdisc_restored(before, run(["tc", "qdisc", "show", "dev", dev]).stdout):
                        raise Error(dev + ": 队列恢复验证失败")
                except (OSError, Error, subprocess.TimeoutExpired) as exc:
                    errors.append(str(exc))
        for path, entry in reversed(list(self.data["files"].items())):
            try:
                restore_file(path, entry["before"])
            except (OSError, Error) as exc:
                errors.append(str(exc))
        if self.data["os"] in SYSTEMD_DISTROS and self.data["files"]:
            try:
                run(["systemctl", "daemon-reload"])
            except (OSError, Error, subprocess.TimeoutExpired) as exc:
                errors.append(str(exc))
        self.data["status"] = "rollback-incomplete" if errors else (
            "rolled-back-files-only" if files_only else "rolled-back")
        self.save()
        if errors:
            raise Error("部分回滚失败，请保留备份检查:\n" + "\n".join(errors))


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def canonical_qdisc(text):
    return sorted(norm(re.sub(r"\brefcnt\s+\d+\s*", "", line))
                  for line in text.splitlines() if line.strip())


def qdisc_restored(before, current):
    # tc may assign an automatic handle when restoring a built-in handle 0:.
    # Rebuilt mq 0: also needs a nonzero root handle to restore child options.
    # Normalize its direct parent references together, retaining queue numbers.
    rebase_mq = any(r[:3] == ["qdisc", "mq", "0:"] and "root" in r
                    for r in (shlex.split(line) for line in before.splitlines()))
    def rows(text):
        result = {}
        parsed = [shlex.split(line) for line in canonical_qdisc(text)]
        mq_roots = [r for r in parsed if len(r) >= 4 and r[:2] == ["qdisc", "mq"] and "root" in r]
        mq_major = mq_roots[0][2].split(":")[0].lstrip("0") if rebase_mq and len(mq_roots) == 1 else None
        for words in parsed:
            if len(words) < 4 or words[0] != "qdisc":
                return None
            if mq_major is not None and words[1] not in ("ingress", "clsact") and "parent" in words:
                i = words.index("parent") + 1
                major, minor = words[i].split(":", 1)
                if major.lstrip("0") == mq_major:
                    words[i] = ":" + minor
            position = "root" if "root" in words else (
                words[words.index("parent") + 1] if "parent" in words else words[2])
            identity = (position, words[1])
            if identity in result:
                return None
            result[identity] = words
        return result
    old, new = rows(before), rows(current)
    if old is None or new is None or old.keys() != new.keys():
        return False
    for identity, words in old.items():
        actual = list(new[identity])
        if words[2] == "0:":
            actual[2] = "0:"
        if words != actual:
            return False
    return True


def recover(tx, original):
    # Do not let a second Ctrl-C interrupt the recovery half way through.
    handlers = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        tx.rollback()
    except BaseException as rollback_error:
        raise Error("原始错误: {}\n回滚错误: {}\n请保留并检查备份: {}".format(
            original, rollback_error, tx.directory)) from rollback_error
    finally:
        for s, handler in handlers.items():
            signal.signal(s, handler)


@contextlib.contextmanager
def lock():
    Path(STATE).mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(Path(STATE) / "lock", "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Error("另一个 proxy-net-tune 操作正在运行")
        yield


def load_modules(cc):
    if shutil.which("modprobe"):
        for name in ("tcp_" + cc, "sch_fq"):
            run(["modprobe", name], check=False)
    if cc not in readkey("net.ipv4.tcp_available_congestion_control").split():
        raise Error("内核未提供 {}；不自动换内核。可用 --cc cubic 或 --cc keep 重新预览。".format(cc))

def load_settings():
    settings = json.loads(Path(CONFIG).read_text())
    if not isinstance(settings, dict) or settings.get("managed_by") != NAME:
        raise Error("无效的受管配置: " + CONFIG)
    devices, values = settings.get("interfaces"), settings.get("values")
    if not isinstance(devices, list) or not all(isinstance(d, str) for d in devices):
        raise Error("配置 interfaces 必须是网卡名称列表")
    base = make_profile(64 * MIB)[0]
    if not isinstance(values, dict) or not base.keys() <= values.keys() or not values.keys() <= base.keys() | REPAIR.keys():
        raise Error("配置 values 缺少必要参数或包含不受管参数")
    for key, value in values.items():
        if not isinstance(value, str) or value != norm(value):
            raise Error("配置值必须是规范的字符串: " + key)
        if key in REPAIR:
            valid = value == REPAIR[key]
        elif key == "net.core.default_qdisc":
            valid = value == "fq"
        elif key == "net.ipv4.tcp_congestion_control":
            valid = re.fullmatch(r"[A-Za-z0-9_]{1,32}", value)
        else:
            parts = value.split()
            valid = len(parts) == (3 if key in ("net.ipv4.tcp_rmem", "net.ipv4.tcp_wmem") else 1)
            valid = valid and all(p.isdigit() and 0 < int(p) < 2**31 for p in parts)
            if valid and len(parts) == 3:
                valid = list(map(int, parts)) == sorted(map(int, parts))
            if key == "net.ipv4.tcp_moderate_rcvbuf":
                valid = value == "1"
        if not valid:
            raise Error("无效的受管参数值: " + key)
    return settings


def build(args):
    distro, mem = os_id(), memory_bytes()
    preflight_owned(distro)
    desired, warning = make_profile(mem, args.bandwidth_mbps, args.rtt_ms, args.cc)
    edits, matched, warnings = scan_configs(desired, args.repair_legacy)
    for key in sorted(matched & REPAIR.keys()):
        if procpath(key).exists():
            desired[key] = REPAIR[key]
    if Path(CONFIG).exists():
        old = load_settings()
        for key, value in old["values"].items():
            if key in REPAIR and value == REPAIR[key] and procpath(key).exists():
                desired[key] = value
    scan_configs(desired, args.repair_legacy)
    for key in desired:
        if not procpath(key).exists():
            raise Error("当前内核/容器不提供必要参数: " + key)
    devices = interfaces(args.interface)
    actions = plan_qdiscs(devices)
    if warning:
        warnings.append(warning)
    return distro, mem, desired, edits, devices, actions, warnings


def show_plan(result):
    distro, mem, desired, edits, devices, actions, warnings = result
    print("proxy-net-tune {} | {} | kernel {} | 有效内存 {} MiB".format(
        VERSION, distro, os.uname().release, mem // MIB))
    print("出口: " + ", ".join(devices))
    print("以下是保守基线，不是测速结果或最优性能保证：")
    for key, value in desired.items():
        print("  {} = {}  [当前: {}]".format(key, value, readkey(key)))
    for action in actions:
        print("  队列变更: " + shlex.join(action["apply"]))
        if action.get("note"):
            print("    " + action["note"])
    for path in edits:
        print("  仅注释可识别旧调优项: " + path)
    for warning in sorted(set(warnings)):
        print("注意: " + warning)
    cc = desired["net.ipv4.tcp_congestion_control"]
    if cc not in readkey("net.ipv4.tcp_available_congestion_control").split():
        print("注意: {} 尚未注册；--apply 会尝试 modprobe，失败则停止。".format(cc))
    print("注意: 缓冲上限是每个 socket 的上限；连接数多时总内存仍可能耗尽。")
    print("注意: 替换实际出口队列会丢弃排队中的包；请在低峰期应用。BBR 仅影响使用它的 TCP 连接。")


def install(tx, args, distro, desired, source):
    settings = {"managed_by": NAME, "version": VERSION, "interfaces": args.interface,
                "values": desired, "repair_values": {k: v for k, v in desired.items() if k in REPAIR}}
    tx.file(CONFIG, (json.dumps(settings, indent=2) + "\n").encode(), 0o600)
    contents = "# " + MARKER + "; use --rollback to undo.\n"
    contents += "\n".join(k + " = " + v for k, v in desired.items()) + "\n"
    tx.file(SYSCTL, contents.encode())
    tx.file(PROGRAM, source, 0o755)
    if distro in SYSTEMD_DISTROS:
        cc = desired["net.ipv4.tcp_congestion_control"]
        modules = "# " + MARKER + "\nsch_fq\n" + ("tcp_" + cc + "\n" if cc != "reno" else "")
        if any(k.startswith("net.netfilter.nf_conntrack_") for k in desired):
            modules += "nf_conntrack\n"
        tx.file(MODULES, modules.encode())
        unit = """# Managed by proxy-net-tune
[Unit]
Description=TCP tuning and fq for proxy server egress
Wants=network-online.target
After=systemd-modules-load.service systemd-sysctl.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/proxy-net-tune --boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"""
        tx.file(UNIT, unit.encode())
        tx.link("/etc/systemd/system/multi-user.target.wants/proxy-net-tune.service", UNIT)
        run(["systemctl", "daemon-reload"])
    else:
        init = """#!/sbin/openrc-run
# Managed by proxy-net-tune
description="TCP tuning and fq for proxy server egress"
depend() {
    need net
    after sysctl
}
start() {
    ebegin "Applying TCP settings and fq"
    /usr/local/sbin/proxy-net-tune --boot
    eend $?
}
"""
        tx.file(INIT, init.encode(), 0o755)
        tx.link("/etc/runlevels/default/proxy-net-tune", INIT)


def preflight_owned(distro):
    for name in (CONFIG, SYSCTL, PROGRAM, MODULES, UNIT if distro in SYSTEMD_DISTROS else INIT):
        path = Path(name)
        if path.is_symlink():
            raise Error("专用路径是符号链接，拒绝覆盖: " + name)
        if path.exists():
            text = path.read_text()
            owned = (bool(load_settings()) if name == CONFIG else
                     text.startswith("#!/bin/sh\n# proxy-net-tune ") if name == PROGRAM else
                     MARKER in text.splitlines()[:2] or "# " + MARKER in text.splitlines()[:2] or
                     (name == SYSCTL and text.startswith("# " + MARKER + ";")))
            if not owned:
                raise Error("专用路径被其他文件占用: " + name)
    link, target = (("/etc/systemd/system/multi-user.target.wants/proxy-net-tune.service", UNIT)
                    if distro in SYSTEMD_DISTROS else ("/etc/runlevels/default/proxy-net-tune", INIT))
    if snap(link) not in ({"type": "absent"}, {"type": "link", "target": target}):
        raise Error("启动链接已被其他配置占用: " + link)
    if distro in SYSTEMD_DISTROS:
        if not Path("/run/systemd/system").is_dir() or not shutil.which("systemctl"):
            raise Error("需要运行中的 systemd；不支持无主机服务管理器的容器")
    elif not (shutil.which("rc-update") and Path("/run/openrc").is_dir()):
        raise Error("Alpine 需要 OpenRC 主机环境")


def apply(args, source):
    result = build(args)
    show_plan(result)
    distro, _, desired, edits, devices, actions, _ = result
    preflight_owned(distro)
    load_modules(desired["net.ipv4.tcp_congestion_control"])
    tx = Transaction(distro)
    print("备份: " + str(tx.directory), flush=True)
    try:
        for path, data in edits.items():
            tx.file(path, data.encode())
        tx.sysctls(desired)
        tx.qdiscs(actions)
        verify(desired, devices)
        install(tx, args, distro, desired, source)
        verify(desired, devices)
        tx.finish()
    except BaseException as exc:
        print("应用未完成，正在回滚本次改动。", file=sys.stderr, flush=True)
        recover(tx, exc)
        raise
    print("成功：当前内核参数和所选出口 fq 已验证，已安装开机服务。")
    print("已有 TCP socket 不保证切换拥塞算法；应用也可自行覆盖。维护窗口重启代理后用 ss -tin 检查。")
    print("回滚命令: sh {} --rollback {}".format(PROGRAM, tx.directory))


def boot():
    distro = os_id()
    settings = load_settings()
    desired = settings["values"]
    scan_configs(desired)
    load_modules(desired["net.ipv4.tcp_congestion_control"])
    if any(k.startswith("net.netfilter.nf_conntrack_") for k in desired) and shutil.which("modprobe"):
        run(["modprobe", "nf_conntrack"], check=False)
    devices = interfaces(settings["interfaces"])
    actions = plan_qdiscs(devices)
    tx = Transaction(distro, persistent=False)
    try:
        tx.sysctls(desired)
        tx.qdiscs(actions)
        verify(desired, devices)
    except BaseException as exc:
        recover(tx, exc)
        raise
    print("启动验证通过: 受管参数 + fq；出口 " + ", ".join(devices))


def check():
    print("系统: {} | kernel {} | 有效内存 {} MiB".format(os_id(), os.uname().release, memory_bytes() // MIB))
    settings = load_settings() if Path(CONFIG).exists() else None
    devices = interfaces(settings["interfaces"] if settings else [])
    for key in ("net.ipv4.tcp_available_congestion_control", "net.ipv4.tcp_congestion_control",
                "net.core.default_qdisc", "net.ipv4.tcp_rmem", "net.ipv4.tcp_wmem"):
        print(key + " = " + readkey(key))
    for dev in devices:
        print(run(["tc", "-s", "qdisc", "show", "dev", dev]).stdout.rstrip())
    for directory in Path("/proc").iterdir():
        if not directory.name.isdigit():
            continue
        try:
            comm = (directory / "comm").read_text().strip()
            if any(s in comm for s in ("xray", "sing-box", "ss-server", "ssserver", "shadowsocks")):
                limits = (directory / "limits").read_text()
                line = next((x for x in limits.splitlines() if x.startswith("Max open files")), "")
                print("代理进程 {} {}: {}".format(directory.name, comm, line))
        except OSError:
            pass
    if settings:
        verify(settings["values"], devices)
        print("PASS：受管参数与所选出口 fq 一致。进程拥塞算法请另用 ss -tin 检查。")
    else:
        print("尚未安装；上面仅为当前状态。")


def rollback(directory, files_only=False):
    base = (Path(STATE) / "backups").resolve()
    candidates = []
    for p in base.glob("*/state.json"):
        if json.loads(p.read_text()).get("status") in ("applied", "in-progress", "rolling-back", "rollback-incomplete"):
            candidates.append(p.parent.resolve())
    if directory == "latest":
        if not candidates:
            raise Error("没有可回滚的备份")
        chosen = sorted(candidates)[-1]
    else:
        chosen = Path(directory).resolve()
    if chosen.parent != base:
        raise Error("仅接受本机 /var/lib/proxy-net-tune/backups 下的备份")
    data = json.loads((chosen / "state.json").read_text())
    if data.get("status") in ("rolled-back", "rolled-back-files-only"):
        raise Error("这个备份已回滚")
    if not candidates or chosen != sorted(candidates)[-1]:
        raise Error("必须从最新未回滚的备份开始，按时间倒序回滚；可使用 --rollback latest")
    if data.get("os") != os_id():
        raise Error("备份系统类型不匹配")
    tx = Transaction(data["os"], persistent=False)
    tx.directory, tx.data = chosen, data
    tx.rollback(manual=True, files_only=files_only)
    if files_only:
        print("已恢复持久配置，尚未恢复当前内核参数/队列；请在维护窗口自行重启服务器。备份: " + str(chosen))
    else:
        print("已恢复该次运行前的受管文件、内核参数和队列配置。备份保留: " + str(chosen))


def menu_input(stream, prompt):
    print(prompt, end="", flush=True)
    line = stream.readline()
    if not line:
        raise EOFError()
    return line.strip()


def menu_settings(stream):
    cc = menu_input(stream, "拥塞算法 bbr / cubic / keep [bbr]: ") or "bbr"
    if cc not in ("bbr", "cubic", "keep"):
        raise Error("拥塞算法只能是 bbr、cubic 或 keep")
    devices = menu_input(stream, "出口网卡（多个用空格分隔，留空自动检测）: ").split()
    for device in devices:
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", device) or device == "lo":
            raise Error("不支持的出口名称: " + device)
    options = ["--cc", cc]
    for device in devices:
        options.append("--interface=" + device)
    bandwidth = menu_input(stream, "期望单连接带宽 Mbps（留空按内存自动计算）: ")
    if bandwidth:
        rtt = menu_input(stream, "到主要客户端的 RTT 毫秒: ")
        for raw in (bandwidth, rtt):
            try:
                value = float(raw)
            except ValueError:
                raise Error("带宽与 RTT 必须输入数字")
            if not math.isfinite(value) or not 0 < value <= 1_000_000:
                raise Error("带宽与 RTT 必须是 0 到 1000000 之间的有限正数")
        options += ["--bandwidth-mbps", bandwidth, "--rtt-ms", rtt]
    return options


def delete_download(source_path):
    path = Path(source_path).absolute()
    if path.resolve() == Path(PROGRAM).resolve():
        print("已退出；保留开机服务使用的已安装程序: " + PROGRAM)
        return
    if not path.is_file():
        print("已退出；没有可删除的脚本文件。")
        return
    source = path.read_bytes()
    if not source.startswith(b"#!/bin/sh\n# proxy-net-tune ") or not source.rstrip().endswith(b"PROXY_NET_TUNE_PY"):
        raise Error("退出时未删除文件：无法确认它是本脚本: " + str(path))
    path.unlink()
    print("已退出并删除脚本: " + str(path))


def run_menu(source_path):
    options = []
    actions = {
        "1": ["--plan"],
        "2": ["--apply"],
        "3": ["--check"],
        "4": ["--plan", "--repair-legacy"],
        "5": ["--apply", "--repair-legacy"],
        "6": ["--rollback", "latest"],
        "7": ["--rollback", "latest", "--files-only"],
    }
    # fd 3 is saved by the shell before stdin is replaced with Python source.
    with os.fdopen(os.dup(3), encoding="utf-8") as stream:
        try:
            while True:
                print("\n=== proxy-net-tune {} ===".format(VERSION))
                print("当前调优参数: " + (shlex.join(options) if options else "BBR / 自动检测出口 / 按内存计算缓冲区"))
                print("1. 预览调优方案（只读）")
                print("2. 应用调优并设置开机生效（需要 root）")
                print("3. 检查当前状态")
                print("4. 预览旧调优配置修复（只读）")
                print("5. 修复旧配置并应用调优（需要 root）")
                print("6. 回滚最新备份（需要 root）")
                print("7. 仅回滚最新备份的持久配置（需要 root，之后需自行重启）")
                print("8. 设置调优参数（算法 / 网卡 / 带宽与 RTT）")
                print("0. 退出并删除下载的脚本")
                choice = menu_input(stream, "请输入编号 [0-8]: ")
                if choice == "0":
                    delete_download(source_path)
                    return
                try:
                    if choice == "8":
                        options = menu_settings(stream)
                        print("参数已更新，将用于后续预览和应用。")
                        continue
                    if choice not in actions:
                        print("无效输入，请输入 0 到 8。")
                        continue
                    argv = list(actions[choice])
                    if choice in ("1", "2", "4", "5"):
                        argv += options
                    main(argv, source_path)
                except (Error, OSError, ValueError, subprocess.TimeoutExpired) as exc:
                    print("错误: " + str(exc), file=sys.stderr)
        except EOFError:
            print("\n输入已结束，退出并保留脚本；输入 0 才会删除。")


def main(argv, source_path):
    if sys.version_info < (3, 9):
        raise Error("需要 Python 3.9 或更新版本")
    parser = argparse.ArgumentParser(prog="proxy-net-tune.sh", description="Debian / Ubuntu / Alpine：SS / REALITY 等 TCP 服务器自适应缓冲区与 fq 调优",
        epilog="不带参数进入菜单，输入 0 退出并删除下载的脚本。命令行先 --plan，再 --apply。应用需要 root、Python 3.9+、iproute2（含 tc）；不会下载、升级软件或重启代理。")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--menu", action="store_true", help="进入交互菜单（不带参数时默认）")
    mode.add_argument("--plan", action="store_true", help="只读检查并展示变更")
    mode.add_argument("--apply", action="store_true", help="应用、备份并设置开机生效")
    mode.add_argument("--check", action="store_true", help="检查参数、实际队列及代理进程文件限制")
    mode.add_argument("--rollback", metavar="BACKUP_OR_latest", help="恢复某次运行前的状态")
    mode.add_argument("--boot", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--cc", choices=("bbr", "cubic", "keep"), default="bbr", help="拥塞算法；默认 bbr；不支持 BBR 可显式选择 cubic 或 keep")
    parser.add_argument("--files-only", action="store_true", help="仅用于回滚：只恢复持久配置，随后自行重启服务器")
    parser.add_argument("--repair-legacy", action="store_true", help="修复可识别的 optimize.sh / optimize_fix 旧调优项（完整备份，修复值并非历史原值）")
    parser.add_argument("--interface", action="append", default=[], help="实际出口网卡，可重复；默认 IPv4/IPv6 主表默认出口")
    parser.add_argument("--bandwidth-mbps", type=float, help="可选：期望单连接带宽 Mbps，需同时提供 RTT")
    parser.add_argument("--rtt-ms", type=float, help="可选：到主要客户端的 RTT 毫秒")
    parser.add_argument("--version", action="version", version=VERSION)
    args = parser.parse_args(argv)
    if args.menu or not argv:
        if args.menu and argv != ["--menu"]:
            parser.error("--menu 请单独使用；调优参数可在菜单内设置")
        run_menu(source_path)
        return
    if sys.platform != "linux" or fcntl is None:
        raise Error("仅支持 Linux 服务器；Windows 上可以查看 --help/--version")
    if (args.bandwidth_mbps is None) != (args.rtt_ms is None):
        parser.error("--bandwidth-mbps 和 --rtt-ms 必须一起提供")
    for value in (args.bandwidth_mbps, args.rtt_ms):
        if value is not None and (not math.isfinite(value) or value <= 0 or value > 1_000_000):
            parser.error("带宽与 RTT 必须是 0 到 1000000 之间的有限正数")
    if args.files_only and not args.rollback:
        parser.error("--files-only 必须与 --rollback 一起使用")
    if (args.check or args.rollback or args.boot) and (args.interface or args.repair_legacy or args.bandwidth_mbps is not None or args.cc != "bbr"):
        parser.error("检查/回滚/启动模式不能混用调优选项")
    for binary in ("ip", "tc"):
        if not shutil.which(binary):
            raise Error("缺少 {}。Debian / Ubuntu: apt-get install python3 iproute2；Alpine: apk add python3 iproute2".format(binary))
    if args.check:
        check()
    elif args.apply or args.rollback or args.boot:
        if os.geteuid() != 0:
            raise Error("应用/启动/回滚需要 root")
        with lock():
            if not args.rollback:
                for p in (Path(STATE) / "backups").glob("*/state.json"):
                    if json.loads(p.read_text()).get("status") in ("in-progress", "rolling-back", "rollback-incomplete"):
                        raise Error("存在未完成的操作，先检查并 --rollback " + str(p.parent))
            if args.rollback:
                rollback(args.rollback, args.files_only)
            elif args.boot:
                boot()
            else:
                path = Path(source_path).resolve()
                if not path.is_file() or not stat.S_ISREG(path.stat().st_mode):
                    raise Error("--apply 需要已保存的脚本文件；请先下载，再 sh proxy-net-tune.sh --apply")
                source = path.read_bytes()
                if not source.startswith(b"#!/bin/sh\n") or not source.rstrip().endswith(b"PROXY_NET_TUNE_PY"):
                    raise Error("脚本来源不完整或不是本脚本；请保存完整 UTF-8 / LF 文件后运行")
                apply(args, source)
    else:
        show_plan(build(args))


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, interrupted)
    try:
        main(sys.argv[2:], sys.argv[1])
    except (Error, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print("错误: " + str(exc), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("操作中断。", file=sys.stderr)
        sys.exit(130)
PROXY_NET_TUNE_PY
