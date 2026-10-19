"""用自己的真实录音横向对比各方案（没有标准答案，结果交给 make_report.py 生成对比页人工挑选）。

读取 ~/Library/Application Support/Vocalocal/recordings，在 bench/real/ 下生成：
  audio/<id>.wav        录音的符号链接（对比页播放用）
  truth.tsv             id 列表（给 App 的 --bench 模式跑苹果识别）
  results_local.jsonl   本地模型的结果

需要识别服务（:8765）和纠错服务（:8766）在运行。
用法: .venv-omni/bin/python real_bench.py [--no-minicpm]
"""
import json
import os
import sys
import time
import urllib.request
import wave
from pathlib import Path

from corrector_bench import AUDIO_PROMPT, apply, multipart, parse_fixes

APP = Path(os.path.expanduser("~/Library/Application Support/Vocalocal"))
OUT = Path(__file__).resolve().parent / "real"
CONFIG = Path(os.path.expanduser("~/.config/vocalocal/config.json"))
MIN_SECONDS = 0.6


def post(url, fields, wav, timeout=120):
    body, ctype = multipart(fields, wav)
    req = urllib.request.Request(url, body, {"Content-Type": ctype})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def asr(wav, hotwords=""):
    return post("http://127.0.0.1:8765/v1/audio/transcriptions", {"language": "zh", "hotwords": hotwords}, wav)["text"]


def correct_server(wav, draft, hotwords):
    return post("http://127.0.0.1:8766/v1/correct", {"draft": draft, "hotwords": hotwords}, wav)["fixes"]


def main():
    vocab = json.loads(CONFIG.read_text()).get("vocabulary", "")
    hotwords = ",".join(w.strip() for w in vocab.replace("\n", ",").split(",") if w.strip())

    (OUT / "audio").mkdir(parents=True, exist_ok=True)
    ids = []
    for f in sorted((APP / "recordings").glob("*.wav")):
        with wave.open(str(f)) as w:
            if w.getnframes() / w.getframerate() < MIN_SECONDS:
                continue
        link = OUT / "audio" / f.name
        if not link.exists():
            link.symlink_to(f)
        ids.append(f.stem)
    (OUT / "truth.tsv").write_text("".join(f"{i}\t\n" for i in ids), encoding="utf-8")
    print(f"{len(ids)} recordings", flush=True)

    minicpm = None
    if "--no-minicpm" not in sys.argv:
        from mlx_vlm import apply_chat_template, generate, load
        model, processor = load("mlx-community/MiniCPM-o-4_5-4bit")

        def minicpm(wav, draft):
            msgs = [{"role": "system", "content": AUDIO_PROMPT},
                    {"role": "user", "content": f"词汇表：{hotwords}\n\n识别初稿：\n{draft}"}]
            prompt = apply_chat_template(processor, model.config, msgs, num_audios=1)
            out = generate(model, processor, prompt, audio=[wav], max_tokens=200, temperature=0.0, verbose=False).text
            return parse_fixes(out)

    # 可续跑：已经有完整结果的录音跳过
    results_path = OUT / "results_local.jsonl"
    done = {}
    if results_path.exists():
        for line in results_path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                r = json.loads(line)
                done.setdefault(r["id"], set()).add(r["engine"])
    need = {"qwen3-asr", "qwen3-asr+词汇表", "+Qwen3-Omni纠错"} | ({"+MiniCPM-o纠错"} if minicpm else set())
    complete = {i for i, engines in done.items() if need <= engines}
    if done:
        # 去掉没跑完的录音的残缺结果
        kept = [l for l in results_path.read_text(encoding="utf-8").splitlines() if l.strip() and json.loads(l)["id"] in complete]
        results_path.write_text("".join(l + "\n" for l in kept), encoding="utf-8")
        print(f"resume: {len(complete)} done", flush=True)

    with results_path.open("a", encoding="utf-8") as out:
        def emit(engine, sid, text, seconds, **extra):
            out.write(json.dumps({"engine": engine, "id": sid, "text": text, "seconds": round(seconds, 3), **extra},
                                 ensure_ascii=False) + "\n")
            out.flush()

        for n, sid in enumerate(ids, 1):
            if sid in complete:
                continue
            wav = str(OUT / "audio" / f"{sid}.wav")
            t = time.time(); plain = asr(wav); emit("qwen3-asr", sid, plain, time.time() - t)
            t = time.time(); draft = asr(wav, hotwords); t_asr = time.time() - t
            emit("qwen3-asr+词汇表", sid, draft, t_asr)
            if not draft.strip():
                continue
            t = time.time(); fixes = correct_server(wav, draft, hotwords)
            text, applied, rejected = apply(fixes, draft)
            emit("+Qwen3-Omni纠错", sid, text, t_asr + time.time() - t, applied=applied, rejected=rejected)
            if minicpm:
                t = time.time(); fixes = minicpm(wav, draft)
                text, applied, rejected = apply(fixes, draft)
                emit("+MiniCPM-o纠错", sid, text, t_asr + time.time() - t, applied=applied, rejected=rejected)
            print(f"[{n}/{len(ids)}] {sid}  {draft[:40]}", flush=True)
    print("saved", OUT / "results_local.jsonl")


if __name__ == "__main__":
    main()
