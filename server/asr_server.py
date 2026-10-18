"""本地 Qwen3-ASR 服务，OpenAI 兼容接口：POST /v1/audio/transcriptions
额外支持两个表单字段（OpenAI 没有）：
  hotwords  逗号分隔的词汇表
  context   场景 / 输入框前文，作为识别时的上下文
模型常驻内存；单线程推理，请求串行处理。
"""
import json
import os
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from mlx_audio.stt.utils import load_model

from asr_server_common import log, parse_multipart

MODEL_ID = os.environ.get("VOCALOCAL_ASR_MODEL", "mlx-community/Qwen3-ASR-1.7B-8bit")
PORT = int(os.environ.get("VOCALOCAL_ASR_PORT", "8765"))
LANGUAGES = {"zh": "Chinese", "en": "English", "ja": "Japanese", "ko": "Korean", "yue": "Cantonese"}

model = load_model(MODEL_ID)
lock = threading.Lock()


def transcribe(path: str, language: str | None, hotwords: list[str], context: str) -> str:
    kwargs = {}
    if hotwords:
        kwargs["hotwords"] = hotwords
    if context:
        kwargs["system_prompt"] = context
    with lock:
        return model.generate(path, language=language, **kwargs).text.strip()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status: int, payload: dict):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") in ("/health", "/v1/models"):
            self.reply(200, {"ok": True, "model": MODEL_ID})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/audio/transcriptions":
            return self.reply(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            fields = parse_multipart(self.headers.get("Content-Type", ""), self.rfile.read(length))
            audio = fields.get("file")
            if not audio:
                return self.reply(400, {"error": "missing file"})
            lang_code = fields.get("language", b"").decode().strip()[:2].lower()
            language = LANGUAGES.get(lang_code)  # None 表示自动检测
            hotwords = [w.strip() for w in fields.get("hotwords", b"").decode().replace("，", ",").split(",") if w.strip()]
            context = fields.get("context", b"").decode().strip()

            with tempfile.NamedTemporaryFile(suffix=".wav") as f:
                f.write(audio)
                f.flush()
                t = time.time()
                text = transcribe(f.name, language, hotwords, context)
            log(f"{time.time() - t:.2f}s {len(audio) // 1024}KB lang={language} hot={len(hotwords)} ctx={len(context)} -> {text}")
            self.reply(200, {"text": text})
        except Exception as e:  # 服务不能因为一个坏请求退出
            log(f"error: {e!r}")
            self.reply(500, {"error": str(e)})


if __name__ == "__main__":
    # 预热：首次推理有编译开销
    import numpy as np
    model.generate(np.zeros(16000, dtype=np.float32), language="Chinese")
    log(f"ready: {MODEL_ID} on 127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
