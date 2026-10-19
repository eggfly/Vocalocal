"""把真实录音的各方案结果合成一个本地对比页 bench/real/index.html。

在页面里逐条点选正确结果（或手动改成正确文字），页面实时计算每个方案的字错率（CER）和全对率。
标注保存在浏览器 localStorage，可导出为 labels.json；把 labels.json 放进 bench/real/ 后重新运行本脚本，
标注会内嵌进页面。

用法: python3 make_report.py && open real/index.html
"""
import json
import os
import wave
from pathlib import Path

REAL = Path(__file__).resolve().parent / "real"
APP = Path(os.path.expanduser("~/Library/Application Support/Vocalocal"))

ENGINES = [
    # (结果里的引擎名, 页面显示名, 说明)
    ("history", "当时实际输出", "你用的时候实际打出的文字（不同时期引擎不同，带屏幕上下文）"),
    ("apple-old/plain", "苹果旧版", "SFSpeechRecognizer"),
    ("apple-new/plain", "苹果新版", "SpeechAnalyzer"),
    ("qwen3-asr", "Qwen3-ASR", "不带词汇表"),
    ("qwen3-asr+词汇表", "Qwen3-ASR+词汇表", "热词 = 设置里的词汇表"),
    ("+Qwen3-Omni纠错", "+Qwen3-Omni 纠错", "当前方案，约 21 GB"),
    ("+MiniCPM-o纠错", "+MiniCPM-o 纠错", "小内存候选，约 6 GB"),
    ("小内存方案", "小内存方案（现在用的）", "Qwen3-ASR+词汇表+规则整理，约 2.5 GB"),
]


def load_jsonl(path):
    if not path.exists():
        return []
    return [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]


def main():
    ids = [l.split("\t")[0] for l in (REAL / "truth.tsv").read_text(encoding="utf-8").splitlines() if l.strip()]
    results = {i: {} for i in ids}
    seconds = {}
    for r in load_jsonl(REAL / "results_local.jsonl") + load_jsonl(REAL / "results_apple.jsonl") + load_jsonl(REAL / "results_rules.jsonl"):
        if r["id"] in results:
            results[r["id"]][r["engine"]] = r.get("text", "")
            seconds.setdefault(r["engine"], []).append(r.get("seconds", 0))
    for h in load_jsonl(APP / "history.jsonl"):
        sid = (h.get("audio") or "").removesuffix(".wav")
        if sid in results:
            results[sid]["history"] = h.get("final", "")
            seconds.setdefault("history", []).append(h.get("latency", 0))

    rows = []
    for sid in ids:
        with wave.open(str(REAL / "audio" / f"{sid}.wav")) as w:
            dur = w.getnframes() / w.getframerate()
        rows.append({"id": sid, "dur": round(dur, 1), "out": results[sid]})
    labels_file = REAL / "labels.json"
    labels = json.loads(labels_file.read_text(encoding="utf-8")) if labels_file.exists() else {}
    engines = [{"key": k, "name": n, "desc": d,
                "sec": round(sum(seconds.get(k, [0])) / max(1, len(seconds.get(k, []))), 2)} for k, n, d in ENGINES]

    html = TEMPLATE.replace("/*DATA*/", json.dumps({"rows": rows, "engines": engines, "labels": labels}, ensure_ascii=False))
    (REAL / "index.html").write_text(html, encoding="utf-8")
    print(f"{len(rows)} 条 → {REAL / 'index.html'}")


