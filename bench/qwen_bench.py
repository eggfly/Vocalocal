"""Qwen3-ASR（MLX）评测：无上下文 / 热词 / 热词+场景，三种模式。
用法: .venv/bin/python qwen_bench.py [模型ID]
"""
import json
import sys
import time

from mlx_audio.stt.utils import load_model

from common import BENCH, SCENE, VOCAB, cer, load_truth

MODEL = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Qwen3-ASR-1.7B-8bit"
MODES = {
    "plain": {},
    "vocab": {"hotwords": VOCAB},
    "vocab+scene": {"hotwords": VOCAB, "system_prompt": SCENE},
}

t0 = time.time()
model = load_model(MODEL)
print(f"loaded {MODEL} in {time.time() - t0:.1f}s", flush=True)

# 预热一次，排除首次编译的开销
model.generate(str(load_truth()[0][2]), language="Chinese")

out_path = BENCH / f"results_{MODEL.split('/')[-1]}.jsonl"
with out_path.open("w", encoding="utf-8") as out:
    for sid, ref, wav in load_truth():
        for mode, kwargs in MODES.items():
            t = time.time()
            text = model.generate(str(wav), language="Chinese", **kwargs).text.strip()
            dt = time.time() - t
            row = {"engine": f"qwen3-asr/{mode}", "id": sid, "cer": round(cer(ref, text), 4),
                   "seconds": round(dt, 3), "text": text}
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            print(f"{sid:7} {mode:12} cer={row['cer']:.3f} {dt:.2f}s  {text}", flush=True)
print("saved", out_path)
