#!/usr/bin/env python3
"""DGX Mission Control: live telemetry + service control for the HP ZGX Nano (NVIDIA GB10).

Standard library only. Listens on 127.0.0.1 so the controls are never exposed to the network.
Samples the box once a second and keeps five minutes of history in memory.
"""
import hmac, json, os, re, secrets, socket, subprocess, threading, time, urllib.parse, urllib.request
from collections import deque
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

HOST, PORT = "127.0.0.1", 8765
HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
HOME = os.path.expanduser("~")
HISTORY = 300

# ---------------------------------------------------------------- services
# kind: "user" = systemd --user unit, "llm" = docker/nohup LLM launched by script, "docker" = plain containers
# cat: dashboard group, rendered in CATS order (models first, then what's built on them)
CATS = [("model", "Models", "engines holding weights in unified memory"),
        ("app", "Applications", "booth experiences built on the models"),
        ("system", "System", "remote access")]
# Packaged boxes: the component list is GENERATED at install time from what is
# actually present on the box (scripts/gen-services.sh -> mc.json next to this
# file). Vision workloads and anything not installed simply never appear.
# The hardcoded list below is the fallback (and the development default).
def _load_services():
    p = os.path.join(HERE, "mc.json")
    if os.path.exists(p):
        try:
            d = json.load(open(p))
            if d.get("services"):
                return d["services"], d.get("tailnet_origin", "")
        except Exception:
            pass
    return [
        {"id": "llm27b", "cat": "model", "name": "Qwen3.8-27B", "engine": "SGLang + DFlash2", "port": 30000, "kind": "llm",
         "container": "qwen38-sglang-run", "need_gb": 62},
        {"id": "llm35b", "cat": "model", "name": "Qwen3.6-35B-A3B", "engine": "SGLang · NVFP4 MoE", "port": 30002, "kind": "sys",
         "unit": "qwen38-35b.service", "need_gb": 60},   # need_gb = the container's docker memory cap
        {"id": "webui", "cat": "app", "name": "Open WebUI", "engine": "chat · qwen3.6-35b", "port": 80, "kind": "docker",
         "containers": ["open-webui", "open-webui-proxy"], "need_gb": 2, "url": "http://localhost/"},   # remote_url comes from generated mc.json
    ], ""
SERVICES, _TAILNET_ORIGIN_CFG = _load_services()
SVC = {s["id"]: s for s in SERVICES}
LLM_ENV = ("DRAFT2_REPO=maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal DRAFT2_REV=bd7a934213c47a9e7ef69eef36bb3325f47fd1f1 "
           "DRAFT2_QUANT=modelopt_fp4 DRAFT2_TOKENS=16")
LLM_START = {"llm27b": f"cd {HOME}/dgx-spark-qwen38 && {LLM_ENV} nohup ./run.sh > {HOME}/qwen38-run.log 2>&1 < /dev/null &"}
LLM_STOP = {"llm27b": "docker stop -t 20 qwen38-sglang-run"}

# ---------------------------------------------------------------- helpers
def sh(cmd, timeout=4):
    try:
        return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return default

def http_get(url, timeout=0.8):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except Exception:
        return None

def port_open(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.25):
            return True
    except OSError:
        return False

CORE_TYPE = {}
for d in sorted(os.listdir("/sys/devices/system/cpu")):
    if re.fullmatch(r"cpu\d+", d):
        mhz = int(read(f"/sys/devices/system/cpu/{d}/cpufreq/cpuinfo_max_freq", "0") or 0) // 1000
        CORE_TYPE[int(d[3:])] = ("X925", mhz) if mhz >= 3500 else ("A725", mhz)

STATIC_INFO = {
    "model": (read("/sys/class/dmi/id/product_name").strip() or "DGX Spark"),
    "vendor": read("/sys/class/dmi/id/sys_vendor").strip(),
    "hostname": socket.gethostname(),
    "cores": [{"id": i, "type": CORE_TYPE[i][0], "mhz": CORE_TYPE[i][1]} for i in sorted(CORE_TYPE)],
    "dgx_os": dict(re.findall(r'^(DGX_[A-Z_]+)="?([^"\n]*)"?', read("/etc/dgx-release"), re.M)).get("DGX_OTA_VERSION")
              or dict(re.findall(r'^(DGX_[A-Z_]+)="?([^"\n]*)"?', read("/etc/dgx-release"), re.M)).get("DGX_SWBUILD_VERSION"),
    "driver": sh(["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"]).strip(),
}