TEMPLATE = r"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>识别方案对比</title>
<style>
:root { --bg:#f7f7f5; --card:#fff; --fg:#1d1d1f; --muted:#6e6e73; --line:#e3e3e0; --accent:#0a64d6;
        --good:#1a7f37; --bad:#c62828; --pick:#e8f1fd; --badbg:#fde8e8; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#161617; --card:#1f1f21; --fg:#f2f2f2; --muted:#9a9aa0; --line:#333336; --accent:#5aa2ff;
          --good:#4cc26b; --bad:#ff7066; --pick:#1d3350; --badbg:#4a2422; } }
* { box-sizing:border-box } body { margin:0; background:var(--bg); color:var(--fg);
  font:14px/1.5 -apple-system, "PingFang SC", sans-serif }
header { position:sticky; top:0; z-index:2; background:var(--bg); border-bottom:1px solid var(--line); padding:14px 20px }
h1 { font-size:18px; margin:0 0 4px } .muted { color:var(--muted) } main { padding:16px 20px 80px; max-width:1200px; margin:auto }
table.board { border-collapse:collapse; width:100%; margin-top:10px; background:var(--card); border-radius:8px; overflow:hidden }
.board th, .board td { padding:6px 10px; border-bottom:1px solid var(--line); text-align:left; white-space:nowrap }
.board td.num { text-align:right; font-variant-numeric:tabular-nums } .board tr.best td { color:var(--good); font-weight:600 }
.bar { display:inline-block; height:6px; background:var(--accent); border-radius:3px; vertical-align:middle; margin-left:6px }
.toolbar { display:flex; gap:10px; flex-wrap:wrap; align-items:center; margin-top:10px }
button, select { font:inherit; padding:4px 10px; border-radius:6px; border:1px solid var(--line); background:var(--card); color:var(--fg); cursor:pointer }
.row { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 14px; margin:12px 0 }
.row.done { border-left:4px solid var(--good) } .head { display:flex; gap:12px; align-items:center; flex-wrap:wrap }
audio { height:30px } .opt { display:grid; grid-template-columns:150px 1fr 56px; gap:8px; padding:5px 8px; border-radius:6px; cursor:pointer; align-items:baseline }
.opt:hover { background:var(--pick) } .opt.chosen { background:var(--pick); outline:1px solid var(--accent) }
.opt .name { color:var(--muted); font-size:12px } .opt .cer { text-align:right; font-size:12px; font-variant-numeric:tabular-nums }
.cer.ok { color:var(--good) } .cer.ng { color:var(--bad) } del { background:var(--badbg); color:var(--bad); text-decoration:none; border-radius:2px }
textarea { width:100%; font:inherit; padding:6px 8px; border-radius:6px; border:1px solid var(--line); background:var(--bg); color:var(--fg); resize:vertical; min-height:34px; margin-top:6px }
.tag { font-size:12px; padding:1px 6px; border-radius:4px; background:var(--pick); color:var(--accent) }
</style></head><body>
<header>
  <h1>识别方案对比 <span class="muted" id="progress"></span></h1>
  <div class="muted">逐条点选正确的那一行（或在下方文本框改成你实际说的话），上方排行实时更新。字错率 = 编辑距离 ÷ 正确答案字数（忽略标点、空格和英文大小写）。</div>
  <table class="board"><thead><tr><th>方案</th><th>平均字错率</th><th>全对</th><th>平均耗时</th><th>说明</th></tr></thead><tbody id="board"></tbody></table>
  <div class="toolbar">
    <label><input type="checkbox" id="onlyTodo"> 只看未标注</label>
    <label><input type="checkbox" id="onlyDiff" checked> 隐藏各方案完全一致的</label>
    <button id="agreeAll">把各方案一致的条目一键标为正确</button>
    <button id="export">导出标注 labels.json</button>
  </div>
</header>
<main id="list"></main>
<script>
const DATA = /*DATA*/;
const KEY = "vocalocal-labels";
let labels = Object.assign({}, DATA.labels, JSON.parse(localStorage.getItem(KEY) || "{}"));
const save = () => { try { localStorage.setItem(KEY, JSON.stringify(labels)) } catch (e) {} };
const norm = s => (s || "").normalize("NFKC").toLowerCase().replace(/[\s\p{P}\p{S}]/gu, "");

function dist(a, b) {
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    prev = cur;
  }
  return prev[b.length];
}
const cer = (truth, hyp) => { const t = [...norm(truth)], h = [...norm(hyp)]; return t.length ? dist(t, h) / t.length : (h.length ? 1 : 0) };

