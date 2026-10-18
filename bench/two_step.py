"""两步式：Qwen3-ASR（带热词+场景）→ 本地 ollama LLM 润色（带同样的上下文）。
用法: .venv/bin/python two_step.py [ollama模型]
"""
import json
import sys
import time
import urllib.request

from mlx_audio.stt.utils import load_model

from common import BENCH, DICTATION_PROMPT, SCENE, VOCAB, cer, context_block, load_truth, looks_like_answer

LLM = sys.argv[1] if len(sys.argv) > 1 else "qwen2.5:7b"
asr = load_model("mlx-community/Qwen3-ASR-1.7B-8bit")


def polish(raw: str) -> str:
    user = context_block() + f"\n<transcript>\n{raw}\n</transcript>"
    body = json.dumps({"model": LLM, "temperature": 0.2, "stream": False, "messages": [
        {"role": "system", "content": DICTATION_PROMPT}, {"role": "user", "content": user}]}).encode()
    req = urllib.request.Request("http://127.0.0.1:11434/v1/chat/completions", body, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=120))["choices"][0]["message"]["content"].strip()


samples = load_truth()
asr.generate(str(samples[0][2]), language="Chinese")   # 预热
polish("预热")

engine = f"two-step/qwen3asr+{LLM}"
out_path = BENCH / f"results_two-step_{LLM.replace(':', '-')}.jsonl"
with out_path.open("w", encoding="utf-8") as out:
    for sid, ref, wav in samples:
        t = time.time()
        raw = asr.generate(str(wav), language="Chinese", hotwords=VOCAB, system_prompt=SCENE).text.strip()
        t_asr = time.time() - t
        final = polish(raw)
        total = time.time() - t
        row = {"engine": engine, "id": sid, "text": final, "raw": raw, "seconds": round(total, 3),
               "asr_seconds": round(t_asr, 3), "cer": round(cer(ref, final), 4), "answered": looks_like_answer(ref, final)}
        out.write(json.dumps(row, ensure_ascii=False) + "\n")
        flag = "  ⚠️回答了" if row["answered"] else ""
        print(f"{sid:7} cer={row['cer']:.3f} asr={t_asr:.2f}s total={total:.2f}s  {final}{flag}", flush=True)
print("saved", out_path)
