# TranslateVITool

Tool tự chứa (self-contained) để tải video, tạo phụ đề tiếng Việt, và burn
(nhúng cứng) phụ đề vào video. Copy nguyên folder `TranslateVITool/` này cho
máy khác, chỉ cần có file JSON data là chạy được ngay — không cần clone gì
thêm từ bên ngoài folder này, và mọi video/output đều nằm trong `output/`
ngay bên trong tool (xem mục "Mức độ độc lập" bên dưới về 1 giới hạn không
thể loại bỏ, liên quan phần cứng).

Input: file JSON dạng `[{"Name": "...", "FolderName": "...", "Url": "..."}]`.
File JSON này có thể nằm **bất kỳ đâu** (không cần cùng chỗ với tool) — mọi
video tải về và mọi output (phụ đề, file burned) đều được ghi vào 1 folder
chung `output/` nằm **bên trong chính tool này**, mỗi `FolderName` là 1 thư
mục con của `output/`. Nhờ vậy đưa cả folder `TranslateVITool/` cho máy
khác là có đủ toàn bộ dữ liệu đi kèm, không rải rác ra ngoài.

## Cấu trúc folder

```
TranslateVITool/
├── 00_download.sh
├── 01_transcribe_chunk.sh
├── 02_build_srt.sh
├── 03_burn_sub.sh
├── docker-compose.yml       # định nghĩa 2 image dùng cho bước 0 và 3
├── docker/
│   └── yt-dlp.Dockerfile
├── scripts/                 # 3 python helper, gọi bởi bước 1 và 2
│   ├── transcribe.py
│   ├── make_chunks.py
│   └── build_srt.py
├── output/                  # TẤT CẢ video + srt + file burned nằm ở đây
│   └── <FolderName>/
│       ├── <name>.mp4
│       ├── <name>.srt
│       └── <name>.sub.mp4
├── .venv-whisper/           # tự tạo ở lần chạy đầu bước 1, không commit vào git
└── README.md
```

## 4 bước — 4 file riêng biệt

Mỗi file `.sh` chạy độc lập, có thể gọi theo 2 cách:

```bash
./01_transcribe_chunk.sh "<name>"        # chạy cho đúng 1 video, folder "<name>" dưới ./output
./01_transcribe_chunk.sh "<data.json>"   # chạy hàng loạt theo JSON, tạo folder dưới ./output
```

(Tương tự cho `02_build_srt.sh` và `03_burn_sub.sh`. Riêng `00_download.sh`
ở chế độ đơn lẻ cần thêm URL — xem bên dưới.)

Script tự nhận diện: tham số kết thúc bằng `.json` → chạy hàng loạt (đọc
`FolderName` của từng entry, tạo/tìm folder dưới `./output`); nếu không,
tham số được hiểu là **tên folder** dưới `./output` (ví dụ `"demo"` →
`./output/demo`). Muốn trỏ ra ngoài `./output` thì truyền đường dẫn tuyệt
đối (bắt đầu bằng `/`) — script sẽ dùng nguyên path đó thay vì tự ghép vào
`output/`. Mỗi script đều **bỏ qua** (skip) những việc đã làm rồi, nên chạy
lại nhiều lần trên cùng JSON là an toàn (idempotent).

### Bước 0 — `00_download.sh`
Tải video bằng `yt-dlp`, chạy qua Docker (image `local-yt-dlp`, định nghĩa ở
`docker-compose.yml` + `docker/yt-dlp.Dockerfile`) — không cần cài `yt-dlp`
trên máy thật. Image **tự build ở lần chạy đầu tiên**, không cần làm gì
trước. Có 2 cách gọi:

```bash
./00_download.sh "<data.json>"                      # tải tất cả theo JSON, vào ./output/<FolderName>
./00_download.sh "<url>" "<name>" ["<filename>"]     # tải 1 video, vào ./output/<name>
```

- Chế độ JSON: với mỗi entry, tải `Url` vào `./output/<FolderName>`, đặt tên
  file theo `Name`. Bỏ qua entry nếu folder đã có `.mp4`. Entry tải lỗi
  được ghi vào `./output/<json-basename>.errors.json` (giống quy ước lỗi
  của bước transcribe), và tool vẫn tiếp tục tải các entry còn lại thay vì
  dừng cả batch.
