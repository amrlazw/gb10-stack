# gb10-stack

Turnkey, modular enterprise installer for NVIDIA GB10 (Grace Blackwell) AI Workstations. One command deploys the complete enterprise LLM & RAG stack: Flagship 35B NVFP4 MoE inference (SGLang official, dedicated 70 GB allocation), local RAG (Open WebUI + MiniLM-L12 embeddings + Chroma vector store), enterprise observability (Prometheus/node-exporter/DCGM/Loki/Grafana, ESM-gated), and DGX Mission Control featuring the Knowledge & RAG Studio.

---

## Quick Start (3-Step Installation Guide)

Designed for both business operators and technical engineers. No prior Linux or Docker configuration required.

### Step 1: Open Your Terminal
On your NVIDIA GB10 desktop, open the **Terminal** application (or press `Ctrl` + `Alt` + `T` on your keyboard).

### Step 2: Copy & Run the Installer
Copy this command, paste it into your terminal, and press `Enter`:

```bash
curl -fsSL https://raw.githubusercontent.com/amrlazw/gb10-stack/main/get.sh | bash
```

*(For private enterprise deployments with access tokens: `GB10_TOKEN=<token> curl -fsSL https://raw.githubusercontent.com/amrlazw/gb10-stack/main/get.sh | bash`)*

#### Visual Installation Progress
You will see a live progress bar tracking each stage of the installation automatically:

```text
╭──────────────────────────────────────────────────────────╮
│  [████████████░░░░░░░░░░░░]  50%  Step 2/4: RAG & Open WebUI    │
╰──────────────────────────────────────────────────────────╯
```

---

### Step 3: What to Do When Installation Is Done

Once complete, your AI workstation is immediately ready to use:

1. **Launch DGX Mission Control (Desktop App)**:
   * Look at your computer desktop for the **`DGX Mission Control`** icon.
   * Double-click it to open your system dashboard in your web browser (`http://localhost:8765`).
   * Here you can monitor live Blackwell GPU temperatures, unified memory usage, and access the **Knowledge & RAG Studio**.

2. **Chat with Your Local 35B AI**:
   * Open your web browser (Chrome / Firefox) and go to:
     👉 **`http://localhost/`**
   * On your first visit, enter your name and password to create your local admin account.
   * Start chatting with the **Qwen 3.6-35B MoE** model running 100% privately on your box.

3. **Ingest & Search Your Own Documents**:
   * In DGX Mission Control, click the **`📚 Knowledge & RAG Studio`** tab.
   * Drag-and-drop your company PDFs, Word documents, or spreadsheets into the dropzone.
   * Click **`⚡ Ingest & Retrain RAG`** to automatically chunk, embed, and index them into your local vector database via `BAAI/bge-m3`.
   * Click **`🎯 Run Retrieval Accuracy Benchmark`** to audit retrieval accuracy and view live Q&A citations.

4. **Run the Health Check (any time, takes ~10 seconds)**:
   * The install command you pasted already saved the tools for you in a folder called `gb10-stack` — no extra download or "clone" needed.
   * Open a terminal (click the **Activities** menu, type `terminal`, press Enter) and run:
     ```bash
     bash ~/gb10-stack/scripts/verify.sh
     ```
   * You will see a list of 24 checks (AI engine, RAG, metrics, dashboard, SSH, disk).
   * Everything **PASS** = the box is healthy. Any **FAIL** = note the line; it tells you exactly what to re-check.
   * Prefer remote? `ssh youruser@<box-ip>` from your laptop, then the same command.

---

## Enterprise RAG & Hybrid Retrieval Architecture

The retrieval pipeline operates 100% on-device with zero external cloud API dependencies or data leakage:

* **Primary Embedding Model**: `BAAI/bge-m3`
  * **Vector Dimensions**: 1024-dimensional dense embeddings.
  * **M3 Multi-Functionality**: Multi-Lingual (100+ languages including English, Bahasa Malaysia, Chinese, Tamil), Multi-Granularity (up to 8,192 token input capacity), and Multi-Retrieval (dense semantic vectors + sparse lexical matching).
  * **Hardware Acceleration**: Local GPU/ARM batch vectorization.
