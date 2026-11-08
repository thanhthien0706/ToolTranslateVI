import sys
import json


def fmt(t):
    h = int(t // 3600)
    m = int((t % 3600) // 60)
    s = int(t % 60)
    ms = int(round((t - int(t)) * 1000))
    if ms == 1000:
        ms = 0
        s += 1
        if s == 60:
            s = 0
            m += 1
            if m == 60:
                m = 0
                h += 1
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def main():
    if len(sys.argv) < 4:
        print(
            "usage: build_srt.py <chunks_json> <vi_translations_json> <out_srt>",
            file=sys.stderr,
        )
        sys.exit(1)

    chunks = json.load(open(sys.argv[1], encoding="utf-8"))
    vi = json.load(open(sys.argv[2], encoding="utf-8"))
    out_srt = sys.argv[3]

    if len(chunks) != len(vi):
        print(
            f"ERROR: count mismatch chunks={len(chunks)} vi={len(vi)}",
            file=sys.stderr,
        )
        sys.exit(1)

    lines = []
    for i, (c, text) in enumerate(zip(chunks, vi), start=1):
        lines.append(str(i))
        lines.append(f"{fmt(c['start'])} --> {fmt(c['end'])}")
        lines.append(text)
        lines.append("")

    with open(out_srt, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"Wrote {len(chunks)} cues -> {out_srt}")


if __name__ == "__main__":
    main()
