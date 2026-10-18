"""本地服务共用的小工具。"""
import time
from email.parser import BytesParser
from email.policy import default as email_policy


def log(msg: str):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def parse_multipart(content_type: str, body: bytes) -> dict:
    msg = BytesParser(policy=email_policy).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\nMIME-Version: 1.0\r\n\r\n" + body)
    fields = {}
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name:
            fields[name] = part.get_payload(decode=True) or b""
    return fields