* **Neural Reranking Model**: `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1`
  * Cross-encodes top-12 candidate chunks to produce the top-5 highest-relevance passages.
* **Hybrid Search Strategy**: BM25 lexical keyword matching + Dense vector similarity (0.5 weight balance).
* **Chunking Configuration**: 1,200-character chunks with 200-character sliding overlap.
* **Vector Database**: Embedded Chroma vector store with persistent SQLite metadata.

---

## Advanced CLI Controls (For System Administrators)

```bash
bash install.sh --plan          # zero-write dry run (audits hardware & disk without mutating system)
bash install.sh                 # interactive turnkey deployment
bash install.sh --force         # idempotent rerun / recovery
bash install.sh --module rag    # targeted repair of an isolated module
bash scripts/verify.sh          # 24-point post-install verification ledger
bash scripts/uninstall.sh --plan  # dry-run the full teardown (see "Uninstall" below)
```

## Remote Diagnostics (SSH)

The installer installs and enables **`openssh-server`** in preflight — before any heavy
work starts — so a headless box is always remotely reachable, even if a later step
stalls:

```bash
ssh <user>@<box-ip>             # from your laptop (port 22)
bash ~/gb10-stack/scripts/verify.sh   # full 24-point "did anything break" ledger
journalctl -u qwen38-35b.service -f   # tail the model engine's boot log live
```

The ledger's L0 section asserts SSH itself (`/usr/sbin/sshd` present + port 22 open),
so a broken remote path is the first thing you see.

## Recovery & Updates (Re-clone, Re-run)

The one-liner keeps the source at `~/gb10-stack` — you did **not** "just run a script",
you also got the tools. Everything below assumes that folder exists:

```bash
# update to the latest fixed installer, then re-run (idempotent — only fixes what's missing)
cd ~/gb10-stack && git pull
bash install.sh --force          # full idempotent re-run, every module repairs itself

# repair just one broken piece (fastest path)
bash install.sh --module mission-control   # dashboard only
bash install.sh --module llm-serving       # 35B engine + systemd unit only
bash install.sh --module rag               # Open WebUI + RAG only

# then prove it:
bash scripts/verify.sh
```

If `~/gb10-stack` is **missing** (deleted, moved box), re-clone and re-run:

```bash
git clone https://github.com/amrlazw/gb10-stack ~/gb10-stack
cd ~/gb10-stack && bash install.sh --force
```

`--force` is safe: it never re-downloads 22 GB of weights, never re-pulls images
that are already cached, and never wipes RAG data — it only repairs what's absent.

### Dashboard only (no repo needed)

If a box just needs the Mission Control dashboard and RAG Studio UI — without the
full stack or any git checkout:

```bash
curl -fsSL https://raw.githubusercontent.com/amrlazw/gb10-stack/main/mission-control.sh | bash
```

Fetches the dashboard from the GitHub CDN into `~/mission-control`, generates the
service list from what's actually on the box, starts `:8765` + desktop shortcut.
Re-running the same command **updates** the dashboard in place (PIN is preserved).

## Uninstall (Pull the Stack Out)

```bash
bash ~/gb10-stack/scripts/uninstall.sh --plan    # dry run: every step, zero writes
bash ~/gb10-stack/scripts/uninstall.sh           # safe removal (type UNINSTALL to confirm)
bash ~/gb10-stack/scripts/uninstall.sh --purge   # total teardown, including RAG data + 22 GB weights
```

| Tier | Removes | Keeps |
|---|---|---|
| **Default** | All systemd units (`qwen38-35b`, `open-webui*`, `mission-control`), all containers (incl. any 27B lane if present), `~/mission-control`, `~/.config/qwen38`, `~/.gb10-stack`, desktop shortcut | Open WebUI volume (**your RAG collections survive**), Docker images, 35B weight cache → re-install in minutes, not hours |
| **`--purge`** | Everything above **+** `open-webui` volume (all collections), all Docker images, 35B HF weights (~22 GB), observability apt packages | OS, desktop environment, SSH |

Safety properties:
- **Dry-run first, always**: `--plan` lists every mutation without executing.
- **Confirmation gate**: live runs require typing `UNINSTALL` (or `--yes` for automation).
- **Idempotent**: every step tolerates already-removed components — re-running on a clean box is a no-op.
- **No data loss by default**: RAG collections, model weights and images are preserved so a re-install reuses everything already downloaded.

