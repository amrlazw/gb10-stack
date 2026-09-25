# KNOWN-GAPS — gb10-stack (option-1)

Honest list, ordered by buyer-impact.

1. **No end-to-end install run on a fresh GB10 yet.** Everything tested was:
   `bash -n`/`py_compile` (local), `--plan` full run (local, zero-write),
   `gen-services.sh` + `verify.sh` + server.py unit test (read-only, on the
   live reference box). The first real buyer-grade run must happen on a spare
   or the buyer's box under supervision. Expected duration ~90 min, dominated
   by the 35B image pull (~38 GB).

2. **`REPO_URL` is a placeholder** in `get.sh` (GitHub private repo + raw
   proxy — decided, not yet created). `get.sh` errors loudly with the exact
   command to run once set; nothing else in the tree depends on it.

3. **Booth auto-login is opt-in and off by default** (`BOOTH_EMAIL=`/
   `BOOTH_PASSWORD=`). The reference box runs an auto-login session for
   kiosk-style demos; shipping it on by default would be a security mistake.
   Buyer must set it explicitly — documented in rag.sh.

4. **First-run account creation is manual.** Open WebUI's first user wins;
   the installer creates the container but not the account (by design —
   the buyer owns the password). README covers it.

5. **Flash 176B lane is a gated stub** (`GB_FLASH=1`). The 27B/35B lanes are
   full; the 176B lane reuses the upstream run.sh with `GB_FLASH=1` but the
   +225 GB disk math and the single-model memory swap were not exercised on
   hardware.

6. **`verify.sh` LLM rows assume default ports** (30000/30001/30002/30090).
   Non-default ports (upstream env overrides) make those rows false-FAIL.
   Fix = read ports from `~/.config/qwen38` at verify time; not done.

7. **Observability assumes Ubuntu Pro is attached first.** Correct behaviour
   is an ESM gate with a skip, but there is no *installer* path that attaches
   Pro itself (the buyer supplies the token; `sudo pro attach` is documented
   in README step 1, not automated — token entry is a human step).

8. **Sunshine delegated, not verified end-to-end.** The upstream one-liner is
   called; its exact interactive prompts (port, user) are not pre-answered
   here, so a fully unattended install will pause at Sunshine. Documented as
   the one interactive point in remote.sh.

9. **opencode wiring** (reference box has opencode → SGLang configured) is
   out of option-1 scope — it's a user-tool preference, not stack. Flagged in
   the plan PDF's open decisions, still open.

10. **filter-chain.service, gcr-ssh-agent.service, :11000** on the reference
    box are unidentified (open decision #7 in the plan PDF). Excluded from
    the package until triaged; if they're buyer-relevant they belong in a
    future module, not option-1.
