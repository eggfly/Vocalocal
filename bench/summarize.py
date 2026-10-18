"""汇总 results_*.jsonl：每个引擎的平均字错率（CER）和平均耗时，以及逐条结果。"""
import json
from collections import defaultdict

from common import BENCH, cer, load_truth, looks_like_answer

truth = {sid: text for sid, text, _ in load_truth()}
rows = []
for path in sorted(BENCH.glob("results_*.jsonl")):
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            r = json.loads(line)
            r["cer"] = cer(truth[r["id"]], r.get("text", ""))  # 统一用同一个函数重算
            r["answered"] = looks_like_answer(truth[r["id"]], r.get("text", ""))
            rows.append(r)

by_engine = defaultdict(list)
for r in rows:
    by_engine[r["engine"]].append(r)

print(f"{'引擎':<40}{'平均CER':>8}{'全对':>7}{'回答了':>6}{'平均耗时':>9}")
for engine, rs in sorted(by_engine.items(), key=lambda kv: sum(r["cer"] for r in kv[1]) / len(kv[1])):
    avg = sum(r["cer"] for r in rs) / len(rs)
    exact = sum(r["cer"] == 0 for r in rs)
    secs = sum(r["seconds"] for r in rs) / len(rs)
    answered = sum(r["answered"] for r in rs)
    print(f"{engine:<40}{avg:>8.1%}{exact:>4}/{len(rs)}{answered:>6}{secs:>8.2f}s")

print()
for sid, ref in truth.items():
    print(f"[{sid}] 标准: {ref}")
    for engine in sorted(by_engine):
        r = next((x for x in by_engine[engine] if x["id"] == sid), None)
        if r:
            flag = "  ⚠️回答了" if r["answered"] else ""
            print(f"   {engine:<38}{r['cer']:>6.1%}  {r.get('text', '')}{flag}")
