#!/usr/bin/env python3
"""
VM Station - VMware Workstation Pro style interface for Proxmox VMs.
One or more Proxmox VE servers; VM consoles embedded in tabs:
  - RDP: xfreerdp
  - SSH: xterm terminal (or Konsole in a separate window)

Configuration: ~/.config/vmstation/config.json (defaults from /etc/vmstation/config.json)
Connection passwords: KDE Wallet / Secret Service (never in the configuration file)
"""
import copy
import getpass
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from urllib.parse import urlparse

import requests
import urllib3
from PySide6.QtCore import (QObject, QProcess, QProcessEnvironment, QRunnable, QThreadPool,
                            QTimer, Qt, Signal)
from PySide6.QtGui import QAction, QColor, QFont, QIcon, QKeySequence, QPalette
from PySide6.QtWidgets import (
    QAbstractItemView, QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox,
    QDockWidget, QFileDialog, QFormLayout, QFrame, QGridLayout, QGroupBox, QHBoxLayout, QHeaderView,
    QInputDialog, QLabel, QLineEdit, QMainWindow, QMenu, QMessageBox, QProgressBar, QPushButton,
    QScrollArea, QSpinBox, QStackedWidget, QStyle, QTabBar, QTabWidget, QTreeWidget,
    QTreeWidgetItem, QVBoxLayout, QWidget,
)

try:
    import keyring
    import keyring.backends.fail
except Exception:          # library missing: passwords in memory only
    keyring = None

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

APP_NAME = "VM Station"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "vmstation"
CONFIG_FILE = CONFIG_DIR / "config.json"
SYSTEM_CONFIG = Path("/etc/vmstation/config.json")
REFRESH_MS = 5000

# ---- interface language: en (texts in the code), it, es, fr ----
from vmstation_i18n import TRANSLATIONS  # noqa: E402  (next to this file)

LANG_NAMES = {"it": "Italiano", "en": "English", "es": "Español", "fr": "Français"}
_LANG_INDEX = {"it": 0, "es": 1, "fr": 2}


def detect_language():
    """Language chosen in Preferences (user file, then system file), otherwise
    the system one (LANGUAGE, LC_ALL, LC_MESSAGES, LANG); English if not supported."""
    choice = "auto"
    for f in (CONFIG_FILE, SYSTEM_CONFIG):
        try:
            data = json.loads(f.read_text())
        except Exception:
            continue
        if "language" in data:
            choice = data["language"]
            break
    if choice in LANG_NAMES:
        return choice
    for var in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
        value = os.environ.get(var, "")
        if not value or value.split(".")[0] in ("C", "POSIX"):
            continue
        code = value.split(":")[0][:2].lower()
        return code if code in LANG_NAMES else "en"
    return "en"


LANG = detect_language()


def tr(text, **kw):
    """Text translated into the interface language; {name} replaced from kw."""
    if LANG != "en":
        t = TRANSLATIONS.get(text)
        if t:
            text = t[_LANG_INDEX[LANG]]
    return text.format(**kw) if kw else text

# normal xfreerdp exit codes (close, logoff, disconnect)
NORMAL_EXIT = {0, 1, 2, 11, 12, 13}
DEFAULT_PORT = {"rdp": 3389, "ssh": 22}
PROTOCOLS = [("rdp", tr("RDP (remote desktop)")), ("ssh", tr("SSH (terminal)"))]
# RDP options as check boxes: (key, label, xfreerdp arguments, on by default)
RDP_FLAGS = [
    ("dynres", tr("Fit the resolution to the window"), ["/dynamic-resolution"], True),
    ("clipboard", tr("Shared clipboard (copy/paste)"), ["+clipboard"], True),
    ("home", tr("PC home folder inside the VM"), ["+home-drive"], True),
    ("sound", tr("VM audio on the PC"), ["/sound"], True),
    ("reconnect", tr("Automatic reconnection"), ["+auto-reconnect"], True),
    ("cert", tr("Accept the VM certificate without asking"), ["/cert:ignore"], True),
    ("mic", tr("PC microphone (calls, Teams)"), ["/microphone"], False),
    ("printer", tr("PC printers"), ["/printer"], False),
    ("smartcard", tr("Smart card / digital signature"), ["/smartcard"], False),
    ("gfx", tr("Smooth graphics (H.264, video and animations)"), ["/gfx"], False),
    ("smartsize", tr("Scale the image instead of changing resolution"), ["/smart-sizing"], False),
    ("multimon", tr("All monitors (windowed console only)"), ["+multimon"], False),
]
RDP_SCALES = [100, 125, 150, 175, 200]
# XKB layout -> (name, Windows layout code for xfreerdp /kbd:layout:)
KBD_LAYOUTS = {
    "it": (tr("Italian"), "0x00000410"), "us": (tr("English (US)"), "0x00000409"),
    "gb": (tr("English (UK)"), "0x00000809"), "de": (tr("German"), "0x00000407"),
    "ch": (tr("Swiss German"), "0x00000807"), "fr": (tr("French"), "0x0000040C"),
    "be": (tr("Belgian"), "0x0000080C"), "es": (tr("Spanish"), "0x0000040A"),
    "pt": (tr("Portuguese"), "0x00000816"), "br": (tr("Portuguese (Brazil)"), "0x00010416"),
    "nl": (tr("Dutch"), "0x00000413"), "at": (tr("German (Austria)"), "0x00000407"),
}
OS_NAMES = {"win11": "Windows 11 / Server 2022-2025", "win10": "Windows 10 / Server 2016-2019",
            "win8": "Windows 8 / Server 2012", "win7": "Windows 7 / Server 2008 R2",
            "l26": "Linux (kernel 2.6+)", "l24": "Linux 2.4", "solaris": "Solaris", "other": tr("Other")}

DEFAULT_CONFIG = {
    # default server (from the NixOS module); the real list is "servers"
    "proxmox": {
        "url": "https://127.0.0.1:8006",
        "user": "root@pam",
        "token_id": "",
        "token_secret": "",
        "verify_ssl": False,
    },
    "rdp": {
        "binary": "",                 # empty = autodetect xfreerdp / xfreerdp3
        "prefer_ip_prefix": "172.30.20.",
        "default_user": "",
        "default_domain": "",
        "flags": {k: d for k, _l, _a, d in RDP_FLAGS},   # check box defaults
        "scale": 100,                 # /scale-desktop (Windows text and icons)
        "keyboard": "auto",           # auto = system layout; "none" = do not set
        "extra_args": "",             # additional xfreerdp options (advanced)
    },
    "ssh": {
        "font": "Monospace",
        "font_size": 11,
        "extra_args": "",
    },
    "language": "auto",              # auto = system language; it, en, es, fr
    "vms": {},                       # per-VM settings for Proxmox, key = "pve:<server>:<vmid>"
    "manual": [],
}


def deep_merge(base, override):
    out = copy.deepcopy(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def diff_from(base, data):
    """Only the keys of data that differ from base (recursive on dicts)."""
    out = {}
    for k, v in data.items():
        b = base.get(k) if isinstance(base, dict) else None
        if isinstance(v, dict) and isinstance(b, dict):
            d = diff_from(b, v)
            if d:
                out[k] = d
        elif v != b:
            out[k] = v
    return out


def server_from(p, sid="local"):
    host = urlparse(p.get("url", "")).hostname or "Proxmox"
    name = tr("Local Proxmox") if host in ("localhost", "127.0.0.1") else host
    return {"id": sid, "name": name, "url": p.get("url", ""), "user": p.get("user", "root@pam"),
            "token_id": p.get("token_id", ""), "token_secret": p.get("token_secret", ""),
            "verify_ssl": bool(p.get("verify_ssl", False))}


class Config:
    def __init__(self):
        # base = program defaults + system defaults (/etc, from the NixOS module)
        self.base = copy.deepcopy(DEFAULT_CONFIG)
        try:
            self.base = deep_merge(self.base, json.loads(SYSTEM_CONFIG.read_text()))
        except FileNotFoundError:
            pass
        except Exception as e:  # corrupted file: do not block startup
            print(f"Config {SYSTEM_CONFIG} ignored: {e}", file=sys.stderr)
        self.base["servers"] = [server_from(self.base["proxmox"])]
        user = {}
        try:
            user = json.loads(CONFIG_FILE.read_text())
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"Config {CONFIG_FILE} ignored: {e}", file=sys.stderr)
        data = deep_merge(self.base, user)
        if not user.get("servers"):
            # configuration with a single server (older versions or defaults)
            data["servers"] = [server_from(data["proxmox"])]
        # VM keys of older versions: "pve:<vmid>" -> "pve:local:<vmid>"
        for k in [k for k in data["vms"] if re.fullmatch(r"pve:\d+", k)]:
            data["vms"][f"pve:local:{k[4:]}"] = data["vms"].pop(k)
        # hand-written arguments that are now check boxes: removed from "extra"
        flag_args = {a for _k, _l, args, _d in RDP_FLAGS for a in args}
        home_drive = re.compile(r"/drive:home," + re.escape(str(Path.home())) + r"/?,?$")
        for e in [data["rdp"], *data["manual"], *data["vms"].values()]:
            extra = e.get("extra_args", "")
            kept = [t for t in extra.split() if t not in flag_args and not home_drive.match(t)]
            if " ".join(kept) != extra.strip():
                e["extra_args"] = " ".join(kept)
                if any(home_drive.match(t) for t in extra.split()):
                    e.setdefault("rdp_flags", {})["home"] = True
        self.data = copy.deepcopy(data)   # never the same object as base

    def save(self):
        """Saves only what the user changed: the system defaults
        (e.g. the Proxmox address) stay updatable by NixOS."""
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        tmp = CONFIG_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(diff_from(self.base, self.data), indent=2))
        os.chmod(tmp, 0o600)       # contains the API tokens
        tmp.replace(CONFIG_FILE)

    @property
    def servers(self):
        return self.data["servers"]

    def server(self, sid):
        return next((s for s in self.servers if s["id"] == sid), None)

    @property
    def rdp(self):
        return self.data["rdp"]

    @property
    def ssh(self):
        return self.data["ssh"]

    def _entry(self, m):
        if m["kind"] == "manual":
            return next((x for x in self.data["manual"] if x["id"] == m["id"]), {})
        return self.data["vms"].get(m["key"], {})

    def machine_conn(self, m):
        """Effective connection settings of a machine."""
        entry = self._entry(m)
        # LXC containers usually have SSH only
        proto = entry.get("protocol") or ("ssh" if m.get("vmtype") == "lxc" else "rdp")
        default_user = self.rdp["default_user"] if proto == "rdp" else ""
        return {
            "protocol": proto,
            "host": entry.get("host", ""),
            "port": int(entry.get("port") or DEFAULT_PORT[proto]),
            "user": entry.get("user", "") or default_user,
            "domain": entry.get("domain", "") or (self.rdp["default_domain"] if proto == "rdp" else ""),
            "ssh_key": entry.get("ssh_key", ""),
            # SSH login: password (empty = asked in the terminal) or key
            "ssh_auth": entry.get("ssh_auth") or ("key" if entry.get("ssh_key") else "password"),
            "embed": bool(entry.get("embed", True)),
            "extra_args": entry.get("extra_args", ""),
            # RDP check boxes: global defaults + connection choices
            "rdp_flags": {**self.rdp["flags"], **entry.get("rdp_flags", {})},
            "scale": int(entry.get("scale") or self.rdp.get("scale", 100)),
        }

    def rdp_args(self, conn):
        """xfreerdp arguments from the check boxes, the scale and the extra arguments."""
        args = []
        for k, _l, a, _d in RDP_FLAGS:
            if conn["rdp_flags"].get(k):
                args += a
        if conn["scale"] != 100:
            args.append(f"/scale-desktop:{conn['scale']}")
        extra = self.rdp["extra_args"].split() + conn["extra_args"].split()
        klid = self.keyboard_klid()
        if klid and not any(a.startswith("/kbd") for a in extra):
            args.append(f"/kbd:layout:{klid}")
        args += extra
        return list(dict.fromkeys(args))          # no duplicates, order unchanged

    def system_layout(self):
        """System keyboard layout (from the NixOS module, otherwise localectl)."""
        lay = self.data.get("keyboard", "")
        if not lay:
            try:
                out = subprocess.run(["localectl", "status"], capture_output=True,
                                     text=True, timeout=3).stdout
                m = re.search(r"X11 Layout:\s*([\w-]+)", out)
                lay = m.group(1) if m else ""
            except Exception:
                lay = ""
        return lay.split(",")[0].strip()

    def keyboard_klid(self):
        """Windows layout code to pass to xfreerdp (None = do not set)."""
        choice = self.rdp.get("keyboard", "auto")
        if choice == "none":
            return None
        lay = self.system_layout() if choice == "auto" else choice
        return KBD_LAYOUTS.get(lay, (None, None))[1]

    def compact_conn(self, values):
        """Keeps only the RDP check box choices that differ from the global defaults,
        so a change of the defaults in Preferences also applies to this connection."""
        values = dict(values)
        if "rdp_flags" in values:
            values["rdp_flags"] = {k: v for k, v in values["rdp_flags"].items()
                                   if v != self.rdp["flags"].get(k)}
        if "scale" in values and values["scale"] == self.rdp.get("scale", 100):
            values["scale"] = 0
        return values

    def set_machine_conn(self, m, values):
        values = self.compact_conn(values)
        if m["kind"] == "manual":
            for x in self.data["manual"]:
                if x["id"] == m["id"]:
                    x.update(values)
        else:
            self.data["vms"][m["key"]] = {**self.data["vms"].get(m["key"], {}), **values}
        self.save()


