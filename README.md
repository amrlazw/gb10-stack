# gb10-stack

Turnkey, modular enterprise installer for NVIDIA GB10 (Grace Blackwell) AI Workstations. One command deploys the complete enterprise LLM & RAG stack: Flagship 35B NVFP4 MoE inference (SGLang official, dedicated 70 GB allocation), local RAG (Open WebUI + MiniLM-L12 embeddings + Chroma vector store), enterprise observability (Prometheus/node-exporter/DCGM/Loki/Grafana, ESM-gated), and DGX Mission Control featuring the Knowledge & RAG Studio.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/amrlazw/gb10-stack/main/get.sh | bash
```

Private repository usage:
```bash
GB10_TOKEN=<ghp_token> curl -fsSL https://raw.githubusercontent.com/amrlazw/gb10-stack/main/get.sh | bash
```

### Preflight Requirements

1. **Hardware Target**: NVIDIA GB10 Grace Blackwell (Ubuntu 24.04 LTS + `7.0.0-nvidia` kernel).
2. **Disk Storage**: Minimum 75 GB free on root filesystem (for 35B NVFP4 weights and container layers).
3. **Ubuntu Pro** (optional for ESM telemetry): `sudo pro attach <token>` (enables Prometheus, node-exporter, DCGM, Loki, Grafana).

### CLI Controls

```bash
bash install.sh --plan          # zero-write dry run (audits hardware & disk without mutating system)
bash install.sh                 # interactive turnkey deployment
bash install.sh --force         # idempotent rerun / recovery
bash install.sh --module rag    # targeted repair of an isolated module
bash scripts/verify.sh          # post-install verification ledger
```

## Desktop Launcher

When installation finishes, a desktop launcher is automatically created on the GB10 desktop:

* **Location**: `~/Desktop/DGX-Mission-Control.desktop`
* **Target URL**: `http://localhost:8765`
* **Capabilities**: Double-clicking launches the DGX Mission Control telemetry dashboard, GPU dials, and the Knowledge & RAG Studio directly in the default browser.

## Resource Headroom & Capacity Analysis (Fresh Box)

The stack is engineered around a **Flagship 35B NVFP4 MoE Solo Architecture** (`nvidia/Qwen3.6-35B-A3B-NVFP4`) to guarantee zero out-of-memory contention while leaving substantial unified memory headroom:

### 1. Unified Memory Headroom (121.6 GiB Physical Baseline)

| Component | Allocation / Footprint | Description |
|---|---|---|
| **Flagship 35B MoE (SGLang)** | `70.0 GiB` | `--memory 70g --mem-fraction-static 0.60` (weights ~21 GB, KV cache pool ~49 GB) |
| **Open WebUI + Nginx Proxy** | `~2.0 GiB` | Host-networked Docker container + SQLite + Chroma vector database |
| **DGX Mission Control** | `~0.05 GiB` | Native Python standard library daemon (`mission-control.service` on `:8765`) |
| **Ubuntu 24.04 OS & Desktop** | `~3.5 GiB` | Kernel 7.0, GNOME desktop environment, systemd user session |
| **Total Committed** | **`~75.5 GiB`** | **62% of physical unified memory** |
| **Available Free Headroom** | **`~46.1 GiB`** | **38% completely unallocated headroom** |

The remaining **~46.1 GiB** buffer provides abundant margin for:
* OS page caching and high-throughput NVLink-C2C data transfers.
* Dynamic multi-user concurrency bursts without triggering CUDA runtime out-of-memory errors.
* Local customer developer scripts and client notebook execution.

### 2. Disk Storage Headroom (Standard 1.0 TB NVMe)

| Item | Disk Footprint |
|---|---|
| **Base Ubuntu 24.04 OS** | ~12 GB |
| **Qwen3.6-35B-A3B NVFP4 Weights** | ~22 GB |
| **SGLang & Open WebUI Docker Layers** | ~35 GB |
| **Observability & Log History** | ~4 GB |
| **Total Stack Consumption** | **~73 GB** |
| **Remaining Free Disk** | **> 900 GB (90%+ free space)** |

## Packaged Modules

| Module | Core Functionality | Service / Target |
|---|---|---|
| `modules/llm-serving.sh` | Solo Flagship 35B NVFP4 MoE via official SGLang container | `qwen38-35b.service` (`:30000`) |
| `modules/rag.sh` | Open WebUI + Nginx trusted proxy + Chroma vector store | `open-webui` (`:80` -> `:8080`) |
| `modules/observability.sh` | ESM Prometheus, node-exporter, DCGM GPU telemetry, Grafana | `:9090`, `:9100`, `:9400`, `:3000` |
| `modules/mission-control.sh` | Live dashboard, RAG Studio, and Desktop shortcut creation | `mission-control.service` (`:8765`) |
| `scripts/gen-services.sh` | Dynamic service scanner generating live `mc.json` | Automatic |
| `scripts/verify.sh` | 14-point non-destructive verification ledger | Pre/post check |

## Security & State Management

* **Zero Credentials Stored in Git**: The installer dynamically generates random keys (`~/.config/qwen38/api-key`) and local hashes at deployment time.
* **Idempotent State Ledger**: Completed modules are recorded in `~/.gb10-stack/state`. Re-running `install.sh` safely skips already installed components.
* **Strict Non-Root Enforcement**: Piped execution via `sudo bash` is blocked at line 0 to prevent filesystem permission poisoning and orphaned configuration keys.
