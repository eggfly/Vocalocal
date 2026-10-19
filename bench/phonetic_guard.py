"""发音相近校验：纠错模型给出的 {from, to} 只有在读音接近时才接受。

真实录音中的观察：正确的修改几乎都发音相近（派送→Python、考→拷、李依晨→李一辰），
错误的修改大多发音不同（改低→改高、SSD→机械硬盘、思维→Vocalocal）。
做法：把 from / to 都转成拼音字母串（英文保持原样、数字读成中文拼音），比较相似度。
"""
import re

from corrector_bench import pinyin

DIGITS = {"0": "ling", "1": "yi", "2": "er", "3": "san", "4": "si", "5": "wu", "6": "liu", "7": "qi", "8": "ba", "9": "jiu"}
FILLERS = {"呃", "嗯", "啊", "额", "呃呃", "嗯嗯", "啊啊", "um", "uh"}


def sound(s: str) -> str:
    s = re.sub(r"\d", lambda m: DIGITS[m.group()], s)
    return re.sub(r"[^a-z]", "", pinyin(s).lower())


def similarity(a: str, b: str) -> float:
    a, b = sound(a), sound(b)
    if not a or not b:
        return 0.0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
        prev = cur
    return 1 - prev[-1] / max(len(a), len(b))


def core(frm: str, to: str) -> tuple[str, str]:
    """去掉两边相同的前后缀，只比较真正改动的部分。
    模型常把修改连同上下文一起给出（"改低一下那个→改高一下那个"），整体看很像，其实只改了 低→高。"""
    i = 0
    while i < min(len(frm), len(to)) and frm[i] == to[i]:
        i += 1
    j = 0
    while j < min(len(frm), len(to)) - i and frm[-1 - j] == to[-1 - j]:
        j += 1
    return frm[i:len(frm) - j], to[i:len(to) - j]


def accept(frm: str, to: str, hotwords: set) -> tuple[bool, float]:
    """返回 (是否接受, 相似度)。改成词汇表/屏幕术语时门槛放低（中文音译英文本来就不太像）"""
    to = to.strip()
    if not to:
        return frm.strip("，。,.！？!? ").lower() in FILLERS, 1.0
    a, b = core(frm, to)
    if not sound(a) and not sound(b):          # 只改了空格 / 标点 / 大小写
        return True, 1.0
    vocab = [w.lower() for w in hotwords if len(w) >= 2]
    gains_term = any(w in to.lower() and w not in frm.lower() for w in vocab)
    if not sound(a):                            # 纯插入：只允许补上词汇表里的词
        return gains_term, 0.0
    if not sound(b):                            # 纯删除：只允许删语气词
        return a.strip("，。,.！？!? ").lower() in FILLERS, 0.0
    sim = similarity(a, b)
    return sim >= (0.25 if gains_term else 0.6), sim