class Secrets:
    """Connection passwords in the KDE Wallet (KWallet / Secret Service)."""
    SERVICE = "vmstation"

    def __init__(self):
        self.ok = False
        if keyring is None:
            return
        try:
            self.ok = not isinstance(keyring.get_keyring(), keyring.backends.fail.Keyring)
        except Exception:
            self.ok = False

    @staticmethod
    def _name(m, user):
        return f"{m['key']}/{user}"

    def get(self, m, user):
        if not (self.ok and user):
            return None
        try:
            return keyring.get_password(self.SERVICE, self._name(m, user))
        except Exception:
            return None

    def set(self, m, user, password):
        if not (self.ok and user):
            return False
        try:
            keyring.set_password(self.SERVICE, self._name(m, user), password)
            return True
        except Exception as e:
            print(f"Wallet: cannot save the password: {e}", file=sys.stderr)
            return False

    def delete(self, m, user):
        if not (self.ok and user):
            return
        try:
            keyring.delete_password(self.SERVICE, self._name(m, user))
        except Exception:
            pass


DEFAULT_SSH_KEYS = ("id_ed25519", "id_ecdsa", "id_rsa")


def home_short(path):
    """/home/user/.ssh/x -> ~/.ssh/x"""
    path, home = str(path), str(Path.home())
    return "~" + path[len(home):] if path.startswith(home + "/") else path


def default_ssh_key():
    """First standard private key in ~/.ssh with its .pub ("" if none)."""
    for name in DEFAULT_SSH_KEYS:
        p = Path.home() / ".ssh" / name
        if p.exists() and Path(f"{p}.pub").exists():
            return str(p)
    return ""


def generate_ssh_key(parent):
    """Creates an ed25519 key with ssh-keygen; returns the path ("" if cancelled)."""
    ssh_dir = Path.home() / ".ssh"
    path = ssh_dir / "id_ed25519"
    if path.exists():
        if QMessageBox.question(parent, APP_NAME, tr("The key {path} already exists. Use it?",
                                                     path=home_short(path))) == QMessageBox.Yes:
            return home_short(path)
        n = 1
        path = ssh_dir / "vmstation_ed25519"
        while path.exists():
            n += 1
            path = ssh_dir / f"vmstation_ed25519_{n}"
    phrase, ok = QInputDialog.getText(
        parent, tr("New SSH key"),
        tr("Key passphrase (empty = none; if set, it will be asked at every connection):"),
        QLineEdit.Password)
    if not ok:
        return ""
    ssh_dir.mkdir(mode=0o700, exist_ok=True)
    comment = f"{getpass.getuser()}@{socket.gethostname()} (VM Station)"
    try:
        r = subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", phrase, "-C", comment,
                            "-f", str(path)], capture_output=True, text=True, timeout=60)
        err = r.stderr.strip() if r.returncode else ""
    except Exception as e:
        err = str(e)
    if err:
        QMessageBox.warning(parent, APP_NAME, tr("Key creation failed:\n{err}", err=err))
        return ""
    QMessageBox.information(parent, APP_NAME, tr(
        "Key created: {path}\n"
        "\n"
        "Install it on the machine with “Copy SSH key to the machine” (VM menu or button in the machine tab).", path=home_short(path)))
    return home_short(path)


def find_xfreerdp(cfg):
    if cfg.rdp.get("binary"):
        return cfg.rdp["binary"]
    for name in ("xfreerdp", "xfreerdp3"):
        if shutil.which(name):
            return name
    return "xfreerdp"


def icon(theme_name, fallback):
    """KDE theme icon, falling back to the standard Qt icons."""
    ic = QIcon.fromTheme(theme_name)
    return ic if not ic.isNull() else QApplication.style().standardIcon(fallback)


def proto_icon(proto):
    if proto == "ssh":
        return icon("utilities-terminal", QStyle.SP_ComputerIcon)
    return icon("krdc", QStyle.SP_ComputerIcon)


def key_icon():
    return icon("dialog-password", QStyle.SP_DialogApplyButton)


def server_icon():
    return icon("network-server", QStyle.SP_DriveNetIcon)


class ProxmoxError(Exception):
    pass


class ProxmoxClient:
    def __init__(self, url, user, token_id="", token_secret="", password="", verify_ssl=False):
        self.base = url.rstrip("/") + "/api2/json"
        self.user = user
        self.password = password
        self.s = requests.Session()
        self.s.verify = verify_ssl
        self.logged = False
        if token_id and token_secret:
            self.s.headers["Authorization"] = f"PVEAPIToken={user}!{token_id}={token_secret}"

    def _check(self, r):
        if r.status_code >= 400:
            msg = r.reason
            try:
                msg = r.json().get("message") or r.json().get("errors") or msg
            except Exception:
                pass
            raise ProxmoxError(f"HTTP {r.status_code}: {msg}")
        return r.json().get("data")

    def login(self):
        """Checks the login (with a token: a test call)."""
        if self.logged:
            return
        try:
            if "Authorization" in self.s.headers:
                self._check(self.s.get(f"{self.base}/version", timeout=10))
            else:
                r = self.s.post(f"{self.base}/access/ticket",
                                data={"username": self.user, "password": self.password}, timeout=10)
                d = self._check(r)
                self.s.cookies.set("PVEAuthCookie", d["ticket"])
                self.s.headers["CSRFPreventionToken"] = d["CSRFPreventionToken"]
        except requests.RequestException as e:
            raise ProxmoxError(tr("server unreachable: {err}", err=e))
        self.logged = True

    def get(self, path, **params):
        self.login()
        try:
            return self._check(self.s.get(self.base + path, params=params, timeout=15))
        except requests.RequestException as e:
            raise ProxmoxError(str(e))

    def post(self, path, **data):
        self.login()
        try:
            return self._check(self.s.post(self.base + path, data=data, timeout=30))
        except requests.RequestException as e:
            raise ProxmoxError(str(e))

    def list_vms(self):
        return [v for v in self.get("/cluster/resources", type="vm") if not v.get("template")]

    def action(self, m, action):
        return self.post(f"/nodes/{m['node']}/{m['vmtype']}/{m['vmid']}/status/{action}")

    def server_summary(self):
        """Server summary: version and, for each node, status and storage."""
        version = self.get("/version") or {}
        nodes = []
        for n in sorted(self.get("/nodes") or [], key=lambda x: x.get("node", "")):
            status, storage = {}, []
            if n.get("status") == "online":
                try:
                    status = self.get(f"/nodes/{n['node']}/status") or {}
                    storage = self.get(f"/nodes/{n['node']}/storage") or []
                except ProxmoxError:
                    pass
            nodes.append({"node": n, "status": status, "storage": storage})
        return {"version": version, "nodes": nodes}

    def vm_details(self, m):
        base = f"/nodes/{m['node']}/{m['vmtype']}/{m['vmid']}"
        try:
            cfg = self.get(base + "/config") or {}
        except ProxmoxError:
            cfg = {}
        return {"config": cfg}

    def guest_ip(self, m, prefer=""):
        ips = []
        try:
            if m["vmtype"] == "qemu":
                data = self.get(f"/nodes/{m['node']}/qemu/{m['vmid']}/agent/network-get-interfaces")
                for iface in (data or {}).get("result", []):
                    for a in iface.get("ip-addresses", []):
                        if a.get("ip-address-type") == "ipv4":
                            ips.append(a.get("ip-address", ""))
            else:
                for iface in self.get(f"/nodes/{m['node']}/lxc/{m['vmid']}/interfaces") or []:
                    ips.append((iface.get("inet") or "").split("/")[0])
        except ProxmoxError:
            return ""   # guest agent not installed or VM stopped
        ips = [ip for ip in ips if ip and not ip.startswith("127.")]
        for ip in ips:
            if prefer and ip.startswith(prefer):
                return ip
        return ips[0] if ips else ""


class WorkerSignals(QObject):
    done = Signal(object)
    failed = Signal(str)


class Worker(QRunnable):
    def __init__(self, fn, *args):
        super().__init__()
        self.fn, self.args = fn, args
        self.signals = WorkerSignals()

    def run(self):
        try:
            res = self.fn(*self.args)
        except Exception as e:
            self.signals.failed.emit(str(e))
            return
        self.signals.done.emit(res)


class ConsoleView(QWidget):
    finished = Signal(int, str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WA_NativeWindow, True)
        self.setAttribute(Qt.WA_DontCreateNativeAncestors, True)
        pal = self.palette()
        pal.setColor(QPalette.Window, QColor("black"))
        self.setPalette(pal)
        self.setAutoFillBackground(True)
        self.setFocusPolicy(Qt.StrongFocus)
        self.proc = None
        self.embed = True
        self.log = ""
        self._resize_timer = QTimer(self, singleShot=True, interval=400)
        self._resize_timer.timeout.connect(self._apply_size)

    def window_id(self):
        return int(self.winId())

    def physical_size(self):
        r = self.devicePixelRatioF()
        return max(640, int(self.width() * r)), max(480, int(self.height() * r))

    def running(self):
        return self.proc is not None and self.proc.state() != QProcess.NotRunning

    def start(self, program, args, embed, env=None):
        """Starts the program. The arguments to embed it (/parent-window
        for xfreerdp, -into for xterm) are added by the caller."""
        self.stop()
        self.embed = embed
        self.log = ""
        self.proc = QProcess(self)
        if env:
            pe = QProcessEnvironment.systemEnvironment()
            for k, v in env.items():
                pe.insert(k, v)
            self.proc.setProcessEnvironment(pe)
        self.proc.setProcessChannelMode(QProcess.MergedChannels)
        self.proc.readyReadStandardOutput.connect(self._read)
        self.proc.finished.connect(self._on_finished)
        self.proc.errorOccurred.connect(self._on_error)
        self.proc.start(program, list(args))
        if embed:
            # the child window appears after a moment: fit it and give it focus;
            # the late attempts are for RDP, which accepts a resolution change
            # only once the session has started
            for ms in (600, 1500, 4000, 8000):
                QTimer.singleShot(ms, self._apply_size)
                QTimer.singleShot(ms + 100, self.focus_child)

    def stop(self):
        if self.running():
            self.proc.terminate()
            if not self.proc.waitForFinished(3000):
                self.proc.kill()

    def _read(self):
        self.log = (self.log + bytes(self.proc.readAllStandardOutput()).decode(errors="replace"))[-6000:]

    def _on_finished(self, code, _status):
        self.finished.emit(code, self.log)

    def _on_error(self, err):
        if err == QProcess.FailedToStart:
            self.finished.emit(-1, tr("Cannot start {prog}: is it installed?", prog=self.proc.program()))

    def _children(self):
        if not shutil.which("xwininfo"):
            return []
        try:
            out = subprocess.run(["xwininfo", "-children", "-id", str(self.window_id())],
                                 capture_output=True, text=True, timeout=2).stdout
        except Exception:
            return []
        return re.findall(r"^\s+(0x[0-9a-fA-F]+)\s", out, re.M)

    def _xdotool(self, *args):
        if not shutil.which("xdotool"):
            return
        for wid in self._children():
            try:
                subprocess.run(["xdotool", args[0], wid, *args[1:]], timeout=2)
            except Exception:
                pass

    def focus_child(self):
        if self.running() and self.embed:
            self._xdotool("windowfocus")

    def focusInEvent(self, e):
        super().focusInEvent(e)
        QTimer.singleShot(0, self.focus_child)

    def resizeEvent(self, e):
        super().resizeEvent(e)
        if self.running() and self.embed:
            self._resize_timer.start()

    def _apply_size(self):
        """Fits the console to the tab (with /dynamic-resolution the VM adapts)."""
        if not self.running() or not self.embed:
            return
        w, h = self.physical_size()
        self._xdotool("windowsize", str(w), str(h))


