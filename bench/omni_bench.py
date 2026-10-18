"""一步式：Qwen3-Omni 直接听音频输出整理好的文字（不经过转写文本）。
用法: .venv-omni/bin/python omni_bench.py [模型ID]
"""
import json
import sys
import time

from mlx_vlm import apply_chat_template, generate, load

from common import BENCH, OMNI_PROMPT, cer, context_block, load_truth, looks_like_answer

MODEL = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Qwen3-Omni-30B-A3B-Instruct-4bit"

t0 = time.time()
model, processor = load(MODEL)
print(f"loaded {MODEL} in {time.time() - t0:.1f}s", flush=True)


def run(wav, with_context: bool) -> str:
    user = "请把这段录音整理成可以直接发送的文字。"
    if with_context:
        user = context_block() + "\n" + user
    messages = [{"role": "system", "content": OMNI_PROMPT}, {"role": "user", "content": user}]
    prompt = apply_chat_template(processor, model.config, messages, num_audios=1)
    result = generate(model, processor, prompt, audio=[str(wav)], max_tokens=256, temperature=0.0, verbose=False)
    return result.text.strip()


samples = load_truth()
run(samples[0][2], False)   # 预热

out_path = BENCH / "results_omni.jsonl"
with out_path.open("w", encoding="utf-8") as out:
    for sid, ref, wav in samples:
        for mode, ctx in (("polish", False), ("polish+ctx", True)):
            t = time.time()
            text = run(wav, ctx)
            dt = time.time() - t
            row = {"engine": f"one-step/qwen3-omni/{mode}", "id": sid, "text": text, "seconds": round(dt, 3),
                   "cer": round(cer(ref, text), 4), "answered": looks_like_answer(ref, text)}
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            flag = "  ⚠️回答了" if row["answered"] else ""
            print(f"{sid:7} {mode:11} cer={row['cer']:.3f} {dt:.2f}s  {text}{flag}", flush=True)
print("saved", out_path)
