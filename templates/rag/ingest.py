#!/usr/bin/env python3
"""Ingest a markdown corpus into Open WebUI as named knowledge collections.
Config-driven: reads ~/.gb10-stack/rag/rag.json
  base             Open WebUI URL (http://localhost:8080)
  ingest_account   { email, password } — a local Open WebUI account (login form enabled, or provisioned)
  corpus_root      dir containing one subdir per collection key
  collections      { "01_key": "Display Name", ... }
Idempotent: skips files already uploaded; reuses collections with the same name.
Usage: python3 ingest.py
"""
import json, os, sys, time, uuid, urllib.request, urllib.error

CFG = os.path.expanduser(os.environ.get("GB10_RAG_CONFIG", "~/.gb10-stack/rag/rag.json"))
cfg = json.load(open(CFG))
BASE = cfg.get("base", "http://localhost:8080")
EMAIL = cfg["ingest_account"]["email"]
PASSWORD = cfg["ingest_account"]["password"]
CORPUS = os.path.expanduser(cfg.get("corpus_root", "~/rag-corpus"))
COLLECTIONS = cfg.get("collections", {})
if not EMAIL or not PASSWORD:
    sys.exit("ERROR: rag.json -> ingest_account.email / password not set")
if not COLLECTIONS:
    sys.exit("ERROR: rag.json -> collections is empty")

def call(method, path, token=None, body=None, raw_body=None, ctype=None, timeout=120):
    headers = {}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if raw_body is not None:
        data = raw_body
        headers["Content-Type"] = ctype
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:300]}
    except Exception as e:
        return -1, {"err": str(e)}

def upload_file(token, fpath):
    boundary = "----h" + uuid.uuid4().hex
    fname = os.path.basename(fpath)
    with open(fpath, "rb") as fh:
        content = fh.read()
    body = b""
    body += f"--{boundary}\r\n".encode()
    body += f'Content-Disposition: form-data; name="file"; filename="{fname}"\r\n'.encode()
    body += b"Content-Type: text/markdown\r\n\r\n"
    body += content
    body += f"\r\n--{boundary}--\r\n".encode()
    code, j = call("POST", "/api/v1/files/", token=token, raw_body=body,
                   ctype=f"multipart/form-data; boundary={boundary}")
    return code, j

def main():
    code, j = call("POST", "/api/v1/auths/signin", body={"email": EMAIL, "password": PASSWORD})
    if code != 200:
        print("SIGNIN FAILED", code, j); sys.exit(1)
    token = j["token"]
    print("signed in as", j.get("name"))

    code, existing = call("GET", "/api/v1/knowledge/", token=token)
    existing = existing.get("items", []) if isinstance(existing, dict) else existing
    by_name = {k.get("name"): k.get("id") for k in existing} if isinstance(existing, list) else {}
    code, existing_files = call("GET", "/api/v1/files/", token=token)
    existing_files = existing_files.get("items", []) if isinstance(existing_files, dict) else existing_files
    have = {f.get("filename"): f.get("id") for f in existing_files} if isinstance(existing_files, list) else {}
    print(f"existing: {len(by_name)} collections, {len(have)} files")

    summary = []
    for cat, cname in COLLECTIONS.items():
        cdir = os.path.join(CORPUS, cat)
        if not os.path.isdir(cdir):
            print(f"[skip] {cname}: corpus dir not found {cdir}")
            continue
        files = sorted(f for f in os.listdir(cdir) if f.endswith(".md"))
        if cname in by_name:
            kid = by_name[cname]
            print(f"[reuse] {cname} -> {kid}")
        else:
            code, j = call("POST", "/api/v1/knowledge/create", token=token,
                           body={"name": cname, "description":
                                 f"Library: {len(files)} reference documents (category {cat})."})
            if code not in (200, 201):
                print(f"KNOWLEDGE CREATE FAIL {cname}: {code} {j}"); continue
            kid = j.get("id")
            print(f"[new] {cname} -> {kid}")
        n_new = 0
        for f in files:
            if f in have:
                continue  # already uploaded server-side
            code, j = upload_file(token, os.path.join(cdir, f))
            if code not in (200, 201):
                print(f"  UPLOAD FAIL {f}: {code} {j}"); continue
            have[f] = j.get("id"); n_new += 1
            time.sleep(0.3)
        attached = 0
        for f in files:
            fid = have.get(f)
            if not fid:
                continue
            code, j = call("POST", f"/api/v1/knowledge/{kid}/file/add",
                           body={"file_id": fid}, token=token)
            if code == 200:
                attached += 1
            else:
                print(f"  ATTACH FAIL {f}: {code} {j}")
            time.sleep(0.2)
        summary.append((cname, len(files), n_new, attached))
        print(f"  -> {cname}: {len(files)} files, {n_new} new uploads, {attached} attached")

    print("\n=== SUMMARY ===")
    for row in summary:
        print(row)
    code, j = call("GET", "/api/v1/knowledge/", token=token)
    if code == 200:
        print("\nknowledge now on server:")
        for k in j:
            print(f"  {k.get('name')}: id={k.get('id')} files={k.get('file_count')}")

if __name__ == "__main__":
    main()
