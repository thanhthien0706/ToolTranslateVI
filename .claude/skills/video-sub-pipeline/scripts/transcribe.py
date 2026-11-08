import sys
import json
import time
import mlx_whisper


def main():
    if len(sys.argv) < 3:
        print("usage: transcribe.py <video_path> <out_json> [model]", file=sys.stderr)
        sys.exit(1)

    video_path = sys.argv[1]
    out_json = sys.argv[2]
    model = sys.argv[3] if len(sys.argv) > 3 else "mlx-community/whisper-medium"

    t0 = time.time()
    result = mlx_whisper.transcribe(
        video_path,
        path_or_hf_repo=model,
        language="en",
        word_timestamps=True,
        verbose=True,
    )
    elapsed = time.time() - t0

    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(f"\nDONE in {elapsed:.1f}s -> {out_json}")


if __name__ == "__main__":
    main()
