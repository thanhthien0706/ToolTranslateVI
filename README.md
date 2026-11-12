# TranslateVITool

Tool tải video khoá học, tạo phụ đề tiếng Việt và gắn cứng phụ đề vào video.

Copy cả folder này sang máy khác là chạy được. Mọi file tạo ra đều nằm trong
`output/`.

## Cần cài trước

- Mac chip Apple Silicon (M1/M2/M3...)
- `python3`, `jq`, `ffmpeg`
- `ffmpeg-full`: `brew install ffmpeg-full` (dùng để gắn phụ đề)
- Docker đang chạy (dùng để tải video)
- `claude` (Claude Code), nếu muốn tự động dịch bằng `run_all.sh`

## File input

Một file JSON, để ở đâu cũng được:

```json
[
  { "Name": "Bài 1 - Giới thiệu", "FolderName": "w1-d1-01-intro", "Url": "https://..." }
]
```

Mỗi `FolderName` sẽ là một thư mục trong `output/`.

## Cách nhanh nhất: chạy 1 lệnh

```bash
./run_all.sh data/w1-d1.json
```

Lệnh này làm hết: tải video → nhận dạng giọng nói → dịch → tạo `.srt` → gắn
phụ đề. Nếu bị ngắt giữa chừng thì chạy lại đúng lệnh đó, phần đã xong sẽ tự
bỏ qua.

Tuỳ chọn thêm:

```bash
# Gom các video đã có phụ đề cùng ngày vào output/w1-d1-concat/
./run_all.sh data/w1-d1.json --prefix '^w\d+-d\d+'

# Gom xong thì nối thành 1 video dài (sẽ hỏi y/N trước khi nối)
./run_all.sh data/w1-d1.json --prefix '^w\d+-d\d+' --concat

# Bắt đầu từ một bước cụ thể: download, transcribe, translate, srt, burn, collect, concat
./run_all.sh data/w1-d1.json --from burn
```

## Chạy từng bước

Mỗi lệnh nhận **file JSON** (chạy cả danh sách) hoặc **tên folder** trong
`output/` (chạy 1 video).

| Bước | Lệnh | Kết quả |
| --- | --- | --- |
| 0. Tải video | `./00_download.sh data.json` | `output/<FolderName>/<Name>.mp4` |
| 1. Nhận dạng giọng nói | `./01_transcribe_chunk.sh data.json` | `chunks.json` |
| Dịch | `/translate-chunks-vi` (gõ trong Claude Code) | `vi_translations.json` |
| 2. Tạo phụ đề | `./02_build_srt.sh data.json` | `<tên>.srt` |
| 3. Gắn phụ đề | `./03_burn_sub.sh data.json` | `<tên>.sub.mp4` |

Video gốc không bao giờ bị sửa. Lỗi tải video được ghi vào
`output/<tên-json>.errors.json`, các video khác vẫn chạy tiếp.

Ví dụ cho đúng 1 video:

```bash
./00_download.sh "https://youtube.com/watch?v=..." "bai-1" "Bài 1"
./01_transcribe_chunk.sh "bai-1"
# trong Claude Code: /translate-chunks-vi bai-1
./02_build_srt.sh "bai-1"
./03_burn_sub.sh "bai-1"
```

## Lệnh phụ (tuỳ chọn)

| Lệnh | Dùng để |
| --- | --- |
| `./03b_collect_sub.sh data.json '^w\d+-d\d+'` | Gom các video đã có phụ đề cùng ngày vào `output/w1-d1-concat/01.mp4, 02.mp4...` |
| `./04_concat.sh w1-d1-concat` | Nối mọi video trong folder thành 1 file `w1-d1.full.mp4` (có chia chương) |
| `./group_by_prefix.sh '^w1-d1'` | Gộp các folder `w1-d1-01-...`, `w1-d1-02-...` thành 1 folder `w1-d1/` |
| `./03_burn_sub.sh --group w1-d1` | Gắn phụ đề cho folder có nhiều video, kết quả nằm trong `w1-d1/sub/` |
| `BURN_QUALITY=60 ./03_burn_sub.sh ...` | Đổi chất lượng video (mặc định 40, số càng cao càng nét và file càng to) |

## Lưu ý

- Bước 1 chỉ chạy được trên Mac Apple Silicon. Lần đầu chạy sẽ tự cài môi
  trường Python vào `.venv-whisper/`.
- Không chạy nhiều lệnh nhận dạng hoặc gắn phụ đề cùng lúc vì máy sẽ chậm. Các
  script đã tự chạy lần lượt từng video.
- File `.sub.mp4` có thể nặng gấp 2–3 lần video gốc.
