---
name: translate-chunks-vi
description: Use for the "Bước giữa" (middle step) of TranslateVITool's pipeline — after 01_transcribe_chunk.sh and before 02_build_srt.sh. Scans output/ for folders that have chunks.json but no vi_translations.json yet, translates each chunk's text to natural Vietnamese, and writes vi_translations.json next to chunks.json in that same folder. Idempotent — skips folders already translated or not yet transcribed.
---

# Dịch chunks.json → vi_translations.json

Thực hiện đúng "Bước giữa" được mô tả trong `README.md` của tool này: không
có model dịch local, nên bước này do Claude làm trực tiếp (không qua script)
cho từng folder trong `output/` đã có `chunks.json` ở bước 1.

`OUTPUT_DIR` = thư mục `output/` nằm ở gốc tool (2 cấp trên `.claude/skills/`
so với file này — tức là sibling của `README.md`, `00_download.sh`, ...).

## Phạm vi chạy

- Không có tham số: quét **toàn bộ** thư mục con trực tiếp dưới `OUTPUT_DIR`.
- Có tham số là 1 tên folder (hoặc đường dẫn tuyệt đối): chỉ xử lý folder đó.
- Có tham số là 1 file JSON (`data.json` dạng `[{"FolderName": ...}]`): chỉ
  xử lý các `FolderName` được liệt kê trong file đó, dưới `OUTPUT_DIR`.

## Với mỗi folder ứng viên

Bỏ qua (không báo lỗi) nếu:
- Folder đã có file `.srt` → đã xong hoàn toàn (bước 2 đã dọn `chunks.json`).
- Folder **chưa có** `chunks.json` → chưa transcribe (cần chạy
  `01_transcribe_chunk.sh` trước).
- Folder **đã có** `vi_translations.json` rồi → đã dịch, chỉ còn chờ chạy
  `02_build_srt.sh`.

Ngược lại (có `chunks.json`, chưa có `vi_translations.json`, chưa có `.srt`):
đọc `chunks.json` — 1 JSON array of `{"start": ..., "end": ..., "text": ...}`
— và dịch field `text` của từng phần tử, **theo đúng thứ tự**.

Quy tắc dịch (áp dụng cho mọi chunk, đọc lướt vài chunk lân cận để giữ mạch
đại từ/ngữ cảnh xuyên suốt, không dịch tách rời từng câu):
- Giữ nguyên tiếng Anh với tên file/tool/sản phẩm/thuật ngữ kỹ thuật:
  `agents.md`, `Claude.md`, `Claude Code`, `README`, `Markdown`, `API`,
  `MCP`, `LLM`, `AI`, `PR`, `Python`, `HTML`, `H1/H2/H3`, tên công cụ khác
  (`Cursor`, `GitHub Copilot`, `Docker`, `Next.js`, v.v.) — phần còn lại
  dịch tự nhiên, văn nói, không word-by-word.
- Có thể sửa lỗi ASR nghe sai dựa vào ngữ cảnh (ví dụ tên tool bị phiên âm
  sai) thay vì dịch nguyên văn lỗi đó.

Ghi kết quả ra `<folder>/vi_translations.json`: **1 JSON array of string**,
**cùng độ dài và cùng thứ tự** với `chunks.json` (phần tử thứ `i` là bản
dịch của `chunks.json[i].text`). Không bọc thêm object, không thêm field
`start`/`end`.

## Tổng kết

Sau khi xử lý hết các folder ứng viên, báo cáo ngắn: tổng số folder đã quét,
số folder vừa dịch (ghi `vi_translations.json` mới), số đã bỏ qua vì đã xong
(`.srt`) hoặc vì đã dịch trước đó, và số bị bỏ qua vì chưa có `chunks.json`.
Nhắc người dùng bước tiếp theo là chạy `./02_build_srt.sh` cho các folder vừa
dịch.

## Lưu ý

- Không tự tạo `chunks.json` hay sửa `transcript.json` — skill này chỉ đọc
  `chunks.json` có sẵn và ghi `vi_translations.json`, không chạy script
  Python/whisper nào.
- Nếu `chunks.json` trong 1 folder bị lỗi JSON hoặc rỗng, báo cho người dùng
  và bỏ qua folder đó, không làm gián đoạn các folder còn lại.