# ---------------------------------------------------------------- sampler
class Sampler:
    def __init__(self):
        self.lock = threading.Lock()
        self.hist = {k: deque(maxlen=HISTORY) for k in ("t", "gpu", "power", "temp", "mem", "cpu", "tok", "rx", "tx")}
        self.snap = {}
        self.events = deque(maxlen=40)
        self._cpu_prev = None
        self._io_prev = None
        self._slow_t = 0
        self._slow = {"procs": [], "services": {}, "ips": [], "units": {}}
        self.event("Mission Control started")

    def event(self, msg, level="info"):
        with self.lock:
            self.events.appendleft({"t": time.strftime("%H:%M:%S"), "msg": msg, "level": level})

    # --- fast metrics (every second)
    def gpu(self):
        out = sh(["nvidia-smi", "--query-gpu=utilization.gpu,power.draw,temperature.gpu,clocks.sm,clocks.max.sm,pstate",
                  "--format=csv,noheader,nounits"], timeout=3)
        try:
            u, p, t, c, cm, ps = [x.strip() for x in out.split(",")]
            f = lambda x: float(x) if re.fullmatch(r"[\d.]+", x) else None
            return {"util": f(u), "power": f(p), "temp": f(t), "clock": f(c), "clock_max": f(cm) or 3003, "pstate": ps}
        except Exception:
            return {"util": None, "power": None, "temp": None, "clock": None, "clock_max": 3003, "pstate": "?"}

    def cpu(self):
        rows = {}
        for line in read("/proc/stat").splitlines():
            m = re.match(r"cpu(\d*)\s+(.+)", line)
            if m:
                v = list(map(int, m.group(2).split()))
                idle = v[3] + (v[4] if len(v) > 4 else 0)
                rows[m.group(1) or "all"] = (sum(v), idle)
        prev, self._cpu_prev = self._cpu_prev, rows
        if not prev:
            return 0.0, [0.0] * len(CORE_TYPE)
        pct = lambda k: max(0.0, min(100.0, 100.0 * (1 - (rows[k][1] - prev[k][1]) / max(1, rows[k][0] - prev[k][0]))))
        return pct("all"), [round(pct(str(i)), 1) for i in sorted(CORE_TYPE) if str(i) in rows]

    def mem(self):
        m = {k: int(v.split()[0]) / 1048576 for k, v in re.findall(r"^(\w+):\s+(.+)$", read("/proc/meminfo"), re.M)}
        total, avail = m.get("MemTotal", 0), m.get("MemAvailable", 0)
        cache = m.get("Cached", 0) + m.get("Buffers", 0) + m.get("SReclaimable", 0)
        return {"total": total, "avail": avail, "used": total - avail, "cache": min(cache, avail),
                "swap_total": m.get("SwapTotal", 0), "swap_used": m.get("SwapTotal", 0) - m.get("SwapFree", 0)}

    def io(self):
        rx = tx = 0
        for line in read("/proc/net/dev").splitlines()[2:]:
            name, data = line.split(":", 1)
            name = name.strip()
            if re.match(r"(lo|docker|veth|br-|cni|flannel|tailscale)", name):
                continue
            v = data.split()
            rx += int(v[0]); tx += int(v[8])
        rd = wr = 0
        for line in read("/proc/diskstats").splitlines():
            v = line.split()
            if len(v) > 9 and re.fullmatch(r"nvme\d+n\d+", v[2]):
                rd += int(v[5]) * 512; wr += int(v[9]) * 512
        now = time.time()
        prev, self._io_prev = self._io_prev, (now, rx, tx, rd, wr)
        if not prev:
            return 0, 0, 0, 0
        dt = max(0.001, now - prev[0])
        return [(a - b) / dt for a, b in zip((rx, tx, rd, wr), prev[1:])]

    # --- slow metrics (every 2 s)
    def procs(self):
        out = sh(["nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits"])
        res = []
        ctrs = dict(l.split(" ", 1) for l in sh(["docker", "ps", "--no-trunc", "--format", "{{.ID}} {{.Names}}"]).splitlines() if " " in l)
        for line in out.strip().splitlines():
            try:
                pid, mb = [x.strip() for x in line.split(",")]
                cmd = read(f"/proc/{pid}/cmdline").replace("\0", " ")
            except Exception:
                continue
            cg = read(f"/proc/{pid}/cgroup")   # SGLang's worker processes only identify via their container
            ctr = next((n for i, n in ctrs.items() if i in cg), "")
            name = ("Qwen3.6-35B · SGLang" if ctr == "qwen38-35b" else "Qwen3.8-27B · SGLang" if "sglang" in cmd or ctr.startswith("qwen38-sglang") else "Ollama" if "ollama" in cmd
                    else "Face Swap" if "faceswap" in cmd else "FLUX engine" if "flux" in cmd.lower() else "Live VLM WebUI" if "live-vlm" in cmd
                    else "Sunshine" if "sunshine" in cmd else "Xorg" if "Xorg" in cmd else "GNOME Shell" if "gnome-shell" in cmd
                    else "Firefox" if "firefox" in cmd else os.path.basename(cmd.split(" ")[0]) or f"pid {pid}")
            if mb.isdigit():
                res.append({"pid": int(pid), "name": name, "gb": int(mb) / 1024})
        merged = {}
        for r in res:  # one entry per app (SGLang runs several GPU processes)
            m = merged.setdefault(r["name"], {"pid": r["pid"], "name": r["name"], "gb": 0.0})
            m["gb"] += r["gb"]
        return sorted(merged.values(), key=lambda r: -r["gb"])

    def services(self):
        units = [s["unit"] for s in SERVICES if s.get("unit") and s["kind"] == "user"]
        states = dict(zip(units, sh(["systemctl", "--user", "is-active", *units]).split()))
        res = {}
        for s in SERVICES:
            r = {"up": port_open(s["port"]), "unit_state": states.get(s.get("unit"), "")}
            if s["kind"] == "sys":
                r["unit_state"] = sh(["systemctl", "is-active", s["unit"]]).strip()
            if s["kind"] == "docker":
                r["unit_state"] = "active" if sh(["docker", "inspect", "-f", "{{.State.Status}}", s["containers"][0]]).strip() == "running" else ""
            if s["id"] == "flux":   # port 30000 is shared with the 27B; only count it when FLUX answers
                try:
                    r["up"] = r["ready"] = json.loads(http_get("http://127.0.0.1:30000/health", timeout=3) or "{}").get("backends", {}).get("flux_visual") == "ok"
                except Exception:
                    r["up"] = r["ready"] = False
            if s["id"] == "llm27b" and r["up"]:
                txt = http_get(f"http://127.0.0.1:{s['port']}/metrics") or ""
                g = lambda k: (lambda m: float(m.group(1)) if m else None)(re.search(rf"^sglang:{k}\{{[^}}]*\}} ([\d.eE+-]+)", txt, re.M))
                r.update(tok=g("gen_throughput"), running=g("num_running_reqs"), queued=g("num_queue_reqs"),
                         accept=g("spec_accept_length"), kv=g("token_usage"))
                r["ready"] = "sglang:" in txt  # /health needs the API key; metrics answering means the engine is serving
                r["up"] = r["ready"]            # port 30000 answering without SGLang metrics is FLUX, not the 27B
            elif s["id"] == "llm35b" and r["up"]:   # no /metrics on this engine; /health answers once the model is loaded
                r["up"] = r["ready"] = http_get(f"http://127.0.0.1:{s['port']}/health", timeout=1.5) is not None
            elif s["id"] == "webui" and r["up"]:    # nginx answers :80 at once; the app behind it takes ~12 s
                r["up"] = http_get("http://127.0.0.1:8080/health", timeout=1.5) is not None
            elif s["id"] == "ollama" and r["up"]:
                try:
                    r["models"] = [m["name"] for m in json.loads(http_get("http://127.0.0.1:11434/api/ps") or "{}").get("models", [])]
                except Exception:
                    r["models"] = []
            res[s["id"]] = r
        return res

    def ips(self):
        out = sh(["ip", "-4", "-o", "addr"])
        return [{"if": m[0], "ip": m[1]} for m in re.findall(r"^\d+:\s+(\S+)\s+inet\s+([\d.]+)", out, re.M)
                if not re.match(r"(lo|docker|veth|br-|cni|flannel)", m[0])]

    def tick(self):
        g = self.gpu()
        cpu_all, cores = self.cpu()
        mem = self.mem()
        rx, tx, rd, wr = self.io()
        if time.time() - self._slow_t > 2:
            self._slow_t = time.time()
            self._slow = {"procs": self.procs(), "services": self.services(),
                          "ips": self.ips() if not self._slow.get("ips") or int(time.time()) % 30 < 3 else self._slow["ips"]}
        temps = [int(read(f"/sys/class/thermal/{z}/temp", "0") or 0) / 1000 for z in os.listdir("/sys/class/thermal")
                 if z.startswith("thermal_zone")]
        st = os.statvfs("/")
        disk_total, disk_free = st.f_blocks * st.f_frsize / 1e9, st.f_bavail * st.f_frsize / 1e9
        load = read("/proc/loadavg").split()[:3]
        tok = (self._slow["services"].get("llm27b") or {}).get("tok")
        now = time.time()
        with self.lock:
            for k, v in (("t", now), ("gpu", g["util"]), ("power", g["power"]), ("temp", g["temp"]),
                         ("mem", round(mem["used"], 2)), ("cpu", round(cpu_all, 1)), ("tok", tok),
                         ("rx", round(rx)), ("tx", round(tx))):
                self.hist[k].append(v)
            self.snap = {
                "t": now, "gpu": g, "cpu": {"all": round(cpu_all, 1), "cores": cores, "load": load,
                                            "temp": max(temps) if temps else None},
                "mem": mem, "procs": self._slow["procs"], "services": self._slow["services"],
                "disk": {"total": disk_total, "free": disk_free, "read": rd, "write": wr},
                "net": {"rx": rx, "tx": tx, "ips": self._slow["ips"]},
                "uptime": float(read("/proc/uptime", "0 0").split()[0]),
            }

    def run(self):
        while True:
            t0 = time.time()
            try:
                self.tick()
            except Exception as e:
                self.event(f"sampler error: {e}", "bad")
            time.sleep(max(0.1, 1.0 - (time.time() - t0)))