## Resource Headroom & Capacity Analysis (Fresh Box)

The stack is engineered around a **Flagship 35B NVFP4 MoE Solo Architecture** (`nvidia/Qwen3.6-35B-A3B-NVFP4`) to guarantee zero out-of-memory contention while leaving substantial unified memory headroom:

### 1. Unified Memory Headroom (121.6 GiB Physical Baseline)

| Component | Allocation / Footprint | Description |
|---|---|---|
| **Flagship 35B MoE (SGLang)** | `70.0 GiB` | `--memory 70g --mem-fraction-static 0.60` (weights ~21 GB, KV cache pool ~49 GB) |
| **Open WebUI + Nginx Proxy** | `~2.5 GiB` | Host-networked Docker container; idle ~35 MiB, peaks at ~2.5 GiB when `BAAI/bge-m3` (~2.2 GB) + `mmarco` reranker (~470 MB) are loaded for embedding/rerank bursts |
| **DGX Mission Control** | `~0.05 GiB` | Native Python standard library daemon (`mission-control.service` on `:8765`) |
| **Ubuntu 24.04 OS & Desktop** | `~3.5 GiB` | Kernel 7.0, GNOME desktop environment, systemd user session |
| **Total Committed (Peak)** | **`~76.0 GiB`** | **62% of physical unified memory** |
| **Available Free Headroom** | **`~45.6 GiB`** | **~37% completely unallocated headroom** |

The remaining **~45.6 GiB** buffer provides abundant margin for:
* OS page caching and high-throughput NVLink-C2C data transfers.
* Dynamic multi-user concurrency bursts without triggering CUDA runtime out-of-memory errors.
* Local customer developer scripts and client notebook execution.

### 2. Disk Storage Headroom (Standard 1.0 TB NVMe)

| Item | Disk Footprint |
|---|---|
| **Base Ubuntu 24.04 OS** | ~12 GB |
| **Qwen3.6-35B-A3B NVFP4 Weights** | ~22 GB |
| **SGLang & Open WebUI Docker Images** | ~67 GB (measured `docker system df`: images 66.7 GB, includes full CUDA/cuDNN/NCCL runtime) |
| **RAG Vector Volume (bge-m3 + reranker cache)** | ~5 GB (`open-webui` named volume: bge-m3 2.2 GB, mmarco reranker 470 MB) |
| **Observability & Log History** | ~4 GB |
| **Total Stack Consumption** | **~110 GB** |
| **Remaining Free Disk** | **> 890 GB (89%+ free space)** |

## Packaged Modules

| Module | Core Functionality | Service / Target |
|---|---|---|
| `modules/llm-serving.sh` | Solo Flagship 35B NVFP4 MoE via official SGLang container | `qwen38-35b.service` (`:30000`) |
| `modules/rag.sh` | Open WebUI + Nginx proxy + Chroma vector store (`BAAI/bge-m3` + `mmarco-mMiniLMv2` reranker) | `open-webui` (`:80` -> `:8080`) |
| `modules/observability.sh` | ESM Prometheus, node-exporter, DCGM GPU telemetry, Grafana | `:9090`, `:9100`, `:9400`, `:3000` |
| `modules/mission-control.sh` | Live dashboard, RAG Studio, and Desktop shortcut creation | `mission-control.service` (`:8765`) |
| `scripts/gen-services.sh` | Dynamic service scanner generating live `mc.json` | Automatic |
| `scripts/verify.sh` | 24-point non-destructive verification ledger (incl. SSH reachability) | Pre/post check |

## Security & State Management

* **Zero Credentials Stored in Git**: The installer dynamically generates random keys (`~/.config/qwen38/api-key`) and local hashes at deployment time.
* **Idempotent State Ledger**: Completed modules are recorded in `~/.gb10-stack/state`. Re-running `install.sh` safely skips already installed components.
* **Strict Non-Root Enforcement**: Piped execution via `sudo bash` is blocked at line 0 to prevent filesystem permission poisoning and orphaned configuration keys.
