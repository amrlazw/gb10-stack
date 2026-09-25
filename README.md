# gb10-stack

Turnkey, modular installer for NVIDIA GB10 (DGX Spark) — option 1 of a
family. One command rebuilds the full non-vision stack: LLM serving
(27B + 35B dual-live), RAG (Open WebUI + config-driven rag-prep tools),
observability (Prometheus/node-exporter/DCGM/Loki/Grafana, ESM-gated),
DGX Mission Control (generated, not hardcoded), and remote access
(Tailscale funnels + Sunshine).

## Install

```bash
curl -fsSL <REPO_URL>/get.sh | bash
```

Private repo: `GB10_TOKEN=<ghp_…> curl -fsSL <REPO_URL>/get.sh | bash`
(fine-grained token, Contents:Read on this repo).

Before running:

1. **Buyer supplies an Ubuntu Pro token** → `sudo pro attach <token>`
   (ESM packages: prometheus, node-exporter, loki, alloy, grafana).
2. Box is GB10 (24.04 + `7.0.0-nvidia` kernel), Tailscale tailnet member.
3. ~135 GB free (176B Flash lane is opt-in: `GB_FLASH=1`, +225 GB).

```bash
bash install.sh --plan     # zero-write dry run — safe on any box
bash install.sh            # execute
bash install.sh --force    # rerun (idempotent, resumable)
bash install.sh --module rag        # repair a single module
bash scripts/verify.sh             # done-ledger; 0 fails = done
```

## Modularity

Options live in `config/options.yaml`. A future option is a new block:

```yaml
  - id: option-2-llm-only
    min_free_gb: 65
    modules:
      - llm-serving
```

No code change. Modules are the atomic unit; every mutation routes through
`scripts/common.sh` helpers, so `--plan` is a genuine zero-write dry run
(verified against the live reference box).

## What ships

| Path | Purpose |
|---|---|
| `get.sh` | one-liner bootstrap (clone + run install.sh) |
| `install.sh` | orchestrator: preflight, manifest, module runner, state |
| `config/options.yaml` | option manifest (option-1 = full non-vision) |
| `modules/llm-serving.sh` | 27B delegated to upstream dgx-spark-qwen38; 35B lane templatized |
| `modules/rag.sh` | Open WebUI + nginx proxy (host network) + config-driven rag tools |
| `modules/observability.sh` | ESM-gated: prometheus (3 jobs), node-exporter + 5 collectors, DCGM, Loki/Grafana |
| `modules/mission-control.sh` | server.py + static/, `mc.json` generated from live detection, user unit |
| `modules/remote.sh` | tailscale up, serve :10000→:80, :8443→:8765; Sunshine delegated |
| `scripts/gen-services.sh` | mc.json generator (read-only; excludes vision by construction) |
| `scripts/verify.sh` | read-only done-ledger |
| `templates/rag/{convert,ingest,eval}.py` | the 4-method RAG pipeline, config-driven (no client content) |
| `templates/mission-control/` | server.py (patched: config-driven SERVICES + live tailnet origin) |

## Delegation (upstream stays canonical)

- **27B lane + keepalive + cockpit**: `hasso5703/dgx-spark-qwen38` (MIT) via its own one-liner.
- **Sunshine**: `seanGSISG/sunshine-setup` upstream one-liner.

## State & repair

State lives in `~/.gb10-stack/state` (one line per completed module).
Every step is idempotent; `--force` reruns; `--module <name>` repairs a
single layer without touching the rest.

## Secrets

Nothing sensitive ships. At install the installer generates: API key
(`~/.config/qwen38/api-key`), mission-control login (HMAC, stored hashed),
remote PIN (6 digits, mode 600). The buyer creates their own Open WebUI
account after first login (first user wins).