// 标出 hyp 里和 truth 不一致的字（按字符 LCS）
function markDiff(truth, hyp) {
  const a = [...truth], b = [...hyp], n = a.length, m = b.length;
  const L = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
    L[i][j] = a[i] === b[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  let i = 0, j = 0, out = "", bad = "";
  const esc = s => s.replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  const flush = () => { if (bad) { out += "<del>" + esc(bad) + "</del>"; bad = "" } };
  while (j < m) {
    if (i < n && a[i] === b[j]) { flush(); out += esc(b[j]); i++; j++ }
    else if (i < n && L[i + 1][j] >= L[i][j + 1]) i++;
    else { if (!/[\s\p{P}]/u.test(b[j])) bad += b[j]; else { flush(); out += esc(b[j]) } j++ }
  }
  flush(); return out;
}

const outputs = r => DATA.engines.map(e => r.out[e.key]).filter(x => x !== undefined);
const allAgree = r => { const o = outputs(r).map(norm).filter(Boolean); return o.length > 1 && o.every(x => x === o[0]) };

function board() {
  const done = DATA.rows.filter(r => labels[r.id] !== undefined && labels[r.id] !== null);
  document.getElementById("progress").textContent = `已标注 ${done.length} / ${DATA.rows.length}`;
  const stats = DATA.engines.map(e => {
    const rs = done.filter(r => r.out[e.key] !== undefined);
    const errs = rs.map(r => cer(labels[r.id], r.out[e.key]));
    return { e, n: rs.length, avg: errs.length ? errs.reduce((a, b) => a + b, 0) / errs.length : null, exact: errs.filter(x => x === 0).length };
  });
  const best = Math.min(...stats.filter(s => s.avg !== null).map(s => s.avg));
  document.getElementById("board").innerHTML = stats.map(s => `<tr class="${s.avg === best ? "best" : ""}">
    <td>${s.e.name}</td>
    <td class="num">${s.avg === null ? "—" : (s.avg * 100).toFixed(1) + "%"}<span class="bar" style="width:${s.avg === null ? 0 : Math.min(120, s.avg * 600)}px"></span></td>
    <td class="num">${s.n ? s.exact + " / " + s.n : "—"}</td><td class="num">${s.e.sec ? s.e.sec + " s" : "—"}</td>
    <td class="muted">${s.e.desc}</td></tr>`).join("");
}

function render() {
  const onlyTodo = document.getElementById("onlyTodo").checked, onlyDiff = document.getElementById("onlyDiff").checked;
  const list = document.getElementById("list"); list.innerHTML = "";
  for (const r of DATA.rows) {
    const truth = labels[r.id];
    if (onlyTodo && truth != null) continue;
    if (onlyDiff && allAgree(r)) continue;
    const div = document.createElement("div");
    div.className = "row" + (truth != null ? " done" : "");
    const time = r.id.replace(/^(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d).*/, "$2-$3 $4:$5:$6");
    div.innerHTML = `<div class="head"><b>${time}</b><span class="muted">${r.dur}s</span>
      <audio controls preload="none" src="audio/${r.id}.wav"></audio>${allAgree(r) ? '<span class="tag">各方案一致</span>' : ""}</div>`;
    for (const e of DATA.engines) {
      const text = r.out[e.key]; if (text === undefined) continue;
      const opt = document.createElement("div");
      const err = truth != null ? cer(truth, text) : null;
      opt.className = "opt" + (truth != null && norm(truth) === norm(text) ? " chosen" : "");
      opt.innerHTML = `<span class="name">${e.name}</span><span>${truth != null ? markDiff(truth, text) : (text || '<span class="muted">（空）</span>')}</span>
        <span class="cer ${err === 0 ? "ok" : "ng"}">${err === null ? "" : (err * 100).toFixed(0) + "%"}</span>`;
      opt.onclick = () => { labels[r.id] = text; save(); render(); board() };
      div.appendChild(opt);
    }
    const ta = document.createElement("textarea");
    ta.placeholder = "正确答案：点上面某一行，或直接输入你实际说的话"; ta.value = truth ?? "";
    ta.onchange = () => { labels[r.id] = ta.value.trim() || null; if (!labels[r.id]) delete labels[r.id]; save(); render(); board() };
    div.appendChild(ta);
    list.appendChild(div);
  }
}

document.getElementById("onlyTodo").onchange = render;
document.getElementById("onlyDiff").onchange = render;
document.getElementById("agreeAll").onclick = () => {
  for (const r of DATA.rows) if (allAgree(r) && labels[r.id] == null) labels[r.id] = outputs(r).find(Boolean);
  save(); render(); board();
};
document.getElementById("export").onclick = () => {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([JSON.stringify(labels, null, 1)], { type: "application/json" }));
  a.download = "labels.json"; a.click();
};
render(); board();
</script></body></html>
"""

if __name__ == "__main__":
    main()