S = Sampler()

# ---------------------------------------------------------------- actions
def action(sid, op):
    s = SVC.get(sid)
    if not s or op not in ("start", "stop", "restart"):
        return False, "unknown action"
    if s["kind"] == "user":
        subprocess.Popen(["systemctl", "--user", op, s["unit"]])
        return True, f"{s['name']}: {op} requested"
    if s["kind"] == "docker":
        if op == "start" and S.snap.get("mem", {}).get("avail", 0) < s["need_gb"]:
            return False, f"Only {S.snap['mem']['avail']:.0f} GB free; {s['name']} needs about {s['need_gb']} GB."
        subprocess.Popen(["docker", op, *s["containers"]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True, f"{s['name']}: {op} requested"
    if s["kind"] == "sys":   # allowed by /etc/sudoers.d/vision-arcade (start/stop only)
        if op == "restart":
            return False, "Use Stop, then Start"
        if op == "start" and S.snap.get("mem", {}).get("avail", 0) < s["need_gb"]:
            return False, f"Only {S.snap['mem']['avail']:.0f} GB free; {s['name']} needs about {s['need_gb']} GB."
        if op == "start" and sid == "flux" and S.snap.get("services", {}).get("llm27b", {}).get("up"):
            return False, "Stop the Qwen 27B first: it also uses port 30000"
        p = subprocess.Popen(["sudo", "-n", "/usr/bin/systemctl", op, s["unit"]], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            p.wait(3)   # a quick non-zero exit is a real refusal (sudo, unknown unit)
        except subprocess.TimeoutExpired:
            return True, f"{s['name']}: {op} in progress"
        return p.returncode == 0, f"{s['name']}: {op} {'requested' if p.returncode == 0 else 'refused: ' + p.stderr.read().strip()[:80]}"
    # LLM lanes: guard unified memory so the box never over-commits (freeze risk on GB10)
    if op == "stop":
        subprocess.Popen(LLM_STOP[sid], shell=True)
        return True, f"{s['name']} ({s['engine']}): stop requested"
    if S.snap.get("services", {}).get(sid, {}).get("up"):
        return False, f"{s['engine']} is already running"
    if sid == "llm27b" and S.snap.get("services", {}).get("flux", {}).get("up"):
        return False, "FLUX is using port 30000. Stop FLUX first."
    avail = S.snap.get("mem", {}).get("avail", 0)
    if avail < s["need_gb"]:
        return False, f"Only {avail:.0f} GB free; {s['engine']} needs about {s['need_gb']} GB. Stop something first."
    subprocess.Popen(LLM_START[sid], shell=True)
    return True, f"{s['name']} ({s['engine']}): starting, first boot takes a few minutes"

# ---------------------------------------------------------------- booth start-up sequence
# Order matters: the 35B's unit waits for the 27B on :30000 before it launches, and each step
# must clear its memory guard. Steps already running are skipped. Timeouts cover a cold start.
# Non-vision booth sequence: the 27B lane is systemd-managed (qwen38-sglang.service)
# and is expected already up; the 35B's own ExecStartPre gates on it. The sequence
# therefore starts the 35B (its unit waits for :30000 health) and the webui.
# Cost for llm35b is the ADDITIONAL GB on top of the already-running 27B.
# Timeouts cover a cold start.
BOOT_SEQ = [("llm35b", 600, 42), ("webui", 120, 2)]
MIN_HEADROOM = 15   # GB; below this a busy booth (35B batching, desktop, browser) can freeze the box
SEQ = {"running": False, "step": -1, "state": [], "msg": ""}

def boot_sequence():
    SEQ.update(running=True, step=-1, state=["wait"] * len(BOOT_SEQ), msg="")
    S.event("Booth start-up sequence started")
    for i, (sid, timeout, cost) in enumerate(BOOT_SEQ):
        SEQ["step"], name = i, SVC[sid]["name"]
        up = lambda: S.snap.get("services", {}).get(sid, {}).get("up")
        if up():
            SEQ["state"][i] = "skip"; continue
        avail = S.snap.get("mem", {}).get("avail", 0)
        if avail - cost < MIN_HEADROOM:
            SEQ["state"][i] = "fail"
            msg = f"Stopped before {name}: {avail:.0f} GB free, it needs ~{cost} GB and {MIN_HEADROOM} GB must stay spare"
            S.event(msg, "bad"); SEQ.update(running=False, msg=msg); return
        SEQ["state"][i] = "run"
        if S.snap.get("services", {}).get(sid, {}).get("unit_state") != "activating":
            ok, msg = action(sid, "start")
            S.event(msg, "info" if ok else "bad")
            if not ok:
                SEQ["state"][i] = "fail"; SEQ.update(running=False, msg=msg); return
        t0 = time.time()
        while not up():
            if time.time() - t0 > timeout:
                SEQ["state"][i] = "fail"; msg = f"{name} not ready after {timeout // 60} min"
                S.event(msg, "bad"); SEQ.update(running=False, msg=msg); return
            time.sleep(2)
        SEQ["state"][i] = "ok"
        S.event(f"{name} ready in {time.time() - t0:.0f} s")
    time.sleep(5)   # let the sampler pick up the new memory figure
    avail = S.snap["mem"]["avail"]
    low = avail < MIN_HEADROOM
    msg = f"Booth ready · {avail:.0f} GB headroom" + (" · LOW, stop something before visitors arrive" if low else "")
    S.event(msg, "bad" if low else "info"); SEQ.update(running=False, msg=msg)

# ---------------------------------------------------------------- remote control over Tailscale (PIN)
# Requests through Tailscale Serve carry X-Forwarded-For / Tailscale-User-Login. They are view-only until someone
# unlocks with the PIN; an unlock gives that browser a 30-minute token. The booth screen itself never needs the PIN.
def _tailscale_origin():
    if _TAILNET_ORIGIN_CFG:
        return _TAILNET_ORIGIN_CFG
    # derive live: this box's MagicDNS origin for the funnel port :8443
    import subprocess as _sp
    try:
        host = _sp.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5).stdout
        d = json.loads(host).get("Self", {}).get("DNSName", "").rstrip(".")
        if d:
            return f"https://{d}:8443"
    except Exception:
        pass
    return "https://localhost:8443"
TAILNET_ORIGIN = _tailscale_origin()
PIN_FILE = os.path.join(HERE, "remote_pin")   # mode 600, edit it to change the PIN (read on every unlock)
TOKEN_TTL, MAX_FAILS, LOCKOUT = 1800, 5, 300
TOKENS, FAILS = {}, {"n": 0, "until": 0.0}

def remote_pin():
    if not os.path.exists(PIN_FILE):
        with os.fdopen(os.open(PIN_FILE, os.O_WRONLY | os.O_CREAT, 0o600), "w") as f:
            f.write(f"{secrets.randbelow(10 ** 6):06d}" + chr(10))
    return open(PIN_FILE).read().strip()

# ---------------------------------------------------------------- http
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=STATIC, **kw)

    def log_message(self, *a):
        pass

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/stats":
            with S.lock:
                return self.send_json({"snap": S.snap, "events": list(S.events), "seq": SEQ})
        if self.path == "/api/history":
            with S.lock:
                return self.send_json({k: list(v) for k, v in S.hist.items()})
        if self.path == "/api/info":
            return self.send_json({"info": STATIC_INFO, "services": SERVICES, "cats": CATS, "boot_seq": [b[0] for b in BOOT_SEQ]})
        if self.path in ("/", "/index.html"):
            with S.lock:
                boot = {"info": STATIC_INFO, "services": SERVICES, "cats": CATS, "boot_seq": [b[0] for b in BOOT_SEQ], "seq": SEQ, "snap": S.snap, "events": list(S.events),
                        "history": {k: list(v) for k, v in S.hist.items()}}
            page = read(os.path.join(STATIC, "index.html")).replace(
                "<!--BOOT-->", "<script>window.__BOOT=" + json.dumps(boot).replace("</", r"</") + "</script>")
            body = page.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        return super().do_GET()

    def do_POST(self):
        # remote = anyone but the booth screen itself: via Tailscale Serve (forwarded headers) or straight from the LAN
        lan = self.client_address[0] not in ("127.0.0.1", "::1")
        remote = lan or bool(self.headers.get("X-Forwarded-For") or self.headers.get("Tailscale-User-Login"))
        who = self.headers.get("Tailscale-User-Login") or (f"LAN {self.client_address[0]}" if lan else "tailnet")
        origin = self.headers.get("Origin")
        same_origin = origin and urllib.parse.urlsplit(origin).netloc == self.headers.get("Host")   # page and request from the same address
        if origin not in (None, f"http://{HOST}:{PORT}", f"http://localhost:{PORT}", TAILNET_ORIGIN) and not same_origin:
            return self.send_json({"ok": False, "msg": "forbidden"}, 403)
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except Exception:
            req = {}
        now = time.time()
        if self.path == "/api/unlock":
            if not remote:
                return self.send_json({"ok": True})   # the booth screen is always unlocked
            if now < FAILS["until"]:
                return self.send_json({"ok": False, "msg": f"Too many wrong PINs. Try again in {int(FAILS['until'] - now) // 60 + 1} min."}, 429)
            if hmac.compare_digest(str(req.get("pin", "")).encode(), remote_pin().encode()):
                FAILS["n"] = 0
                token = secrets.token_urlsafe(24); TOKENS[token] = now + TOKEN_TTL
                S.event(f"Remote controls unlocked by {who}")
                return self.send_json({"ok": True, "token": token, "ttl": TOKEN_TTL})
            FAILS["n"] += 1
            if FAILS["n"] >= MAX_FAILS:
                FAILS.update(n=0, until=now + LOCKOUT)
                S.event(f"Remote unlock blocked for {LOCKOUT // 60} min after {MAX_FAILS} wrong PINs ({who})", "bad")
            return self.send_json({"ok": False, "msg": "Wrong PIN"}, 403)
        if self.path == "/api/lock":
            TOKENS.pop(self.headers.get("X-MC-Token", ""), None)
            return self.send_json({"ok": True})
        if self.path != "/api/action":
            return self.send_json({"ok": False}, 404)
        if remote:
            for t in [t for t, exp in TOKENS.items() if exp < now]:
                TOKENS.pop(t, None)
            if self.headers.get("X-MC-Token", "") not in TOKENS:
                return self.send_json({"ok": False, "locked": True, "msg": "Controls are locked. Unlock with the PIN."}, 403)
        try:
            if req.get("op") == "boot":
                ok, msg = (False, "Start-up sequence already running") if SEQ["running"] else (True, "Start-up sequence launched")
                if ok:
                    threading.Thread(target=boot_sequence, daemon=True).start()
            else:
                ok, msg = action(req.get("id"), req.get("op"))
        except Exception as e:
            ok, msg = False, str(e)
        S.event(msg + (f" (remote: {who})" if remote else ""), "info" if ok else "bad")
        return self.send_json({"ok": ok, "msg": msg})

if __name__ == "__main__":
    threading.Thread(target=S.run, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()   # box + LAN (hp-zgx.local:8765); Tailscale Serve proxies :8443 here
