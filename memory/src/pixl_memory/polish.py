"""Prompt for "polish this" and a word-level diff for the UI."""

from __future__ import annotations

import difflib
import re

SYSTEM = (
    "You are a careful editor. Apply the user's instruction to the text inside <text> tags. "
    "Keep the author's meaning, voice, language and formatting (line breaks, lists, markdown). "
    "Do not add facts. Reply with the revised text only: no preamble, no explanation, no quotes, no tags."
)

DEFAULT_INSTRUCTION = "Polish this: fix grammar and spelling, tighten wording, keep my voice."
MAX_CHARS = 20_000


def messages(text: str, instruction: str | None) -> list[dict[str, str]]:
    instruction = (instruction or "").strip() or DEFAULT_INSTRUCTION
    return [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": f"Instruction: {instruction}\n\n<text>\n{text}\n</text>"},
    ]


_THINK = re.compile(r"<think>.*?</think>", re.S)


def clean(output: str, source: str) -> str:
    """Strip wrappers models sometimes add despite the prompt."""
    out = _THINK.sub("", output).strip()
    m = re.fullmatch(r"<text>\s*(.*?)\s*</text>", out, re.S)
    if m:
        out = m.group(1)
    if len(out) >= 2 and out[0] == out[-1] and out[0] in "\"'“" and not (source[:1] == out[0]):
        out = out[1:-1]
    if out.startswith("“") and out.endswith("”") and not source.startswith("“"):
        out = out[1:-1]
    # Keep the source's surrounding whitespace so a drop replaces the selection cleanly.
    lead = source[: len(source) - len(source.lstrip())]
    trail = source[len(source.rstrip()) :]
    return lead + out.strip() + trail


_TOKEN = re.compile(r"\s+|\w+|[^\w\s]", re.U)


def word_diff(a: str, b: str) -> list[dict[str, str]]:
    """[{op: equal|delete|insert, text}] at word granularity, adjacent ops merged."""
    ta, tb = _TOKEN.findall(a), _TOKEN.findall(b)
    ops: list[dict[str, str]] = []

    def push(op: str, text: str) -> None:
        if not text:
            return
        if ops and ops[-1]["op"] == op:
            ops[-1]["text"] += text
        else:
            ops.append({"op": op, "text": text})

    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, ta, tb, autojunk=False).get_opcodes():
        if tag == "equal":
            push("equal", "".join(ta[i1:i2]))
        else:
            push("delete", "".join(ta[i1:i2]))
            push("insert", "".join(tb[j1:j2]))
    return ops


def diff_stats(ops: list[dict[str, str]]) -> dict[str, int]:
    words = lambda s: len(re.findall(r"\w+", s))  # noqa: E731
    return {
        "inserted_words": sum(words(o["text"]) for o in ops if o["op"] == "insert"),
        "deleted_words": sum(words(o["text"]) for o in ops if o["op"] == "delete"),
    }