class RdpFlagsBox(QGroupBox):
    """Main RDP options as check boxes, plus the Windows scale."""

    def __init__(self, flags=None, scale=100, title=None):
        super().__init__(title or tr("RDP options"))
        flags = flags or {k: d for k, _l, _a, d in RDP_FLAGS}
        g = QGridLayout(self)
        self.checks = {}
        for i, (k, label, args, default) in enumerate(RDP_FLAGS):
            cb = QCheckBox(label)
            cb.setChecked(bool(flags.get(k, default)))
            cb.setToolTip("xfreerdp " + " ".join(args))
            g.addWidget(cb, i // 2, i % 2)
            self.checks[k] = cb
        self.scale = QComboBox()
        for s in RDP_SCALES:
            self.scale.addItem(f"{s}%" + ("  " + tr("(normal)") if s == 100 else ""), s)
        self.scale.setCurrentIndex(max(0, self.scale.findData(int(scale or 100))))
        row = QHBoxLayout()
        row.addWidget(QLabel(tr("Text and icon size in Windows:")))
        row.addWidget(self.scale)
        row.addStretch()
        g.addLayout(row, (len(RDP_FLAGS) + 1) // 2, 0, 1, 2)
        # the two fitting modes exclude each other
        self.checks["dynres"].toggled.connect(lambda on: on and self.checks["smartsize"].setChecked(False))
        self.checks["smartsize"].toggled.connect(lambda on: on and self.checks["dynres"].setChecked(False))

    def flags(self):
        return {k: cb.isChecked() for k, cb in self.checks.items()}

    def scale_value(self):
        return self.scale.currentData()


class ConnSettingsDialog(QDialog):
    """Settings of a connection (RDP or SSH), with its own user and password."""

    def __init__(self, parent, title, values, secrets, saved_password=False,
                 with_name=False, name=""):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumWidth(520)
        self.saved_password = saved_password
        form = self.form = QFormLayout(self)
        self.name = QLineEdit(name)
        if with_name:
            form.addRow(tr("Name:"), self.name)
        self.proto = QComboBox()
        for key, label in PROTOCOLS:
            self.proto.addItem(label, key)
        self.proto.setCurrentIndex(max(0, self.proto.findData(values.get("protocol", "rdp"))))
        self.host = QLineEdit(values.get("host", ""))
        self.host.setPlaceholderText(tr("empty = automatic IP (Proxmox VM)"))
        self.port = QSpinBox()
        self.port.setRange(1, 65535)
        self.port.setValue(int(values.get("port") or DEFAULT_PORT[self.protocol()]))
        self.user = QLineEdit(values.get("user", ""))
        self.auth = QComboBox()
        self.auth.addItem(tr("Password"), "password")
        self.auth.addItem(tr("SSH key"), "key")
        auth = values.get("ssh_auth") or ("key" if values.get("ssh_key") else "password")
        self.auth.setCurrentIndex(max(0, self.auth.findData(auth)))
        self.password = QLineEdit()
        self.password.setEchoMode(QLineEdit.Password)
        self.password.setPlaceholderText(
            tr("•••••• (saved — type to change it)") if saved_password else tr("not saved"))
        self.forget = QCheckBox(tr("Forget the saved password"))
        self.domain = QLineEdit(values.get("domain", ""))
        # SSH key: path, Browse, Generate
        self.ssh_key = QLineEdit(values.get("ssh_key", ""))
        self.ssh_key.setPlaceholderText(tr("empty = keys in ~/.ssh and agent"))
        b_browse = QPushButton(tr("Browse..."))
        b_browse.clicked.connect(self._browse_key)
        b_gen = QPushButton(tr("Generate key..."))
        b_gen.clicked.connect(self._generate_key)
        self.key_row = QWidget()
        kl = QHBoxLayout(self.key_row)
        kl.setContentsMargins(0, 0, 0, 0)
        kl.addWidget(self.ssh_key, 1)
        kl.addWidget(b_browse)
        kl.addWidget(b_gen)
        self.key_note = QLabel(tr(
            "<small>The public key (.pub) must be in the machine's ~/.ssh/authorized_keys: <b>Copy SSH key to the machine</b> (VM menu) installs it using the password.</small>"))
        self.key_note.setWordWrap(True)
        self.embed = QCheckBox()
        self.embed.setChecked(values.get("embed", True))
        self.rdp_box = RdpFlagsBox(values.get("rdp_flags"), values.get("scale", 100))
        self.extra = QLineEdit(values.get("extra_args", ""))

        form.addRow(tr("Type:"), self.proto)
        form.addRow(tr("Host / IP:"), self.host)
        form.addRow(tr("Port:"), self.port)
        form.addRow(tr("User:"), self.user)
        form.addRow(tr("Authentication:"), self.auth)
        form.addRow(tr("Password:"), self.password)
        form.addRow("", self.forget)
        self.wallet_note = None
        if not secrets.ok:
            self.wallet_note = QLabel(tr("<small>KDE Wallet not available: the password is kept in memory only until the program is closed.</small>"))
            self.wallet_note.setWordWrap(True)
            form.addRow("", self.wallet_note)
        form.addRow(tr("Domain:"), self.domain)
        form.addRow(tr("SSH key:"), self.key_row)
        form.addRow("", self.key_note)
        form.addRow("", self.embed)
        form.addRow(self.rdp_box)
        form.addRow(tr("Extra arguments:"), self.extra)
        bb = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        form.addRow(bb)
        self._last_proto = self.protocol()
        self.proto.currentIndexChanged.connect(self._proto_changed)
        self.auth.currentIndexChanged.connect(self._proto_changed)
        self._proto_changed()

    def protocol(self):
        return self.proto.currentData()

    def _proto_changed(self):
        p = self.protocol()
        # default port if the user had not changed it
        if self.port.value() == DEFAULT_PORT[self._last_proto]:
            self.port.setValue(DEFAULT_PORT[p])
        self._last_proto = p
        key = p == "ssh" and self.auth.currentData() == "key"
        self.form.setRowVisible(self.domain, p == "rdp")
        self.form.setRowVisible(self.auth, p == "ssh")
        self.form.setRowVisible(self.key_row, key)
        self.form.setRowVisible(self.key_note, key)
        self.form.setRowVisible(self.password, not key)
        self.form.setRowVisible(self.forget, not key and self.saved_password)
        if self.wallet_note is not None:
            self.form.setRowVisible(self.wallet_note, not key)
        self.form.setRowVisible(self.rdp_box, p == "rdp")
        if p == "ssh":
            self.embed.setText(tr("Terminal inside VM Station (tab); if unchecked: Konsole in a window"))
            self.extra.setPlaceholderText(tr("ssh options, e.g. -A -L 8080:localhost:80"))
        else:
            self.embed.setText(tr("Show the console inside VM Station (tab)"))
            self.extra.setPlaceholderText(tr("additional xfreerdp options (advanced), e.g. /drive:data,/srv/data"))
        self.adjustSize()

    def _browse_key(self):
        start = os.path.expanduser(self.ssh_key.text().strip() or "~/.ssh")
        path, _filter = QFileDialog.getOpenFileName(self, tr("SSH private key"), start)
        if path:
            if path.endswith(".pub"):
                path = path[:-4]
            self.ssh_key.setText(home_short(path))

    def _generate_key(self):
        path = generate_ssh_key(self)
        if path:
            self.ssh_key.setText(path)

    def values(self):
        return {
            "protocol": self.protocol(),
            "host": self.host.text().strip(),
            "port": self.port.value(),
            "user": self.user.text().strip(),
            "domain": self.domain.text().strip(),
            "ssh_auth": self.auth.currentData(),
            "ssh_key": self.ssh_key.text().strip(),
            "embed": self.embed.isChecked(),
            "extra_args": self.extra.text().strip(),
            "rdp_flags": self.rdp_box.flags(),
            "scale": self.rdp_box.scale_value(),
        }


class CredentialsDialog(QDialog):
    """User and password when connecting, with "Remember"."""

    def __init__(self, parent, title, user, can_remember, remember, password_optional=False):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumWidth(380)
        form = QFormLayout(self)
        self.user = QLineEdit(user)
        self.password = QLineEdit()
        self.password.setEchoMode(QLineEdit.Password)
        if password_optional:
            self.password.setPlaceholderText(tr("empty = SSH key or asked in the terminal"))
        self.remember = QCheckBox(tr("Remember user and password (KDE Wallet)"))
        self.remember.setChecked(can_remember and remember)
        self.remember.setEnabled(can_remember)
        if not can_remember:
            self.remember.setToolTip(tr("KDE Wallet not available"))
        form.addRow(tr("User:"), self.user)
        form.addRow(tr("Password:"), self.password)
        form.addRow("", self.remember)
        bb = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        form.addRow(bb)
        (self.password if user else self.user).setFocus()


class ServerDialog(QDialog):
    """Data of a Proxmox VE server."""

    def __init__(self, parent, title, values):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumWidth(500)
        form = QFormLayout(self)
        self.name = QLineEdit(values.get("name", ""))
        self.name.setPlaceholderText(tr("e.g. Office, Lab"))
        self.url = QLineEdit(values.get("url", "https://"))
        self.url.setPlaceholderText(tr("https://address:8006"))
        self.user = QLineEdit(values.get("user", "root@pam"))
        self.token_id = QLineEdit(values.get("token_id", ""))
        self.token_secret = QLineEdit(values.get("token_secret", ""))
        self.token_secret.setEchoMode(QLineEdit.Password)
        self.verify = QCheckBox(tr("Verify SSL certificate"))
        self.verify.setChecked(bool(values.get("verify_ssl", False)))
        form.addRow(tr("Name:"), self.name)
        form.addRow("URL:", self.url)
        form.addRow(tr("User (e.g. root@pam):"), self.user)
        form.addRow(tr("Token ID (optional):"), self.token_id)
        form.addRow("Token secret:", self.token_secret)
        form.addRow("", self.verify)
        note = QLabel(tr("<small>Without a token the password is asked at every connection and is not saved. The token needs the required permissions (or <i>Privilege Separation</i> disabled).</small>"))
        note.setWordWrap(True)
        form.addRow(note)
        bb = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        form.addRow(bb)

    def values(self):
        url = self.url.text().strip().rstrip("/")
        return {"name": self.name.text().strip() or (urlparse(url).hostname or url),
                "url": url, "user": self.user.text().strip(),
                "token_id": self.token_id.text().strip(),
                "token_secret": self.token_secret.text().strip(),
                "verify_ssl": self.verify.isChecked()}


class SettingsDialog(QDialog):
    def __init__(self, parent, cfg):
        super().__init__(parent)
        self.cfg = cfg
        self.setWindowTitle(tr("Preferences"))
        self.setMinimumWidth(520)
        lay = QVBoxLayout(self)

        g1 = QGroupBox(tr("Interface"))
        f1 = QFormLayout(g1)
        self.language = QComboBox()
        self.language.addItem(tr("Same as the system"), "auto")
        for code, name in LANG_NAMES.items():
            self.language.addItem(name, code)
        self.language.setCurrentIndex(max(0, self.language.findData(cfg.data.get("language", "auto"))))
        f1.addRow(tr("Language:"), self.language)

        g2 = QGroupBox(tr("RDP defaults (new connections and non-customized connections)"))
        f2 = QFormLayout(g2)
        self.duser = QLineEdit(cfg.rdp["default_user"])
        self.ddomain = QLineEdit(cfg.rdp["default_domain"])
        self.prefix = QLineEdit(cfg.rdp["prefer_ip_prefix"])
        self.args = QLineEdit(cfg.rdp["extra_args"])
        self.binary = QLineEdit(cfg.rdp.get("binary", ""))
        self.binary.setPlaceholderText(tr("auto (xfreerdp)"))
        self.keyboard = QComboBox()
        sys_lay = cfg.system_layout()
        sys_name = KBD_LAYOUTS.get(sys_lay, (sys_lay or tr("unknown"),))[0]
        self.keyboard.addItem(tr("Same as the system ({name})", name=sys_name), "auto")
        for code, (name, _klid) in KBD_LAYOUTS.items():
            self.keyboard.addItem(name, code)
        self.keyboard.addItem(tr("Do not set (Windows decides)"), "none")
        self.keyboard.setCurrentIndex(max(0, self.keyboard.findData(cfg.rdp.get("keyboard", "auto"))))
        f2.addRow(tr("User:"), self.duser)
        f2.addRow(tr("Domain:"), self.ddomain)
        f2.addRow(tr("Keyboard in the VM:"), self.keyboard)
        f2.addRow(tr("Preferred network (IP prefix):"), self.prefix)
        f2.addRow(tr("Extra arguments (advanced):"), self.args)
        f2.addRow(tr("Executable:"), self.binary)

        g3 = QGroupBox(tr("SSH terminal"))
        f3 = QFormLayout(g3)
        self.font = QLineEdit(cfg.ssh["font"])
        self.font_size = QSpinBox()
        self.font_size.setRange(6, 40)
        self.font_size.setValue(int(cfg.ssh["font_size"]))
        self.ssh_args = QLineEdit(cfg.ssh["extra_args"])
        self.ssh_args.setPlaceholderText(tr("e.g. -o ServerAliveInterval=30"))
        f3.addRow(tr("Font:"), self.font)
        f3.addRow(tr("Size:"), self.font_size)
        f3.addRow(tr("ssh options:"), self.ssh_args)
        f3.addRow(QLabel(tr("<small>In the terminal: Ctrl+Shift+C copies, Ctrl+Shift+V pastes.</small>")))

        lay.addWidget(QLabel(tr("Proxmox servers are managed from the <b>Home</b> tab.")))
        self.rdp_box = RdpFlagsBox(cfg.rdp["flags"], cfg.rdp.get("scale", 100),
                                   tr("Default RDP options"))
        for g in (g1, g2, self.rdp_box, g3):
            lay.addWidget(g)
        bb = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        lay.addWidget(bb)

    def apply(self):
        old_lang = self.cfg.data.get("language", "auto")
        self.cfg.data["language"] = self.language.currentData()
        self.cfg.rdp.update(default_user=self.duser.text().strip(),
                            default_domain=self.ddomain.text().strip(),
                            prefer_ip_prefix=self.prefix.text().strip(),
                            extra_args=self.args.text().strip(),
                            flags=self.rdp_box.flags(), scale=self.rdp_box.scale_value(),
                            binary=self.binary.text().strip(),
                            keyboard=self.keyboard.currentData())
        self.cfg.ssh.update(font=self.font.text().strip() or "Monospace",
                            font_size=self.font_size.value(),
                            extra_args=self.ssh_args.text().strip())
        self.cfg.save()
        if self.cfg.data["language"] != old_lang:
            QMessageBox.information(self, APP_NAME, tr("The new language will be used the next time VM Station starts."))


def fmt_bytes(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def fmt_uptime(s):
    s = int(s or 0)
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m, _ = divmod(s, 60)
    return tr("{d}d {h}h {m}m", d=d, h=h, m=m) if d else f"{h}h {m}m"


def title_font(size=18):
    f = QFont()
    f.setPointSize(size)
    f.setBold(True)
    return f


def clear_layout(lay):
    while lay.count():
        it = lay.takeAt(0)
        if it.widget():
            it.widget().deleteLater()
        elif it.layout():
            clear_layout(it.layout())


class Bar(QProgressBar):
    """Usage bar with text (e.g. "3.2 GB / 8.0 GB (40%)")."""

    def __init__(self):
        super().__init__()
        self.setRange(0, 100)
        self.setTextVisible(True)
        self.setMinimumWidth(280)

    def set_usage(self, used, total, text=None):
        used, total = float(used or 0), float(total or 0)
        pct = int(round(used * 100 / total)) if total else 0
        self.setValue(max(0, min(100, pct)))
        self.setFormat(text or f"{fmt_bytes(used)} / {fmt_bytes(total)}  ({pct}%)")

    def set_cpu(self, frac, cpus):
        pct = float(frac or 0) * 100
        self.setValue(int(min(100, pct)))
        self.setFormat(tr("{pct}% of {cpus} CPUs", pct=f"{pct:.0f}", cpus=cpus))


class Fields:
    """"label: value" grid (QLabel or Bar), with rows that can be hidden."""

    def __init__(self, grid, rows):
        self.labels, self.values = {}, {}
        for i, (key, label, kind) in enumerate(rows):
            lab = QLabel(f"<b>{label}</b>")
            val = Bar() if kind == "bar" else QLabel("-")
            if kind != "bar":
                val.setTextInteractionFlags(Qt.TextSelectableByMouse)
                val.setWordWrap(True)
            grid.addWidget(lab, i, 0, Qt.AlignTop)
            grid.addWidget(val, i, 1)
            self.labels[key], self.values[key] = lab, val
        grid.setColumnStretch(1, 1)

    def __getitem__(self, key):
        return self.values[key]

    def show_row(self, key, visible):
        self.labels[key].setVisible(visible)
        self.values[key].setVisible(visible)


class NodeBox(QGroupBox):
    """Summary of a Proxmox node (like the Summary page of the Web UI)."""

    def __init__(self):
        super().__init__()
        lay = QVBoxLayout(self)
        g = QGridLayout()
        self.f = Fields(g, [
            ("status", tr("Status"), "text"), ("pve", tr("Version"), "text"), ("kernel", "Kernel", "text"),
            ("cpu", "CPU", "bar"), ("model", tr("Processor"), "text"), ("load", tr("Load average"), "text"),
            ("mem", tr("Memory"), "bar"), ("swap", "Swap", "bar"), ("root", tr("System disk"), "bar"),
            ("uptime", "Uptime", "text"), ("guests", tr("VMs / containers"), "text"),
        ])
        lay.addLayout(g)
        self.storage_box = QGroupBox("Storage")
        self.storage_grid = QGridLayout(self.storage_box)
        lay.addWidget(self.storage_box)

    def update_node(self, n, st, storage, counts):
        f = self.f
        online = n.get("status") == "online"
        self.setTitle(tr("Node {name}", name=n.get('node', '?')))
        f["status"].setText("🟢 Online" if online else "🔴 Offline")
        for k in ("pve", "kernel", "cpu", "model", "load", "mem", "swap", "root", "uptime"):
            f.show_row(k, online)
        self.storage_box.setVisible(online)
        running, total = counts
        f["guests"].setText(tr("{running} running of {total}", running=running, total=total))
        if not online:
            return
        info = st.get("cpuinfo", {})
        f["pve"].setText(st.get("pveversion", "-"))
        f["kernel"].setText(st.get("kversion", "-"))
        f["cpu"].set_cpu(st.get("cpu", n.get("cpu")), info.get("cpus", n.get("maxcpu", "?")))
        f["model"].setText(f"{info.get('model', '-')}  ({info.get('sockets', '?')} socket)")
        f["load"].setText("  ".join(str(x) for x in st.get("loadavg", [])) or "-")
        mem, swap, root = st.get("memory", {}), st.get("swap", {}), st.get("rootfs", {})
        f["mem"].set_usage(mem.get("used", n.get("mem")), mem.get("total", n.get("maxmem")))
        f["swap"].set_usage(swap.get("used"), swap.get("total"))
        f["root"].set_usage(root.get("used", n.get("disk")), root.get("total", n.get("maxdisk")))
        f["uptime"].setText(fmt_uptime(st.get("uptime", n.get("uptime"))))
        clear_layout(self.storage_grid)
        for i, s in enumerate(sorted(storage, key=lambda x: x.get("storage", ""))):
            name = QLabel(f"<b>{s.get('storage')}</b>  <small>({s.get('type', '')})</small>")
            bar = Bar()
            if s.get("active"):
                bar.set_usage(s.get("used"), s.get("total"))
            else:
                bar.setValue(0)
                bar.setFormat(tr("inactive"))
            content = QLabel(f"<small>{s.get('content', '')}</small>")
            self.storage_grid.addWidget(name, i, 0)
            self.storage_grid.addWidget(bar, i, 1)
            self.storage_grid.addWidget(content, i, 2)
        self.storage_grid.setColumnStretch(1, 1)


class ServerTab(QWidget):
    """Summary tab of a Proxmox server."""

    def __init__(self, main, sid):
        super().__init__()
        self.main, self.sid = main, sid
        self.node_boxes = {}
        self._loading = False
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        outer.addWidget(scroll)
        page = QWidget()
        scroll.setWidget(page)
        pl = QVBoxLayout(page)
        pl.setContentsMargins(24, 24, 24, 24)
        self.title = QLabel()
        self.title.setFont(title_font())
        self.subtitle = QLabel()
        self.subtitle.setTextInteractionFlags(Qt.TextSelectableByMouse)
        pl.addWidget(self.title)
        pl.addWidget(self.subtitle)
        row = QHBoxLayout()
        st = self.style()
        self.b_connect = QPushButton(st.standardIcon(QStyle.SP_BrowserReload), tr("Connect"))
        b_web = QPushButton(st.standardIcon(QStyle.SP_DirLinkIcon), tr("Open Web UI"))
        b_edit = QPushButton(st.standardIcon(QStyle.SP_FileDialogDetailedView), tr("Edit server"))
        self.b_connect.clicked.connect(lambda: main.connect_server(sid, interactive=True))
        b_web.clicked.connect(lambda: main.open_web(sid))
        b_edit.clicked.connect(lambda: main.edit_server(sid))
        for b in (self.b_connect, b_web, b_edit):
            row.addWidget(b)
        row.addStretch()
        pl.addLayout(row)
        self.message = QLabel()
        self.message.setWordWrap(True)
        self.message.setStyleSheet("color: #c0392b;")
        pl.addWidget(self.message)
        self.nodes_lay = QVBoxLayout()
        pl.addLayout(self.nodes_lay)
        pl.addStretch()
        self.update_server()

    def update_server(self):
        s = self.main.cfg.server(self.sid) or {}
        self.title.setText(s.get("name", "?"))
        state = self.main.server_state.get(self.sid, tr("not connected"))
        self.subtitle.setText(f"{s.get('url', '')}   ·   {s.get('user', '')}   ·   {state}")
        connected = self.sid in self.main.clients
        self.b_connect.setText(tr("Reconnect") if connected else tr("Connect"))
        if not connected:
            self.message.setText(tr("Server not connected: press Connect."))

    def load(self):
        client = self.main.clients.get(self.sid)
        if not client or self._loading:
            self.update_server()
            return
        self._loading = True

        def done(data):
            self._loading = False
            self.show_summary(data)

        def fail(err):
            self._loading = False
            self.message.setText(tr("Cannot read the server status: {err}", err=err))

        self.main.run_async(client.server_summary, on_done=done, on_fail=fail)

    def show_summary(self, data):
        self.message.clear()
        ver = data.get("version", {})
        if ver.get("version"):
            s = self.main.cfg.server(self.sid) or {}
            self.subtitle.setText(f"{s.get('url', '')}   ·   Proxmox VE {ver.get('version')}"
                                  f"   ·   {self.main.server_state.get(self.sid, '')}")
        seen = set()
        for nd in data.get("nodes", []):
            name = nd["node"].get("node", "?")
            seen.add(name)
            box = self.node_boxes.get(name)
            if box is None:
                box = self.node_boxes[name] = NodeBox()
                self.nodes_lay.addWidget(box)
            guests = [m for m in self.main.machines.values()
                      if m.get("sid") == self.sid and m.get("node") == name]
            counts = (sum(1 for m in guests if m.get("status") == "running"), len(guests))
            box.update_node(nd["node"], nd["status"], nd["storage"], counts)
        for name in [n for n in self.node_boxes if n not in seen]:
            self.node_boxes.pop(name).deleteLater()
        self.update_server()


class MachineTab(QWidget):
    def __init__(self, main, machine):
        super().__init__()
        self.main = main
        self.m = machine
        self.details = {}
        self.normal_exit = NORMAL_EXIT     # None = every exit is normal (terminal)
        self.on_exit = None                # function called when the console closes
        self.stack = QStackedWidget()
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(self.stack)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        page = QWidget()
        scroll.setWidget(page)
        pl = QVBoxLayout(page)
        pl.setContentsMargins(24, 24, 24, 24)
        self.title = QLabel()
        self.title.setFont(title_font())
        pl.addWidget(self.title)

        buttons = QHBoxLayout()
        st = self.style()
        self.b_on = QPushButton(st.standardIcon(QStyle.SP_MediaPlay), tr("Start"))
        self.b_off = QPushButton(st.standardIcon(QStyle.SP_MediaStop), tr("Shut down"))
        self.b_con = QPushButton()
        self.b_set = QPushButton(st.standardIcon(QStyle.SP_FileDialogDetailedView), tr("Connection settings"))
        self.b_key = QPushButton(key_icon(), tr("Copy SSH key"))
        self.b_key.setToolTip(tr("Install the public SSH key on the machine (ssh-copy-id)"))
        self.b_on.clicked.connect(lambda: main.vm_action("start", self.m))
        self.b_off.clicked.connect(lambda: main.vm_action("shutdown", self.m))
        self.b_con.clicked.connect(self.connect_console)
        self.b_set.clicked.connect(lambda: main.edit_conn(self.m))
        self.b_key.clicked.connect(lambda: main.copy_ssh_key(self.m))
        for b in (self.b_on, self.b_off, self.b_con, self.b_set, self.b_key):
            buttons.addWidget(b)
        buttons.addStretch()
        pl.addLayout(buttons)

        box = QGroupBox(tr("Summary"))
        g = QGridLayout(box)
        self.f = Fields(g, [
            ("status", tr("Status"), "text"), ("server", "Server", "text"), ("node", tr("Node"), "text"),
            ("vmid", "VMID", "text"), ("type", tr("Type"), "text"), ("os", tr("Operating system"), "text"),
            ("cpu", "CPU", "bar"), ("mem", tr("Memory"), "bar"), ("disk", tr("Disk"), "bar"),
            ("net", tr("Network (since boot)"), "text"), ("io", tr("Disk read / written"), "text"),
            ("uptime", "Uptime", "text"), ("conn", tr("Connection"), "text"),
            ("ip", tr("Address"), "text"), ("notes", tr("Notes"), "text"),
        ])
        pl.addWidget(box)
        self.message = QLabel()
        self.message.setWordWrap(True)
        self.message.setStyleSheet("color: #c0392b;")
        pl.addWidget(self.message)
        pl.addStretch()
        self.stack.addWidget(scroll)

        self.console = ConsoleView()
        self.console.finished.connect(self._console_finished)
        self.stack.addWidget(self.console)
        self.update_machine(machine)
        self.load_details()

    def load_details(self):
        client = self.main.clients.get(self.m.get("sid"))
        if self.m["kind"] != "proxmox" or not client:
            return
        self.main.run_async(client.vm_details, (self.m,), on_done=self._got_details,
                            on_fail=lambda _e: None)

    def _got_details(self, d):
        self.details = d
        self.update_machine(self.m)

    def update_machine(self, m):
        self.m = m
        f = self.f
        is_pve = m["kind"] == "proxmox"
        self.title.setText(m["name"])
        status = m.get("status", "-")
        f["status"].setText({"running": "🟢 " + tr("Running"), "stopped": "⚫ " + tr("Stopped"),
                             "paused": "🟡 " + tr("Paused")}.get(status, status))
        for k in ("server", "node", "vmid", "type", "os", "cpu", "mem", "disk", "net", "io",
                  "uptime", "notes"):
            f.show_row(k, is_pve)
        if is_pve:
            cfg = self.details.get("config", {})
            running = status == "running"
            srv = self.main.cfg.server(m["sid"]) or {}
            f["server"].setText(srv.get("name", m["sid"]))
            f["node"].setText(m["node"])
            f["vmid"].setText(str(m["vmid"]))
            f["type"].setText("VM (QEMU)" if m["vmtype"] == "qemu" else "Container (LXC)")
            ost = cfg.get("ostype", "")
            f["os"].setText(OS_NAMES.get(ost, ost.capitalize() or "-"))
            f["cpu"].set_cpu(m.get("cpu", 0) if running else 0, m.get("maxcpu", 0))
            f["mem"].set_usage(m.get("mem", 0) if running else 0, m.get("maxmem", 0))
            if m.get("disk"):
                f["disk"].set_usage(m.get("disk"), m.get("maxdisk"))
            else:   # QEMU VMs do not report the used space
                f["disk"].setValue(0)
                f["disk"].setFormat(tr("{size} allocated", size=fmt_bytes(m.get('maxdisk'))))
            f["net"].setText(f"↓ {fmt_bytes(m.get('netin'))}   ↑ {fmt_bytes(m.get('netout'))}"
                             if running else "-")
            f["io"].setText(f"{fmt_bytes(m.get('diskread'))} / {fmt_bytes(m.get('diskwrite'))}"
                            if running else "-")
            f["uptime"].setText(fmt_uptime(m.get("uptime")) if running else "-")
            notes = (cfg.get("description") or "").strip()
            f.show_row("notes", bool(notes))
            f["notes"].setText(notes[:600])
        conn = self.main.cfg.machine_conn(m)
        proto = conn["protocol"]
        conn_text = tr("{proto}  ·  user: {user}", proto=proto.upper(),
                       user=conn['user'] or tr("(asked when connecting)"))
        if proto == "ssh":
            conn_text += "  ·  " + (tr("SSH key") if conn["ssh_auth"] == "key" else tr("password"))
        f["conn"].setText(conn_text)
        f["ip"].setText(f"{conn['host'] or m.get('ip') or tr("automatic (guest agent)")}:{conn['port']}")
        self.b_con.setIcon(proto_icon(proto))
        self.b_con.setText(tr("Open terminal (SSH)") if proto == "ssh" else tr("Open console (RDP)"))
        self.b_key.setVisible(proto == "ssh")
        self.b_on.setVisible(is_pve)
        self.b_off.setVisible(is_pve)
        self.b_on.setEnabled(status != "running")
        self.b_off.setEnabled(status == "running")

    def connect_console(self):
        self.message.clear()
        self.main.start_console(self)

    def show_console(self):
        self.stack.setCurrentWidget(self.console)
        self.console.setFocus()

    def disconnect_console(self):
        self.console.stop()
        self.stack.setCurrentIndex(0)

    def _console_finished(self, code, log):
        self.stack.setCurrentIndex(0)
        if self.on_exit:
            callback, self.on_exit = self.on_exit, None
            callback(code)
        if self.normal_exit is not None and code not in self.normal_exit:
            self.main.credentials_failed(self.m)   # password possibly wrong: ask for it again
            tail = "\n".join(log.strip().splitlines()[-6:])
            self.message.setText(tr("Connection closed (code {code}).", code=code) + "\n" + tail)
        self.main.update_actions()


class HomePage(QWidget):
    """Home: list of Proxmox servers and main actions."""

    def __init__(self, main):
        super().__init__()
        self.main = main
        lay = QVBoxLayout(self)
        lay.setContentsMargins(48, 36, 48, 36)
        t = QLabel(f"<h1>{APP_NAME}</h1>" + tr(
            "<p>Consoles for Proxmox virtual machines: remote desktop (RDP) or terminal (SSH).</p><p>In the <b>Library</b>: click a server for its summary, click a VM for the machine summary, <b>Open console</b> to connect. In <b>Connection settings</b> choose RDP or SSH, user and password (saved in the KDE Wallet) or, for SSH, a key.</p>"))
        t.setWordWrap(True)
        lay.addWidget(t)

        box = QGroupBox("Server Proxmox VE")
        bl = QVBoxLayout(box)
        self.table = QTreeWidget()
        self.table.setHeaderLabels([tr("Name"), tr("Address"), tr("User"), tr("Status"), "VM"])
        self.table.setRootIsDecorated(False)
        self.table.setSelectionMode(QAbstractItemView.SingleSelection)
        self.table.header().setSectionResizeMode(QHeaderView.ResizeToContents)
        self.table.itemDoubleClicked.connect(lambda it, _c: main.open_server_tab(it.data(0, Qt.UserRole)))
        bl.addWidget(self.table)
        row = QHBoxLayout()
        st = self.style()
        for text, ic, slot in [
            (tr("Add server"), QStyle.SP_FileDialogNewFolder, main.add_server),
            (tr("Edit"), QStyle.SP_FileDialogDetailedView, lambda: self._with_sel(main.edit_server)),
            (tr("Remove"), QStyle.SP_TrashIcon, lambda: self._with_sel(main.remove_server)),
            (tr("Connect"), QStyle.SP_BrowserReload,
             lambda: self._with_sel(lambda s: main.connect_server(s, interactive=True))),
            (tr("Summary"), QStyle.SP_FileDialogInfoView, lambda: self._with_sel(main.open_server_tab)),
            ("Web UI", QStyle.SP_DirLinkIcon, lambda: self._with_sel(main.open_web)),
        ]:
            b = QPushButton(st.standardIcon(ic), text)
            b.clicked.connect(slot)
            row.addWidget(b)
        row.addStretch()
        bl.addLayout(row)
        lay.addWidget(box)

        row2 = QHBoxLayout()
        for a in (main.a_new, main.a_prefs):
            b = QPushButton(a.icon(), a.text())
            b.setMinimumHeight(40)
            b.clicked.connect(a.trigger)
            row2.addWidget(b)
        row2.addStretch()
        lay.addLayout(row2)
        lay.addWidget(QLabel(tr("<small>For automatic VM addresses install the <i>QEMU guest agent</i> and enable it in Proxmox (Options &gt; QEMU Guest Agent).</small>")))
        lay.addStretch()

    def _with_sel(self, fn):
        it = self.table.currentItem()
        if it is None and self.table.topLevelItemCount() == 1:
            it = self.table.topLevelItem(0)
        if it is None:
            QMessageBox.information(self, APP_NAME, tr("Select a server in the list."))
            return
        fn(it.data(0, Qt.UserRole))

    def refresh(self):
        cur = self.table.currentItem()
        cur_sid = cur.data(0, Qt.UserRole) if cur else None
        self.table.clear()
        for s in self.main.cfg.servers:
            vms = [m for m in self.main.machines.values() if m.get("sid") == s["id"]]
            running = sum(1 for m in vms if m.get("status") == "running")
            state = self.main.server_state.get(s["id"], tr("not connected"))
            it = QTreeWidgetItem([s["name"], s["url"], s["user"], state,
                                  f"{running} / {len(vms)}" if s["id"] in self.main.clients else "-"])
            it.setIcon(0, server_icon())
            it.setData(0, Qt.UserRole, s["id"])
            self.table.addTopLevelItem(it)
            if s["id"] == cur_sid:
                self.table.setCurrentItem(it)


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.cfg = Config()
        self.secrets = Secrets()
        self.clients = {}          # server id -> connected ProxmoxClient
        self.server_state = {}     # server id -> status text
        self.server_items = {}     # server id -> library node
        self.server_tabs = {}      # server id -> ServerTab
        self.machines = {}
        self.items = {}
        self.tabs_by_key = {}
        self.preview_key = None    # "preview" tab replaced by the next selection
        self.passwords = {}        # key -> unsaved password (memory only)
        self.ask_again = set()     # key: last connection failed, ask for the credentials
        self.pool = QThreadPool.globalInstance()
        self._workers = set()
        self._refreshing = set()

        self.setWindowTitle(APP_NAME)
        self.resize(1400, 900)
        self._build_actions()
        self._build_ui()
        self.load_servers()
        self.load_manual()

        self.timer = QTimer(self, interval=REFRESH_MS)
        self.timer.timeout.connect(self.refresh)
        QTimer.singleShot(200, self.connect_all)

    def _act(self, text, icon_, slot, shortcut=None):
        a = QAction(icon_ if isinstance(icon_, QIcon) else self.style().standardIcon(icon_), text, self)
        a.triggered.connect(slot)
        if shortcut:
            a.setShortcut(QKeySequence(shortcut))
        return a

    def _build_actions(self):
        S = QStyle
        self.a_start = self._act(tr("Start"), S.SP_MediaPlay, lambda: self.vm_action("start"), "Ctrl+B")
        self.a_shutdown = self._act(tr("Shut down guest"), S.SP_MediaStop, lambda: self.vm_action("shutdown"), "Ctrl+E")
        self.a_stop = self._act(tr("Power off (forced)"), S.SP_BrowserStop, lambda: self.vm_action("stop"))
        self.a_reboot = self._act(tr("Reboot"), S.SP_BrowserReload, lambda: self.vm_action("reboot"), "Ctrl+R")
        self.a_suspend = self._act(tr("Suspend"), S.SP_MediaPause, lambda: self.vm_action("suspend"), "Ctrl+Z")
        self.a_resume = self._act(tr("Resume"), S.SP_MediaSeekForward, lambda: self.vm_action("resume"))
        self.a_connect = self._act(tr("Open console"), S.SP_ComputerIcon, self.connect_current, "Ctrl+Return")
        self.a_disconnect = self._act(tr("Disconnect"), S.SP_DialogCloseButton, self.disconnect_current)
        self.a_full = self._act(tr("Full screen"), S.SP_TitleBarMaxButton, self.toggle_fullscreen, "Ctrl+Alt+Return")
        self.a_conn = self._act(tr("Connection settings..."), S.SP_FileDialogDetailedView, lambda: self.edit_conn())
        self.a_refresh = self._act(tr("Refresh"), S.SP_BrowserReload, self.refresh, "F5")
        self.a_new = self._act(tr("New connection..."), S.SP_FileIcon, self.add_manual, "Ctrl+N")
        self.a_del = self._act(tr("Remove connection"), S.SP_TrashIcon, self.remove_manual)
        self.a_add_server = self._act(tr("Add Proxmox server..."), S.SP_DriveNetIcon, self.add_server)
        self.a_connect_all = self._act(tr("Connect to all servers"), S.SP_BrowserReload, self.connect_all)
        self.a_prefs = self._act(tr("Preferences..."), S.SP_FileDialogInfoView, self.open_settings, "Ctrl+P")
        self.a_web = self._act(tr("Open Proxmox Web UI"), S.SP_DirLinkIcon, lambda: self.open_web())
        self.a_copy_key = self._act(tr("Copy SSH key to the machine..."), key_icon(),
                                    lambda: self.copy_ssh_key())
        self.a_quit = self._act(tr("Quit"), S.SP_DialogCloseButton, self.close, "Ctrl+Q")

    def _build_ui(self):
        mb = self.menuBar()
        m = mb.addMenu(tr("&File"))
        for a in (self.a_add_server, self.a_connect_all, self.a_web, None, self.a_new, self.a_del,
                  None, self.a_prefs, None, self.a_quit):
            m.addSeparator() if a is None else m.addAction(a)
        m = mb.addMenu("&VM")
        m.addMenu(tr("Power")).addActions([self.a_start, self.a_shutdown, self.a_stop,
                                              self.a_reboot, self.a_suspend, self.a_resume])
        for a in (self.a_connect, self.a_disconnect, None, self.a_conn, self.a_copy_key):
            m.addSeparator() if a is None else m.addAction(a)
        m = mb.addMenu(tr("&View"))
        m.addActions([self.a_full, self.a_refresh])
        m = mb.addMenu(tr("&Help"))
        m.addAction(tr("About"), self.about)

        self.tb = self.addToolBar(tr("Main"))
        self.tb.setMovable(False)
        for a in (self.a_start, self.a_shutdown, self.a_suspend, self.a_reboot, None,
                  self.a_connect, self.a_disconnect, self.a_full, None, self.a_refresh, self.a_new):
            self.tb.addSeparator() if a is None else self.tb.addAction(a)

        self.dock = QDockWidget(tr("Library"), self)
        self.dock.setFeatures(QDockWidget.DockWidgetMovable)
        lib = QWidget()
        ll = QVBoxLayout(lib)
        ll.setContentsMargins(4, 4, 4, 4)
        self.search = QLineEdit()
        self.search.setPlaceholderText(tr("Search..."))
        self.search.textChanged.connect(self.filter_tree)
        self.tree = QTreeWidget()
        self.tree.setHeaderHidden(True)
        self.tree.itemDoubleClicked.connect(self._tree_double)
        self.tree.currentItemChanged.connect(self._tree_selected)
        self.tree.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self._tree_menu)
        self.root_manual = QTreeWidgetItem(self.tree, [tr("Connections")])
        self.root_manual.setIcon(0, self.style().standardIcon(QStyle.SP_DirIcon))
        self.root_manual.setExpanded(True)
        ll.addWidget(self.search)
        ll.addWidget(self.tree)
        self.dock.setWidget(lib)
        self.dock.setMinimumWidth(260)
        self.addDockWidget(Qt.LeftDockWidgetArea, self.dock)

        self.tabs = QTabWidget()
        self.tabs.setTabsClosable(True)
        self.tabs.setMovable(True)
        self.tabs.setDocumentMode(True)
        self.tabs.tabCloseRequested.connect(self.close_tab)
        self.tabs.currentChanged.connect(self._tab_changed)
        self.home = HomePage(self)
        self.tabs.addTab(self.home, self.style().standardIcon(QStyle.SP_DirHomeIcon), "Home")
        self.tabs.tabBar().setTabButton(0, QTabBar.ButtonPosition.RightSide, None)
        self.setCentralWidget(self.tabs)
        self.statusBar().showMessage(tr("Ready"))
        self.update_actions()

    def run_async(self, fn, args=(), on_done=None, on_fail=None):
        w = Worker(fn, *args)
        self._workers.add(w)

        def finish(_=None):
            self._workers.discard(w)

        w.signals.done.connect(lambda r: (finish(), on_done and on_done(r)))
        w.signals.failed.connect(lambda e: (finish(), (on_fail or self.show_error)(e)))
        self.pool.start(w)

    def show_error(self, msg):
        self.statusBar().showMessage(tr("Error: {msg}", msg=msg), 10000)

    # ---- server Proxmox ----
    def load_servers(self):
        for s in self.cfg.servers:
            self._add_server_item(s)
        self.home.refresh()

    def _add_server_item(self, s):
        item = QTreeWidgetItem()
        item.setIcon(0, server_icon())
        item.setData(0, Qt.UserRole, f"server:{s['id']}")
        self.tree.insertTopLevelItem(self.tree.indexOfTopLevelItem(self.root_manual), item)
        item.setExpanded(True)
        self.server_items[s["id"]] = item
        self._update_server_item(s["id"])

    def _update_server_item(self, sid):
        s, item = self.cfg.server(sid), self.server_items.get(sid)
        if s and item:
            state = "" if sid in self.clients else f"  ({self.server_state.get(sid, tr("not connected"))})"
            item.setText(0, s["name"] + state)
        tab = self.server_tabs.get(sid)
        if tab:
            tab.update_server()
            self.tabs.setTabText(self.tabs.indexOf(tab), s["name"] if s else "?")
        self.home.refresh()

    def connect_all(self):
        for s in self.cfg.servers:
            self.connect_server(s["id"], interactive=False)

    def connect_server(self, sid, interactive=True):
        s = self.cfg.server(sid)
        if not s:
            return
        password = ""
        if not (s.get("token_id") and s.get("token_secret")):
            password, ok = QInputDialog.getText(self, tr("Proxmox login"),
                                                tr("Password for {user} on {name} ({url}):",
                                                   user=s['user'], name=s['name'], url=s['url']),
                                                QLineEdit.Password)
            if not ok:
                self.server_state[sid] = tr("not connected")
                self._update_server_item(sid)
                return
        client = ProxmoxClient(s["url"], s["user"], s.get("token_id", ""), s.get("token_secret", ""),
                               password, s.get("verify_ssl", False))
        self.clients.pop(sid, None)
        self.server_state[sid] = tr("connecting...")
        self._update_server_item(sid)

        def ok(_):
            self.clients[sid] = client
            self.server_state[sid] = tr("connected")
            self._update_server_item(sid)
            self.statusBar().showMessage(tr("Connected to {name}", name=s['name']), 5000)
            self.refresh_server(sid)
            tab = self.server_tabs.get(sid)
            if tab:
                tab.load()
            self.timer.start()

        def fail(err):
            self.server_state[sid] = tr("error: {err}", err=err)
            self._update_server_item(sid)
            if interactive:
                QMessageBox.warning(self, "Proxmox", tr("Login to {name} failed:", name=s['name'])
                                    + "\n" + str(err))
            else:
                self.show_error(f"{s['name']}: {err}")

        self.run_async(client.login, on_done=ok, on_fail=fail)

    def add_server(self):
        d = ServerDialog(self, tr("Add Proxmox server"), {})
        if d.exec() != QDialog.Accepted or not d.values()["url"]:
            return
        s = {"id": uuid.uuid4().hex[:8], **d.values()}
        self.cfg.servers.append(s)
        self.cfg.save()
        self._add_server_item(s)
        self.connect_server(s["id"], interactive=True)

    def edit_server(self, sid):
        s = self.cfg.server(sid)
        if not s:
            return
        d = ServerDialog(self, f"Server - {s['name']}", s)
        if d.exec() != QDialog.Accepted:
            return
        s.update(d.values())
        self.cfg.save()
        self.clients.pop(sid, None)
        self.server_state[sid] = tr("not connected")
        self._update_server_item(sid)
        self.connect_server(sid, interactive=True)

    def remove_server(self, sid):
        s = self.cfg.server(sid)
        if not s:
            return
        if QMessageBox.question(self, APP_NAME, tr("Remove the server '{name}' from the list?\n"
                                                   "(the VMs on Proxmox are not touched)",
                                                   name=s['name'])) != QMessageBox.Yes:
            return
        for key in [k for k in self.machines if k.startswith(f"pve:{sid}:")]:
            self.close_tab_for(key)
            self.machines.pop(key, None)
            self.items.pop(key, None)
        tab = self.server_tabs.pop(sid, None)
        if tab:
            self.tabs.removeTab(self.tabs.indexOf(tab))
            tab.deleteLater()
        item = self.server_items.pop(sid, None)
        if item:
            self.tree.takeTopLevelItem(self.tree.indexOfTopLevelItem(item))
        self.clients.pop(sid, None)
        self.server_state.pop(sid, None)
        self.cfg.data["servers"] = [x for x in self.cfg.servers if x["id"] != sid]
        self.cfg.save()
        self.home.refresh()

    def open_server_tab(self, sid):
        if not self.cfg.server(sid):
            return
        tab = self.server_tabs.get(sid)
        if tab is None:
            tab = self.server_tabs[sid] = ServerTab(self, sid)
            self.tabs.addTab(tab, server_icon(), self.cfg.server(sid)["name"])
            tab.load()
        self.tabs.setCurrentWidget(tab)

    # ---- VM list ----
    def refresh(self):
        for sid in list(self.clients):
            self.refresh_server(sid)
        w = self.tabs.currentWidget()
        if isinstance(w, ServerTab):
            w.load()
        elif isinstance(w, MachineTab):
            w.load_details()

    def refresh_server(self, sid):
        client = self.clients.get(sid)
        if not client or sid in self._refreshing:
            return
        self._refreshing.add(sid)

        def done(vms):
            self._refreshing.discard(sid)
            self.update_vms(sid, vms)

        def fail(e):
            self._refreshing.discard(sid)
            self.server_state[sid] = tr("error: {err}", err=e)
            self._update_server_item(sid)
            self.show_error(f"{(self.cfg.server(sid) or {}).get('name', sid)}: {e}")

        self.run_async(client.list_vms, on_done=done, on_fail=fail)

    def update_vms(self, sid, vms):
        parent = self.server_items.get(sid)
        if parent is None:
            return
        if self.server_state.get(sid) != tr("connected"):
            self.server_state[sid] = tr("connected")
            self._update_server_item(sid)
        seen = set()
        st = self.style()
        icons = {"running": QStyle.SP_MediaPlay, "stopped": QStyle.SP_MediaStop, "paused": QStyle.SP_MediaPause}
        for v in sorted(vms, key=lambda x: x.get("vmid", 0)):
            key = f"pve:{sid}:{v['vmid']}"
            seen.add(key)
            old = self.machines.get(key, {})
            m = {"key": key, "kind": "proxmox", "sid": sid, "name": v.get("name") or f"VM {v['vmid']}",
                 "node": v["node"], "vmtype": v["type"], "vmid": v["vmid"],
                 "status": v.get("status", "unknown"), "ip": old.get("ip", "")}
            for k in ("cpu", "maxcpu", "mem", "maxmem", "disk", "maxdisk", "uptime",
                      "netin", "netout", "diskread", "diskwrite"):
                m[k] = v.get(k, 0)
            self.machines[key] = m
            item = self.items.get(key)
            if item is None:
                item = QTreeWidgetItem(parent)
                item.setData(0, Qt.UserRole, key)
                self.items[key] = item
            proto = self.cfg.machine_conn(m)["protocol"]
            item.setText(0, f"{m['name']}  ({m['vmid']})" + ("  · SSH" if proto == "ssh" else ""))
            item.setIcon(0, st.standardIcon(icons.get(m["status"], QStyle.SP_MessageBoxQuestion)))
            if key in self.tabs_by_key:
                self.tabs_by_key[key].update_machine(m)
        for key in [k for k in self.items if k.startswith(f"pve:{sid}:") and k not in seen]:
            parent.removeChild(self.items.pop(key))
            self.machines.pop(key, None)
        self.filter_tree(self.search.text())
        self.home.refresh()
        self.update_actions()

    # ---- manual connections ----
    def load_manual(self):
        for e in self.cfg.data["manual"]:
            self._add_manual_item(e)

    def _add_manual_item(self, e):
        key = f"manual:{e['id']}"
        self.machines[key] = {"key": key, "kind": "manual", "id": e["id"], "name": e["name"], "status": "-"}
        item = QTreeWidgetItem(self.root_manual, [e["name"]])
        item.setData(0, Qt.UserRole, key)
        self.items[key] = item
        self._refresh_manual_item(self.machines[key])

    def _refresh_manual_item(self, m):
        item = self.items.get(m["key"])
        if item:
            item.setText(0, m["name"])
            item.setIcon(0, proto_icon(self.cfg.machine_conn(m)["protocol"]))

    def add_manual(self):
        d = ConnSettingsDialog(self, tr("New connection"),
                               {"embed": True, "rdp_flags": self.cfg.rdp["flags"],
                                "scale": self.cfg.rdp.get("scale", 100)},
                               self.secrets, with_name=True)
        if d.exec() != QDialog.Accepted or not d.values()["host"]:
            return
        vals = d.values()
        e = {"id": uuid.uuid4().hex[:8], "name": d.name.text().strip() or vals["host"],
             **self.cfg.compact_conn(vals)}
        self.cfg.data["manual"].append(e)
        self.cfg.save()
        self._add_manual_item(e)
        self._store_password(self.machines[f"manual:{e['id']}"], vals["user"], d.password.text())

    def remove_manual(self):
        m = self.current_machine()
        if not m or m["kind"] != "manual":
            return
        if QMessageBox.question(self, APP_NAME, tr("Remove '{name}'?", name=m['name'])) != QMessageBox.Yes:
            return
        self.close_tab_for(m["key"])
        self.secrets.delete(m, self.cfg.machine_conn(m)["user"])
        self.cfg.data["manual"] = [x for x in self.cfg.data["manual"] if x["id"] != m["id"]]
        self.cfg.save()
        self.root_manual.removeChild(self.items.pop(m["key"]))
        self.machines.pop(m["key"], None)

    # ---- selection / tabs ----
    def current_machine(self):
        """Machine the menus and toolbar act on: the library selection
        if it has focus, otherwise the open tab, otherwise the selection."""
        item = self.tree.currentItem()
        key = item.data(0, Qt.UserRole) if item else None
        w = self.tabs.currentWidget()
        if self.tree.hasFocus() and key:
            return self.machines.get(key)
        if isinstance(w, MachineTab):
            return self.machines.get(w.m["key"], w.m)
        return self.machines.get(key) if key else None

    def _item_key(self, item):
        return item.data(0, Qt.UserRole) if item else None

    def _tree_selected(self, item, _prev):
        """Click on a server -> server summary; on a VM -> VM summary."""
        key = self._item_key(item)
        if key and key.startswith("server:"):
            self.open_server_tab(key[7:])
        elif key in self.machines:
            self.open_tab(self.machines[key], preview=True)
        self.update_actions()

    def _tree_double(self, item, _col):
        key = self._item_key(item)
        if key in self.machines:
            self.open_tab(self.machines[key])

    def _tree_menu(self, pos):
        item = self.tree.itemAt(pos)
        key = self._item_key(item)
        menu = QMenu(self)
        if key and key.startswith("server:"):
            sid = key[7:]
            menu.addAction(server_icon(), tr("Summary"), lambda: self.open_server_tab(sid))
            menu.addAction(tr("Connect"), lambda: self.connect_server(sid, interactive=True))
            menu.addAction(tr("Open Web UI"), lambda: self.open_web(sid))
            menu.addSeparator()
            menu.addAction(tr("Edit server..."), lambda: self.edit_server(sid))
            menu.addAction(tr("Remove server"), lambda: self.remove_server(sid))
        elif key in self.machines:
            self.tree.setCurrentItem(item)
            menu.addActions([self.a_connect, self.a_disconnect])
            menu.addSeparator()
            menu.addActions([self.a_start, self.a_shutdown, self.a_stop, self.a_reboot])
            menu.addSeparator()
            menu.addActions([self.a_conn, self.a_copy_key, self.a_del])
        else:
            menu.addActions([self.a_new, self.a_add_server])
        menu.exec(self.tree.viewport().mapToGlobal(pos))

    def _tab_changed(self, _idx):
        w = self.tabs.currentWidget()
        if isinstance(w, MachineTab) and w.console.running():
            QTimer.singleShot(50, w.console.focus_child)
        elif isinstance(w, ServerTab):
            w.load()
        self.update_actions()

    def _remove_machine_tab(self, tab):
        self.tabs_by_key.pop(tab.m["key"], None)
        self.tabs.removeTab(self.tabs.indexOf(tab))
        tab.deleteLater()

    def open_tab(self, m, preview=False):
        key = m["key"]
        tab = self.tabs_by_key.get(key)
        if tab is None:
            old = self.tabs_by_key.get(self.preview_key) if preview else None
            if old is not None and not old.console.running():
                self._remove_machine_tab(old)
            tab = MachineTab(self, m)
            self.tabs_by_key[key] = tab
            self.tabs.addTab(tab, proto_icon(self.cfg.machine_conn(m)["protocol"]), m["name"])
            self.preview_key = key if preview else None
        elif not preview and self.preview_key == key:
            self.preview_key = None
        self.tabs.setCurrentWidget(tab)
        return tab

    def close_tab(self, idx):
        w = self.tabs.widget(idx)
        if isinstance(w, MachineTab):
            if w.console.running() and QMessageBox.question(
                    self, APP_NAME, tr("Disconnect the console of '{name}'?", name=w.m['name'])) != QMessageBox.Yes:
                return
            w.console.stop()
            if self.preview_key == w.m["key"]:
                self.preview_key = None
            self._remove_machine_tab(w)
        elif isinstance(w, ServerTab):
            self.server_tabs.pop(w.sid, None)
            self.tabs.removeTab(idx)
            w.deleteLater()

    def close_tab_for(self, key):
        tab = self.tabs_by_key.get(key)
        if tab:
            tab.console.stop()
            self.close_tab(self.tabs.indexOf(tab))

    def filter_tree(self, text):
        t = text.lower()
        for item in self.items.values():
            item.setHidden(bool(t) and t not in item.text(0).lower())

    def update_actions(self):
        m = self.current_machine()
        pve = bool(m and m["kind"] == "proxmox" and m.get("sid") in self.clients)
        status = m.get("status") if m else None
        self.a_start.setEnabled(pve and status in ("stopped", "paused"))
        self.a_shutdown.setEnabled(pve and status == "running")
        self.a_stop.setEnabled(pve and status in ("running", "paused"))
        self.a_reboot.setEnabled(pve and status == "running")
        self.a_suspend.setEnabled(pve and status == "running")
        self.a_resume.setEnabled(pve and status == "paused")
        self.a_conn.setEnabled(bool(m))
        self.a_copy_key.setEnabled(bool(m))
        self.a_del.setEnabled(bool(m and m["kind"] == "manual"))
        tab = self.tabs_by_key.get(m["key"]) if m else None
        connected = bool(tab and tab.console.running())
        self.a_connect.setEnabled(bool(m) and not connected)
        self.a_disconnect.setEnabled(connected)

    def vm_action(self, action, m=None):
        m = m or self.current_machine()
        client = self.clients.get(m.get("sid")) if m else None
        if not m or m["kind"] != "proxmox" or not client:
            return
        if action == "stop" and QMessageBox.question(
                self, APP_NAME, tr("Force power off '{name}'? (like pulling the plug)", name=m['name'])) != QMessageBox.Yes:
            return
        self.statusBar().showMessage(f"{action} → {m['name']}...", 5000)
        self.run_async(client.action, (m, action),
                       on_done=lambda _: QTimer.singleShot(1500, lambda: self.refresh_server(m["sid"])))

    # ---- credentials ----
    def _store_password(self, m, user, password, remember=True):
        """Saves the password in the wallet (or in memory if not available)."""
        if not password:
            return
        if remember and self.secrets.set(m, user, password):
            self.passwords.pop(m["key"], None)
        else:
            self.passwords[m["key"]] = password

    def credentials_failed(self, m):
        self.passwords.pop(m["key"], None)
        self.ask_again.add(m["key"])

    def get_credentials(self, m, conn, password_optional=False):
        """(user, password) for the connection; None if cancelled.
        Order: memory -> wallet -> asking the user."""
        key, user = m["key"], conn["user"]
        if key not in self.ask_again and user:
            pw = self.passwords.get(key)
            if pw is None:
                pw = self.secrets.get(m, user)
            if pw is not None or password_optional:
                return user, pw or ""
        saved = self.secrets.get(m, user) is not None
        d = CredentialsDialog(self, tr("Login to {name} ({proto})", name=m['name'],
                                         proto=conn['protocol'].upper()), user,
                              self.secrets.ok, remember=saved or self.secrets.ok,
                              password_optional=password_optional)
        if d.exec() != QDialog.Accepted:
            return None
        new_user = d.user.text().strip()
        password = d.password.text()
        if not new_user or (not password and not password_optional):
            return None
        self.ask_again.discard(key)
        if d.remember.isChecked():
            if new_user != user:
                self.secrets.delete(m, user)
                self.cfg.set_machine_conn(m, {"user": new_user})
                tab = self.tabs_by_key.get(key)
                if tab:
                    tab.update_machine(m)
            self._store_password(m, new_user, password)
        else:
            self.secrets.delete(m, new_user)
            self.passwords[key] = password
        return new_user, password

    def edit_conn(self, m=None):
        m = m or self.current_machine()
        if not m:
            return False
        cur = self.cfg.machine_conn(m)
        saved = self.secrets.get(m, cur["user"]) is not None or m["key"] in self.passwords
        d = ConnSettingsDialog(self, tr("Connection - {name}", name=m['name']), cur, self.secrets, saved_password=saved)
        if d.exec() != QDialog.Accepted:
            return False
        vals = d.values()
        self.cfg.set_machine_conn(m, vals)
        if d.forget.isChecked() or vals["user"] != cur["user"]:
            self.secrets.delete(m, cur["user"])
            self.passwords.pop(m["key"], None)
        self._store_password(m, vals["user"], d.password.text())
        self.ask_again.discard(m["key"])
        if m["kind"] == "manual":
            self._refresh_manual_item(m)
        tab = self.tabs_by_key.get(m["key"])
        if tab:
            tab.update_machine(m)
            self.tabs.setTabIcon(self.tabs.indexOf(tab), proto_icon(vals["protocol"]))
        if m["kind"] == "proxmox":
            self.refresh_server(m["sid"])
        return True

    # ---- console ----
    def connect_current(self):
        m = self.current_machine()
        if m:
            self.open_tab(m).connect_console()

    def disconnect_current(self):
        m = self.current_machine()
        tab = self.tabs_by_key.get(m["key"]) if m else None
        if tab:
            tab.disconnect_console()
            self.update_actions()

    def copy_ssh_key(self, m=None):
        """Installs the public SSH key on the machine (ssh-copy-id in the terminal)."""
        m = m or self.current_machine()
        if not m:
            return
        tab = self.open_tab(m)
        tab.message.clear()
        self.start_console(tab, copy_key=True)

    def start_console(self, tab, copy_key=False):
        m = tab.m
        if self.preview_key == m["key"]:
            self.preview_key = None     # with the console open the tab stays
        # first connection to a VM never configured: settings first
        if m["kind"] == "proxmox" and m["key"] not in self.cfg.data["vms"]:
            if not self.edit_conn(m):
                return
        conn = self.cfg.machine_conn(m)
        if conn["host"]:
            self._launch(tab, conn["host"], conn, copy_key)
            return
        client = self.clients.get(m.get("sid"))
        if m["kind"] != "proxmox" or not client:
            tab.message.setText(tr("Set the host in Connection settings."))
            return
        if m.get("status") != "running":
            tab.message.setText(tr("The VM is off: start it before opening the console."))
            return
        self.statusBar().showMessage(tr("Looking up the IP address via the guest agent..."))

        def got_ip(ip):
            if not ip:
                tab.message.setText(tr("IP not available: install the QEMU guest agent in the VM or set the host in Connection settings."))
                return
            m["ip"] = ip
            tab.update_machine(m)
            self._launch(tab, ip, conn, copy_key)

        self.run_async(client.guest_ip, (m, self.cfg.rdp["prefer_ip_prefix"]), on_done=got_ip)

    def _launch(self, tab, host, conn, copy_key=False):
        tab.on_exit = None
        if copy_key or conn["protocol"] == "ssh":
            self._launch_ssh(tab, host, conn, copy_key)
        else:
            self._launch_rdp(tab, host, conn)
        self.update_actions()

    def _launch_rdp(self, tab, host, conn):
        m = tab.m
        cred = self.get_credentials(m, conn)
        if cred is None:
            return
        user, password = cred
        args = [f"/v:{host}:{conn['port']}", f"/u:{user}", f"/p:{password}", f"/t:{m['name']}"]
        if conn["domain"]:
            args.append(f"/d:{conn['domain']}")
        args += self.cfg.rdp_args(conn)
        if conn["embed"]:
            # show the console first: a widget never shown measures 640x480
            tab.show_console()
            QApplication.processEvents()
            args.append(f"/parent-window:{tab.console.window_id()}")
        w, h = tab.console.physical_size()
        args.append(f"/size:{w}x{h}")
        tab.normal_exit = NORMAL_EXIT
        tab.console.start(find_xfreerdp(self.cfg), args, conn["embed"])
        self.statusBar().showMessage(tr("RDP console opened on {host}", host=host), 5000)

    def _ssh_key_to_copy(self, tab, conn):
        """Private key to install (its .pub goes on the machine); "" = cancel."""
        key = os.path.expanduser(conn["ssh_key"]) if conn["ssh_key"] else default_ssh_key()
        if not key:
            if QMessageBox.question(self, APP_NAME, tr("No SSH key found in ~/.ssh. Create one now?")) != QMessageBox.Yes:
                return ""
            key = os.path.expanduser(generate_ssh_key(self))
        if key and not Path(f"{key}.pub").exists():
            tab.message.setText(tr("Public key {path} not found.", path=home_short(f"{key}.pub")))
            return ""
        return key

    def _launch_ssh(self, tab, host, conn, copy_key=False):
        m = tab.m
        is_ssh = conn["protocol"] == "ssh"
        port = conn["port"] if is_ssh else DEFAULT_PORT["ssh"]
        use_key = is_ssh and conn["ssh_auth"] == "key" and not copy_key
        key = os.path.expanduser(conn["ssh_key"]) if conn["ssh_key"] else ""
        if copy_key:
            key = self._ssh_key_to_copy(tab, conn)
            if not key:
                return
        if use_key:
            # key login: no password (ssh asks for the passphrase in the terminal)
            user, password = conn["user"], ""
            if not user:
                user, ok = QInputDialog.getText(self, tr("Login to {name} ({proto})", name=m["name"],
                                                         proto="SSH"), tr("User:"))
                user = user.strip()
                if not ok or not user:
                    return
                self.cfg.set_machine_conn(m, {"user": user})
                tab.update_machine(m)
        else:
            cred = self.get_credentials(m, conn, password_optional=True)
            if cred is None:
                return
            user, password = cred
        target = f"{user}@{host}" if user else host
        opts = ["-p", str(port), "-o", "StrictHostKeyChecking=accept-new"]
        if copy_key:
            ssh = ["ssh-copy-id", "-i", f"{key}.pub", *opts, target]
        else:
            ssh = ["ssh", *opts]
            if use_key and key:
                ssh += ["-i", key, "-o", "IdentitiesOnly=yes"]
            ssh += shlex.split(self.cfg.ssh["extra_args"])
            if is_ssh:
                ssh += shlex.split(conn["extra_args"])
            ssh.append(target)
        env = None
        if password:
            ssh = ["sshpass", "-e"] + ssh      # password from the SSHPASS variable, not in argv
            env = {"SSHPASS": password}
        q = shlex.quote
        wrong_pw = tr("Wrong password: fix it in Connection settings.")
        if copy_key:
            marker = Path(tempfile.gettempdir()) / f"vmstation-key-{uuid.uuid4().hex}"
            # the terminal stays open to show the result; the file signals success
            script = (f"{shlex.join(ssh)}; rc=$?; echo; "
                      f"if [ $rc -eq 0 ]; then : > {q(str(marker))}; "
                      f"printf '%s\\n' {q(tr("Key installed: from now on SSH access uses the key."))}; "
                      f"else [ $rc -eq 5 ] && printf '%s\\n' {q(wrong_pw)}; "
                      f"printf {q(tr("Copying the key failed (code %s).") + chr(92) + 'n')} $rc; fi; "
                      f"printf '%s ' {q(tr("Press Enter to close."))}; read _")

            def copied(_code):
                if not marker.exists():
                    return
                marker.unlink(missing_ok=True)
                values = {"ssh_key": conn["ssh_key"] or home_short(key)}
                if is_ssh:
                    values["ssh_auth"] = "key"
                self.cfg.set_machine_conn(m, values)
                tab.update_machine(self.machines.get(m["key"], m))
                self.statusBar().showMessage(tr("SSH key installed on {host}", host=host), 8000)

            tab.on_exit = copied
            title = f"{m['name']} - ssh-copy-id"
        else:
            # if the connection drops the terminal stays open and shows the reason
            script = (f"{shlex.join(ssh)}; rc=$?; if [ $rc -ne 0 ]; then echo; "
                      f"[ $rc -eq 5 ] && printf '%s\\n' {q(wrong_pw)}; "
                      f"printf {q(tr("Connection closed (code %s). Press Enter to close.") + chr(92) + 'n')} $rc; "
                      f"read _; fi")
            title = f"{m['name']} - SSH"
        cmd = ["sh", "-c", script]
        tab.normal_exit = None          # the terminal itself shows the errors
        embed = conn["embed"] if is_ssh else True
        if embed or not shutil.which("konsole"):
            s = self.cfg.ssh
            args = ["-T", title, "-fa", s["font"], "-fs", str(s["font_size"]),
                    "-bg", "#1e1e1e", "-fg", "#d4d4d4", "-cr", "#d4d4d4", "-b", "6", "-sl", "10000",
                    "-xrm", "XTerm*termName: xterm-256color",
                    "-xrm", "XTerm*locale: true",
                    "-xrm", "XTerm*scrollTtyOutput: false",
                    "-xrm", "XTerm*scrollKey: true",
                    "-xrm", "XTerm*bellIsUrgent: true",
                    "-xrm", "XTerm*metaSendsEscape: true",
                    "-xrm", "XTerm*VT100.translations: #override \\n"
                            " Ctrl Shift <Key>C: copy-selection(CLIPBOARD) \\n"
                            " Ctrl Shift <Key>V: insert-selection(CLIPBOARD) \\n"
                            " Shift <Key>Insert: insert-selection(CLIPBOARD)"]
            if embed:
                tab.show_console()
                args = ["-into", str(tab.console.window_id())] + args
            tab.console.start("xterm", args + ["-e"] + cmd, embed, env)
        else:
            tab.console.start("konsole", ["--separate", "-p", f"tabtitle={title}", "-e"] + cmd,
                              False, env)
        self.statusBar().showMessage(tr("SSH terminal opened on {host}", host=host), 5000)

    # ---- misc ----
    def toggle_fullscreen(self):
        full = not self.isFullScreen()
        self.menuBar().setVisible(not full)
        self.dock.setVisible(not full)
        self.statusBar().setVisible(not full)
        self.tabs.tabBar().setVisible(not full)
        # the toolbar stays visible so full screen can be left
        self.showFullScreen() if full else self.showNormal()
        tab = self.tabs.currentWidget()
        if isinstance(tab, MachineTab):
            tab.console.setFocus()

    def open_settings(self):
        d = SettingsDialog(self, self.cfg)
        if d.exec() == QDialog.Accepted:
            d.apply()

    def open_web(self, sid=None):
        if sid is None:
            m = self.current_machine()
            item_key = self._item_key(self.tree.currentItem()) or ""
            w = self.tabs.currentWidget()
            if m and m.get("sid"):
                sid = m["sid"]
            elif item_key.startswith("server:"):
                sid = item_key[7:]
            elif isinstance(w, ServerTab):
                sid = w.sid
            elif self.cfg.servers:
                sid = self.cfg.servers[0]["id"]
        s = self.cfg.server(sid)
        if s:
            subprocess.Popen(["xdg-open", s["url"]])

    def about(self):
        wallet = tr("KDE Wallet") if self.secrets.ok else tr("in memory only (wallet not available)")
        QMessageBox.about(self, APP_NAME, f"<h3>{APP_NAME}</h3>" + tr(
            "<p>Proxmox VM consoles: RDP (xfreerdp) and SSH (xterm / Konsole), multiple Proxmox servers.</p><p>Configuration: {config}<br>Passwords: {wallet}<br>Language: {lang}</p>",
            config=CONFIG_FILE, wallet=wallet, lang=LANG_NAMES[LANG]))

    def closeEvent(self, e):
        running = [t for t in self.tabs_by_key.values() if t.console.running()]
        if running and QMessageBox.question(
                self, APP_NAME, tr("{n} open consoles will be closed. Quit?", n=len(running))) != QMessageBox.Yes:
            e.ignore()
            return
        for t in running:
            t.console.stop()
        e.accept()


def main():
    # xfreerdp and xterm are X11 clients: the Qt window must be X11 too
    # (XWayland) for embedding in tabs to work.
    os.environ.setdefault("QT_QPA_PLATFORM", "xcb")
    app = QApplication(sys.argv)
    app.setApplicationName(APP_NAME)
    app.setDesktopFileName("vmstation")
    w = MainWindow()
    w.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
