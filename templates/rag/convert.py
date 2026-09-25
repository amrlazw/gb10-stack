#!/usr/bin/env python3
"""Desktop documents -> clean Markdown for RAG (tables and headings kept, one file per source document).
Config-driven: reads ~/.gb10-stack/rag/rag.json (convert.in_dir / convert.out_dir / convert.redact).
PDF: pymupdf4llm (layout-aware, tables as Markdown). PPTX: one '## Slide n: title' section per slide. MD: copied as-is.
Every output starts with a title header naming the source file, so citations and BM25 both see the document name.
Usage: python3 convert.py
Deps:  pip install --user pymupdf4llm python-pptx
"""
import json, os, re

import pymupdf4llm
from pptx import Presentation

CFG = os.path.expanduser(os.environ.get("GB10_RAG_CONFIG", "~/.gb10-stack/rag/rag.json"))
cfg = json.load(open(CFG))
conv = cfg.get("convert", {})
SRC = os.path.expanduser(conv.get("in_dir", "~/rag-corpus/raw"))
OUT = os.path.expanduser(conv.get("out_dir", "~/rag-corpus/md"))
REDACT_EXTRA = [re.escape(s) for s in conv.get("redact", [])]

def pptx_md(path):
    parts = []
    for i, slide in enumerate(Presentation(path).slides, 1):
        title = slide.shapes.title.text.strip() if slide.shapes.title and slide.shapes.title.text else f"Slide {i}"
        body = []
        for sh in slide.shapes:
            if sh == slide.shapes.title:
                continue
            if sh.has_text_frame:
                body += [("- " + p.text.strip()) for p in sh.text_frame.paragraphs if p.text.strip()]
            if getattr(sh, "has_table", False) and sh.has_table:
                rows = [[c.text.strip().replace("|", "/") for c in r.cells] for r in sh.table.rows]
                if rows:
                    body += ["", "| " + " | ".join(rows[0]) + " |", "|" + "---|" * len(rows[0])] + ["| " + " | ".join(r) + " |" for r in rows[1:]]
        notes = slide.notes_slide.notes_text_frame.text.strip() if slide.has_notes_slide else ""
        parts.append(f"## Slide {i}: {title}\n\n" + "\n".join(body) + (f"\n\nSpeaker notes: {notes}" if notes else ""))
    return "\n\n".join(parts)

IS_ROW = lambda s: s.startswith("|") and s.endswith("|")
IS_SEP = lambda s: bool(re.fullmatch(r"\|(\s*:?-{3,}:?\s*\|)+", s))
cols = lambda s: s.count("|") - 1

def tidy(md, redact):
    """Drop page furniture (repeated headers/footers, page numbers) and re-join tables split across pages."""
    fictional = "FICTIONAL TEST DATA" in md
    kept, seen = [], set()
    for ln in md.splitlines():
        s = ln.strip()
        if re.fullmatch(r"Page \d+ of \d+", s) or "FICTIONAL TEST DATA" in s or re.fullmatch(r"-{3,}", s):
            continue
        # a bare document number (e.g. MSN-PDS-TS200-R1) that is also in the header table = page footer
        if re.fullmatch(r"[A-Z]{2,6}(?:-[A-Z0-9]+){2,}", s) and re.search(r"\|\s*(\*\*)?" + re.escape(s) + r"(\*\*)?\s*\|", md):
            continue
        short_header = s and not IS_ROW(s) and not s.startswith(("-", "*   ", "#")) and len(s) < 90
        if short_header and s in seen:            # the same header/footer line again on the next page
            continue
        if s:
            seen.add(s)
        kept.append(ln.rstrip())
    out = []
    for ln in kept:                               # a table that restarts right after another = page-split table
        s = ln.strip()
        prev = next((x.strip() for x in reversed(out) if x.strip()), "")
        if IS_SEP(s) and len(out) >= 1 and IS_ROW(out[-1].strip()):
            before = next((x.strip() for x in reversed(out[:-1]) if x.strip()), "")
            gap = out[-2].strip() == "" if len(out) >= 2 else False
            if gap and IS_ROW(before) and cols(before) == cols(s):
                row = out.pop()
                while out and not out[-1].strip():
                    out.pop()
                out.append(row)
                continue
        out.append(ln)
    md = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()
    # never index secrets: anything a visitor could ask the chat for
    for pat in REDACT_EXTRA:
        md = re.sub(pat, "[redacted]", md, flags=re.I)
    md = re.sub(r"(?i)\b(password|passwd|pin|api[ _-]?key|token)(\s*[:=]\s*)(?!\[redacted\])[`*]*[^\s`*|]{3,}[`*]*", r"\1\2[redacted]", md)
    note = "> Note: the source marks this document as fictional test data (evaluation only).\n\n" if fictional else ""
    return note + md + "\n"

def contextualise(md, title):
    """'## Specifications Summary' -> '## Specifications Summary · <doc title> — <subject>'"""
    lines = md.splitlines()
    subject = ""
    for i, ln in enumerate(lines[:25]):
        if ln.startswith("# ") and i + 1 < len(lines):
            nxt = next((x.strip() for x in lines[i + 1:i + 4] if x.strip()), "")
            if nxt and not nxt.startswith(("|", "#", ">", "-", "*")) and len(nxt) < 120:
                subject = nxt
    ctx = title + (f" — {subject}" if subject else "")
    return "\n".join(re.sub(r"^(#{2,4}) (.+)$", lambda m: f"{m.group(1)} {m.group(2).strip()} · {ctx}", ln) for ln in lines)

os.makedirs(OUT, exist_ok=True)
n = 0
for name in sorted(os.listdir(SRC)):
    path, stem, ext = os.path.join(SRC, name), os.path.splitext(name)[0], os.path.splitext(name)[1].lower()
    if ext == ".pdf":
        body = pymupdf4llm.to_markdown(path, show_progress=False)
    elif ext == ".pptx":
        body = pptx_md(path)
    elif ext == ".md":
        body = open(path, encoding="utf-8").read()
    else:
        continue
    title = stem.replace("_", " ")
    out = f"# {title}\n\nSource file: {name}\n\n{contextualise(tidy(body, REDACT_EXTRA), title)}"
    with open(os.path.join(OUT, stem + ".md"), "w", encoding="utf-8") as f:
        f.write(out)
    n += 1
    print(f"{name[:52]:52} -> {len(out):7,d} chars, {out.count(chr(10) + '|'):4d} table rows, {len(re.findall(r'(?m)^#+ ', out)):3d} headings")
print(f"\n{ n } documents converted -> {OUT}")
