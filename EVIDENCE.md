# EVIDENCE — gb10-stack

Real output only. No fabricated results.

## 1. Syntax: every shipped .sh passes `bash -n`

```
OK  get.sh
OK  install.sh
OK  scripts/common.sh
OK  scripts/gen-services.sh
OK  scripts/verify.sh
OK  modules/observability.sh
OK  modules/mission-control.sh
OK  modules/remote.sh
OK  modules/llm-serving.sh
OK  modules/rag.sh
```

## 2. Syntax: every shipped .py passes `python -m py_compile`

```
OK  templates/rag/convert.py
OK  templates/rag/eval.py
OK  templates/rag/ingest.py
OK  templates/mission-control/server.py
```

## 3. `install.sh --plan` (zero-write dry run) — full 5-module run

Ran locally (Node 2, Windows/git-bash) against the real repo tree. Exit 0.
Every mutation printed as `[plan] (would) …`; **zero bytes written** (no
state file, no /etc, no docker, no tailscale — plan mode routes all
mutations through no-op helpers in `scripts/common.sh`).

Key lines:
```
 gb10-stack  |  option: default
 MODE: PLAN (zero writes — nothing below is executed)
 modules: llm-serving rag observability mission-control remote
 [ ok ] disk: 363 GB free (need 135)
 [plan] (would) curl -fsSL https://raw.githubusercontent.com/hasso5703/dgx-spark-qwen38/main/get.sh | bash -s --  (PORT=30000 PROXY_PORT=30001)
 [plan] (would) write: …/launch-35b.sh (3 lines)
 [plan] (would) sudo write: /etc/systemd/system/qwen38-35b.service (25 lines)
 [plan] (would) docker run --name open-webui --network host -v open-webui:/app/backend/data --memory 12g ghcr.io/open-webui/open-webui:main
 [plan] (would) write /etc/prometheus/prometheus.yml (3 jobs)
 [ ok ] observability stack: prometheus :9090, node :9100, dcgm :9400, grafana :3000, loki :3100
 [plan] (would) generate …/mission-control/mc.json from detected components (vision excluded by construction)
 [plan] (would) tailscale up (if not already) + funnels :10000 -> :80, :8443 -> :8765 (tailnet-only)
 PLAN complete: llm-serving,rag,observability,mission-control,remote (zero writes)
```

## 4. `scripts/gen-services.sh` — run READ-ONLY on the live reference box (hp-zgx)

Proof the SERVICES.json generator works against a real GB10, excluding vision:
```
mc.json: 4 services -> /tmp/gbstack-test/mc.json
```
Detected (4, all non-vision): `llm27b`(:30000), `llm35b`(:30002), `webui`(80,
both containers), `sunshine`(:47990).
**Vision excluded (0):** arcade, VLM, faceswap, moondream/ollama, FLUX — none
present, so none emitted (exclusion by construction, not a filter list).
Per-box tailnet origin derived live (not hardcoded):
`https://hp-zgx.tail00b4b6.ts.net:8443`.
Test dir removed after run (`rm -rf /tmp/gbstack-test` → cleaned).

## 5. `scripts/verify.sh` — done-ledger run on the live reference box (hp-zgx)

Read-only. Real current state (box was mid-LLM-restart at run time):
```
RESULT: 17 pass, 9 fail, 1 skip
```
PASS (17): docker daemon, nvidia driver, keepalive :30001, api-key file,
open-webui + proxy containers, webui :80 + :3000, MC unit active, MC :8765,
mc.json no-vision, remote PIN 600, tailscale, serve :10000, serve :8443,
sunshine, no .gbstack.bak in /etc.
FAIL (9) are **true current-state**, not tooling bugs — confirmed by direct
probe: LLM containers "none running", units "activating", cockpit ":30090 not
listening". RAG-tools/config + state-file FAILs because this is a fresh test
tree, not an installed box.
SKIP (1): observability (ESM not attached — correct gate behaviour).
Test dir removed after run.

## 6. Reference-box facts used to templatize (all read-only, ssh hp-zgx)

- 35B unit `qwen38-35b.service` + `launch-35b.sh` (pinned digest, 60g cap,
  health-ordered 27B-first start) — captured verbatim.
- Open WebUI: `ghcr.io/open-webui/open-webui:main`, `NetworkMode: host`,
  named volume `open-webui`, 12g memory, full env (embedding, telemetry off).
- nginx proxy: separate `nginx:alpine` container, `NetworkMode: host`, conf
  mounted ro.
- Prometheus: `/etc/prometheus/prometheus.yml`, exactly 3 jobs
  (node :9100, dcgm :9400, engine :30000/metrics); no conf.d.
- node-exporter collectors: apt, ipmitool-sensor, mellanox-hca-temp, nvme, smartmon.
- DCGM: `nvcr.io/nvidia/k8s/dcgm-exporter` container → :9400.
- Mission Control: **user** unit; `remote_pin` mode 600; funnel :8443→:8765,
  :10000→:80 (ref-verified `tailscale serve status`).
- Upstream `hasso5703/dgx-spark-qwen38` = **MIT**; env surface
  (PORT, PROXY_PORT, COCKPIT_PORT, HF_CACHE, api-key path) confirmed from its install.sh.

## 7. `server.py` patch verification — unit-tested on Linux (hp-zgx, temp dir, removed after)

Two import scenarios + service lookup:
```
fallback ids: ['llm27b', 'llm35b', 'webui'] | vision: NONE | BOOT_SEQ ids ok: True
mc.json ids: ['llm27b', 'webui'] | origin: https://freshbox.ts.net:8443
svc lookup webui ok: docker
RESULT: PASS
```
- No mc.json → hardcoded fallback, vision-free, `BOOT_SEQ` valid against `SVC`.
- mc.json next to server.py (installed layout) → file wins, per-box tailnet origin.
- This test caught and fixed a real crash: the verbatim `BOOT_SEQ` referenced
  vision ids (`ollama`, `flux`, `faceswap`, `arcade`) that don't exist in the
  non-vision `SVC` → `KeyError` in `boot_sequence()`. Fixed to the 2-step
  non-vision sequence; the 90 s moondream wait was removed with it.

## 8. What was NOT run (honest gaps)

No live GB10 was mutated by this build. `install.sh` (non-plan) has NOT been
executed end-to-end on a box — only `--plan` (local) + the two read-only
scripts (on hp-zgx) + the server.py unit test (on hp-zgx, temp dir). A real
install run on a spare/fresh GB10 is the next gate before shipping to a buyer.