- Chế độ đơn lẻ: `<url>` là link video, `<name>` là tên folder dưới
  `./output` (hoặc đường dẫn tuyệt đối để lưu ra ngoài), `<filename>` là
  tên file (không bắt buộc — nếu bỏ qua sẽ dùng tiêu đề gốc của video).
  Bỏ qua nếu folder đã có sẵn `.mp4`.

### Bước 1 — `01_transcribe_chunk.sh`
Transcribe video bằng `mlx-whisper` rồi chunk thành các câu ngắn.
Output: `transcript.json`, `chunks.json` trong từng folder.
Bỏ qua nếu folder đã có `.srt`, hoặc đã có `chunks.json` (đang chờ dịch).

**Tự bootstrap:** lần chạy đầu tiên, script tự tạo Python venv tại
`./.venv-whisper` (bên trong chính folder tool) và `pip install mlx-whisper`
vào đó — không cần làm gì trước, chỉ cần máy có sẵn `python3`. Đây là bước
**duy nhất không thể chạy qua Docker** (xem "Mức độ độc lập" bên dưới).

### Bước giữa — Dịch sang tiếng Việt (làm qua Claude, không phải script)
Không có model dịch local nào được cài, bước này **phải nhờ Claude** (hoặc 1
LLM khác) dịch nội dung. Trong Claude Code, gọi skill có sẵn:

```
/translate-chunks-vi
```

Skill này tự quét toàn bộ `output/`, dịch cho mọi folder vừa có `chunks.json`
ở bước 1 (bỏ qua folder đã dịch rồi hoặc đã xong `.srt`). Có thể truyền thêm
1 tên folder hoặc 1 file JSON để chỉ xử lý đúng tập đó, ví dụ
`/translate-chunks-vi mastering-agents-md`. Không dùng skill thì cũng có thể
nhờ trực tiếp bằng câu lệnh tương đương, với mỗi folder vừa có `chunks.json`
ở bước 1:

> "Dịch file chunks.json trong folder `<FolderName>` sang tiếng Việt, lưu ra
> vi_translations.json cùng folder đó"

Yêu cầu khi dịch (Claude đã biết các quy tắc này từ trước — cả trong skill
`translate-chunks-vi` lẫn khi nhờ trực tiếp — chỉ nhắc lại để bạn hiểu output
sẽ như thế nào):
- Output là 1 JSON array of string, **cùng độ dài và thứ tự** với `chunks.json`.
- Giữ nguyên tên file/tool/thuật ngữ tiếng Anh (`agents.md`, `Claude Code`,
  `API`, `MCP`, tên sản phẩm...), dịch tự nhiên phần còn lại.
- Có thể sửa lỗi ASR nghe sai dựa vào ngữ cảnh.

### Bước 2 — `02_build_srt.sh`
Ghép `chunks.json` + `vi_translations.json` thành file `.srt` cuối cùng (tên
trùng với video, chỉ đổi đuôi), rồi dọn các file tạm
(`transcript.json`, `chunks.json`, `vi_translations.json`).
Bỏ qua nếu folder đã có `.srt`, hoặc chưa đủ `chunks.json` +
`vi_translations.json`.

### Bước 3 — `03_burn_sub.sh`
Burn (nhúng cứng) `.srt` vào video, tạo ra file mới `<tên>.sub.mp4` cạnh
video gốc — **không sửa/đè file `.mp4` gốc**. Chạy `ffmpeg` qua Docker
(image `jrottenberg/ffmpeg:6-ubuntu`, có `libass`) vì bản `ffmpeg` cài local
qua Homebrew không hỗ trợ filter `subtitles`.
Bỏ qua nếu chưa có `.srt`, hoặc đã có file burned rồi.

## Ví dụ chạy toàn bộ cho 1 bộ JSON

JSON có thể để ở bất kỳ đâu, ví dụ ngoài tool — kết quả vẫn luôn nằm trong
`TranslateVITool/output/`:

```bash
./00_download.sh "/path/to/data-AI-Coder.json"
./01_transcribe_chunk.sh "/path/to/data-AI-Coder.json"
# -> /translate-chunks-vi (dịch chunks.json cho các folder trong ./output được liệt kê)
./02_build_srt.sh "/path/to/data-AI-Coder.json"
./03_burn_sub.sh "/path/to/data-AI-Coder.json"
```

## Ví dụ chạy cho đúng 1 video

```bash
./00_download.sh "https://youtube.com/watch?v=..." "mastering-agents-md" "12. Day 2 - Mastering agents.md"
./01_transcribe_chunk.sh "mastering-agents-md"
# -> /translate-chunks-vi mastering-agents-md
./02_build_srt.sh "mastering-agents-md"
./03_burn_sub.sh "mastering-agents-md"
```

## Mức độ độc lập (self-contained)

Mục tiêu: copy nguyên folder `TranslateVITool/` sang máy khác, đưa 1 file
JSON data vào là chạy được — không cần setup thủ công, không phụ thuộc file
nào ngoài folder này.

**Đã tự chứa hoàn toàn:**
- Bước 0 (download) và bước 3 (burn sub): chạy qua Docker, image tự build
  (`local-yt-dlp`) hoặc tự pull (`jrottenberg/ffmpeg:6-ubuntu`) ở lần chạy
  đầu, định nghĩa sẵn trong `docker-compose.yml` + `docker/`.
- Python venv cho mlx-whisper: tự tạo bên trong `./.venv-whisper` ở lần
  chạy đầu bước 1, không cần venv bên ngoài.
- Bước 2 (build srt): chỉ dùng `python3` thư viện chuẩn, không phụ thuộc gì
  thêm.

**1 giới hạn không loại bỏ được (do phần cứng, không phải do thiết kế tool):**
Bước 1 (transcribe) dùng `mlx-whisper`, bắt buộc chạy **native trên Mac
Apple Silicon** vì nó dùng GPU qua Metal — **không thể chạy trong Docker**
(Docker trên Mac là Linux VM, không có quyền truy cập Metal). Vì vậy máy
chạy bước 1 bắt buộc cần sẵn:
- Máy Mac dùng chip Apple Silicon (M1/M2/M3/...).
- `python3` trên PATH (có sẵn trên macOS, hoặc cài qua Xcode CLT/Homebrew).
- `ffmpeg` trên PATH — không cần bản có `libass`, bản Homebrew thường là đủ,
  vì đây là bản `mlx-whisper` tự gọi để giải mã audio, khác với `ffmpeg` burn
  sub ở bước 3 (chạy trong Docker, không liên quan đến bản cài local).

Nếu đưa tool cho máy không phải Apple Silicon (Windows/Intel Mac/Linux): các
bước 0, 2, 3 vẫn chạy bình thường qua Docker/python3, chỉ riêng bước 1 sẽ
không chạy được — cần transcribe sẵn trên 1 máy Apple Silicon rồi copy
`chunks.json` qua, hoặc đổi sang 1 thư viện Whisper khác chạy CPU/Docker
được (sẽ chậm hơn nhiều, không phải phạm vi tool hiện tại).

**Yêu cầu chung còn lại trên host (không thể bootstrap qua Docker vì bản
thân là CLI điều phối, không phải thứ chạy trong container):**
- `jq` — dùng để parse JSON trong các script, cho cả 4 bước.
- Docker Desktop (hoặc Docker Engine) đã cài và đang chạy.

## Lưu ý

- Không chạy transcribe song song nhiều video cùng lúc — `mlx-whisper` đã
  dùng hết GPU/ANE cho 1 job, chạy nhiều job sẽ chỉ làm chậm lẫn nhau. Các
  script đã xử lý tuần tự (từng video một).
- Burn sub (bước 3) encode lại toàn bộ video nên chậm hơn — cũng chạy tuần
  tự khi dùng chế độ JSON.
- Mọi output trung gian (`transcript.json`, `chunks.json`,
  `vi_translations.json`) đều bị xoá sau bước 2 — chỉ còn lại `.mp4` gốc và
  `.srt` trong mỗi folder, cộng thêm `.sub.mp4` sau bước 3.
