import sys
import json
import re

MAX_WORDS = 11
MAX_DUR = 6.5
BREAK_CONJ = {"and", "but", "so", "because", "which", "that", "when", "if", "or"}


def flatten_words(transcript):
    words = []
    for seg in transcript["segments"]:
        for w in seg.get("words", []):
            words.append({"word": w["word"], "start": w["start"], "end": w["end"]})
    return words


def split_into_sentences(words):
    sentences = []
    cur = []
    for w in words:
        cur.append(w)
        if re.search(r'[.!?]["\')\]]?$', w["word"].strip()):
            sentences.append(cur)
            cur = []
    if cur:
        sentences.append(cur)
    return sentences


def split_sentence(sw):
    n = len(sw)
    if n <= MAX_WORDS and (sw[-1]["end"] - sw[0]["start"]) <= MAX_DUR:
        return [sw]

    breaks = set()
    for i, w in enumerate(sw):
        token = w["word"].strip()
        if re.search(r"[,;:]$", token):
            breaks.add(i + 1)
        low = token.lower().strip(".,!?;:")
        if low in BREAK_CONJ and i > 0:
            breaks.add(i)
    breaks.add(n)
    breaks = sorted(b for b in breaks if 0 < b <= n)

    chunks = []
    start_idx = 0
    while start_idx < n:
        best = None
        for b in breaks:
            if b <= start_idx:
                continue
            length = b - start_idx
            dur = sw[b - 1]["end"] - sw[start_idx]["start"]
            if length <= MAX_WORDS and dur <= MAX_DUR:
                best = b
            else:
                break
        if best is None:
            best = min(start_idx + MAX_WORDS, n)
        chunks.append(sw[start_idx:best])
        start_idx = best
    return chunks


def build_chunks(transcript):
    words = flatten_words(transcript)
    sentences = split_into_sentences(words)

    all_chunks = []
    for sent in sentences:
        for c in split_sentence(sent):
            if not c:
                continue
            text = "".join(w["word"] for w in c).strip()
            text = re.sub(r"\s+", " ", text)
            all_chunks.append({"start": c[0]["start"], "end": c[-1]["end"], "text": text})

    merged = []
    for c in all_chunks:
        if (
            merged
            and len(c["text"].split()) <= 2
            and not re.search(r"[.!?]$", merged[-1]["text"])
        ):
            merged[-1]["end"] = c["end"]
            merged[-1]["text"] = (merged[-1]["text"] + " " + c["text"]).strip()
        else:
            merged.append(c)
    return merged


def main():
    if len(sys.argv) < 3:
        print("usage: make_chunks.py <transcript_json> <out_chunks_json>", file=sys.stderr)
        sys.exit(1)

    transcript = json.load(open(sys.argv[1], encoding="utf-8"))
    chunks = build_chunks(transcript)

    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(chunks, f, ensure_ascii=False, indent=1)

    print(f"total chunks: {len(chunks)} -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
