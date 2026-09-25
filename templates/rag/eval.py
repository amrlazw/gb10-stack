#!/usr/bin/env python3
"""RAG evaluation harness for an Open WebUI instance.
Config-driven: reads ~/.gb10-stack/rag/rag.json
  base      Open WebUI URL (eval goes through the nginx proxy by default: http://127.0.0.1)
  eval.qa_file  JSON: { "model": "qwen3.6-35b", "qa": [ {id, question, source (regex or null), want (list of alt-groups, or "REFUSE")} ] }
Retrieval: is the expected source file among the chunks Open WebUI retrieves (its own /retrieval endpoint, current settings)?
Answer: does a real chat answer contain the expected fact(s), or refuse when the documents don't say?
Usage:
  python3 eval.py <label> [collection_id ...]      # run the QA set, write eval-<label>.json
  python3 eval.py --rescore <label>                # re-check saved answers after changing rules (no model calls)
"""
import json, os, re, sys, time, urllib.request

CFG = os.path.expanduser(os.environ.get("GB10_RAG_CONFIG", "~/.gb10-stack/rag/rag.json"))
cfg = json.load(open(CFG))
B = cfg.get("base", "http://127.0.0.1")
EVAL = cfg.get("eval", {})
QA_FILE = os.path.expanduser(EVAL.get("qa_file", "~/rag-corpus/eval-qa.json"))
OUT_DIR = os.path.dirname(CFG)   # store eval-<label>.json next to the config

def load_qa():
    d = json.load(open(QA_FILE))
    Q = []
    for q in d["qa"]:
        Q.append((q["id"], q["question"], q.get("source"), q.get("want", "REFUSE")))
    return d.get("model", "local-model"), Q

REFUSAL = re.compile(r"not (?:mentioned|stated|specified|provided|found|included|available|in the)|no (?:information|mention|data|details)"
                     r"|(?:do|does) not (?:have|say|mention|specify|include|provide|contain)|doesn't (?:say|mention|specify|contain)"
                     r"|(?:do|does)(?: not|n't) (?:cover|state|identify)|couldn't find|could not find|cannot (?:find|answer|provide|be determined)|unable to (?:find|answer)|not able to find"
                     r"|tidak (?:dinyatakan|disebut|terdapat|ditemui|mempunyai maklumat)", re.I)

def rescore(label):
    d = json.load(open(os.path.join(OUT_DIR, f"eval-{label}.json")))
    _, Q = load_qa()
    want = {q[0]: q[3] for q in Q}
    for r in d["rows"]:
        w = want.get(r["id"])
        if w == "REFUSE":
            r["ok"] = bool(REFUSAL.search(r["answer"]))
        elif w:
            r["ok"] = all(any(a.lower() in r["answer"].lower() for a in g) for g in w)
    d["summary"]["answers_pass"] = f"{sum(r['ok'] for r in d['rows'])}/{len(d['rows'])}"
    json.dump(d, open(os.path.join(OUT_DIR, f"eval-{label}.json"), "w"), indent=1, ensure_ascii=False)
    print("RESCORED", json.dumps(d["summary"]), "| failing:", " ".join(r["id"] for r in d["rows"] if not r["ok"]))

def post(path, body, timeout=180):
    req = urllib.request.Request(B + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def retrieved_names(query, collections, k):
    r = post("/api/v1/retrieval/query/collection", {"collection_names": collections, "query": query, "k": k})
    names = [(m or {}).get("name") or (m or {}).get("source") or "" for m in (r.get("metadatas") or [[]])[0]]
    return names

def main():
    label, cols = sys.argv[1], sys.argv[3:]
    model, Q = load_qa()
    if not Q:
        sys.exit(f"no QA entries in {QA_FILE}")
    rows, t_all = [], time.time()
    for qid, q, src, want in Q:
        t0 = time.time()
        try:
            names = retrieved_names(q, cols, 5) if cols else []
        except Exception as e:
            names = [f"ERR {type(e).__name__}"]
        rt = time.time() - t0
        hit = None if src is None else any(re.search(src, n or "", re.I) for n in names)
        t1 = time.time()
        try:
            r = post("/api/chat/completions", {"model": model, "stream": False, "chat_id": f"local:rag-eval-{label}",
                                               "chat_template_kwargs": {"enable_thinking": False},
                                               "messages": [{"role": "user", "content": q}],
                                               "files": [{"type": "collection", "id": c} for c in cols]})
            ans = r["choices"][0]["message"]["content"]
        except Exception as e:
            ans = f"ERROR {type(e).__name__}: {e}"
        at = time.time() - t1
        if want == "REFUSE":
            ok = bool(REFUSAL.search(ans))
        else:
            low = ans.lower()
            ok = all(any(a.lower() in low for a in grp) for grp in want)
        rows.append({"id": qid, "hit": hit, "ok": ok, "rt": round(rt, 2), "at": round(at, 1), "top": names[:3], "answer": ans[:400]})
        print(f"{qid:3} retrieval {'-' if hit is None else ('HIT ' if hit else 'MISS')}  answer {'PASS' if ok else 'FAIL'}  "
              f"({rt:4.2f}s search, {at:4.1f}s answer)  top: {', '.join((n or '?')[:28] for n in names[:3])}", flush=True)
    hits = [r["hit"] for r in rows if r["hit"] is not None]
    summary = {"label": label, "retrieval_hit_at_5": f"{sum(hits)}/{len(hits)}" if hits else "n/a",
               "answers_pass": f"{sum(r['ok'] for r in rows)}/{len(rows)}",
               "avg_search_s": round(sum(r["rt"] for r in rows) / len(rows), 2),
               "avg_answer_s": round(sum(r["at"] for r in rows) / len(rows), 1)}
    print("SUMMARY", json.dumps(summary))
    json.dump({"summary": summary, "rows": rows},
              open(os.path.join(OUT_DIR, f"eval-{label}.json"), "w"), indent=1, ensure_ascii=False)

if __name__ == "__main__":
    rescore(sys.argv[2]) if sys.argv[1] == "--rescore" else main()
