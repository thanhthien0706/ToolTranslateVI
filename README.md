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
├── 03b_collect_sub.sh       # (tuỳ chọn) gom video đã sub theo prefix vào <prefix>-concat/
├── 04_concat.sh             # (tuỳ chọn) nối nhiều video trong 1 folder thành 1
├── run_all.sh               # chạy toàn bộ pipeline cho 1 file JSON bằng 1 lệnh
├── group_by_prefix.sh       # gom nhiều folder cùng tiền tố thành 1 folder
├── run_build_srt_all.sh     # chạy bước 2 cho mọi folder con (dùng ngoài repo)
├── docker-compose.yml       # định nghĩa image yt-dlp dùng cho bước 0
├── docker/
│   └── yt-dlp.Dockerfile
├── scripts/                 # 3 python helper, gọi bởi bước 1 và 2
│   ├── transcribe.py
│   ├── make_chunks.py
│   └── build_srt.py
├── output/                  # TẤT CẢ video + srt + file burned nằm ở đây
│   ├── <FolderName>/        # folder 1 video (do bước 0 tạo)
│   │   ├── <name>.mp4
│   │   ├── <name>.srt
│   │   └── <name>.sub.mp4
│   ├── <prefix>-concat/     # 03b_collect_sub.sh: chỉ chứa video đã sub
│   │   ├── 01.mp4, 02.mp4, ...           # hardlink tới <FolderName>/<name>.sub.mp4
│   │   └── <prefix>.full.mp4             # 04_concat.sh <prefix>-concat
│   └── <prefix>/            # folder nhiều video (sau group_by_prefix.sh)
│       ├── 01.mp4, 01.srt, 02.mp4, 02.srt, ...
│       └── sub/
│           ├── 01.mp4, 02.mp4, ...       # 03_burn_sub.sh --group
│           └── <prefix>.full.mp4         # 04_concat.sh <prefix>/sub
├── .venv-whisper/           # tự tạo ở lần chạy đầu bước 1, không commit vào git
└── README.md
```

## Bảng tổng hợp cách chạy

Quy ước tham số:

- `<name>`: tên folder dưới `./output`, ví dụ `w1-d1` nghĩa là
  `./output/w1-d1`. Có thể truyền đường dẫn tuyệt đối (bắt đầu bằng `/`).
- `<data.json>`: file JSON `[{Name, FolderName, Url}]` nằm ở đâu cũng được.
  Script xử lý lần lượt từng `FolderName`.
- Mọi lệnh đều bỏ qua phần việc đã làm xong, nên chạy lại nhiều lần vẫn an
  toàn.

| Lệnh | Tham số | Output | Mô tả |
| --- | --- | --- | --- |
| `./00_download.sh <data.json>` | File JSON | `output/<FolderName>/<Name>.mp4`, lỗi ghi vào `output/<json>.errors.json` | Tải video của mọi entry bằng yt-dlp (chạy trong Docker). Bỏ qua folder đã có `.mp4`. |
| `./00_download.sh <url> <name> [filename]` | URL video, tên folder, tên file (không bắt buộc) | `output/<name>/<filename>.mp4`, nếu bỏ trống thì dùng tiêu đề gốc | Tải đúng 1 video. |
| `./01_transcribe_chunk.sh <name>` | Tên folder | `transcript.json`, `chunks.json` trong folder | Nhận dạng giọng nói bằng mlx-whisper rồi chia thành câu phụ đề ngắn (1 video). |
| `./01_transcribe_chunk.sh <data.json>` | File JSON | Như trên, cho từng folder | Giống trên, chạy hàng loạt. |
| `/translate-chunks-vi [name hoặc data.json]` | Không bắt buộc: tên folder hoặc JSON để giới hạn phạm vi | `vi_translations.json` trong folder | Skill của Claude Code: dịch `chunks.json` sang tiếng Việt. Không truyền gì thì quét toàn bộ `output/`. |
| `./02_build_srt.sh <name>` | Tên folder | `<tên-video>.srt`, đồng thời xoá 3 file JSON tạm | Ghép thời gian và bản dịch thành file `.srt` (1 video). |
| `./02_build_srt.sh <data.json>` | File JSON | Như trên, cho từng folder | Giống trên, chạy hàng loạt. |
| `./03_burn_sub.sh <name>` | Tên folder | `<tên-video>.sub.mp4` cạnh video gốc | Burn phụ đề vào video, chỉ lấy file `.srt` **đầu tiên** trong folder. |
| `./03_burn_sub.sh <data.json>` | File JSON | Như trên, cho từng folder | Giống trên, chạy hàng loạt. |
| `./03_burn_sub.sh --group <name>` | `--group` (đặt trước hoặc sau đều được), tên folder | `<name>/sub/<x>.mp4` cho mỗi cặp `<x>.mp4/<x>.srt` | Burn **tất cả** các cặp trong folder nhiều video (ví dụ folder đã gộp). Chuyển file `<x>.sub.mp4` kiểu cũ vào `sub/`. |
| `./03_burn_sub.sh --group <data.json>` | `--group`, file JSON | Như trên, cho từng folder | Giống trên, chạy hàng loạt. |
| `BURN_QUALITY=<1-100> ./03_burn_sub.sh ...` | Biến môi trường, đi kèm bất kỳ lệnh bước 3 nào | Như lệnh gốc | Đổi chất lượng encode (mặc định 40; cao hơn thì nét hơn và file to hơn). |
| `./03b_collect_sub.sh <data.json> '<regex>'` | File JSON, regex khớp đầu `FolderName` (ví dụ `'^w\d+-d\d+'`) | `output/<prefix>-concat/<NN>.mp4` | Gom các `<name>.sub.mp4` của từng entry vào 1 folder cho mỗi prefix, đánh số theo số đứng sau prefix. Dùng hardlink (không tốn thêm dung lượng, folder nguồn giữ nguyên), không ghi đè, liệt kê video chưa burn. |
| `./run_all.sh <data.json> [--prefix '<regex>'] [--concat] [--from <bước>]` | File JSON và các tuỳ chọn | Như các bước bên dưới | Chạy toàn bộ pipeline bằng 1 lệnh, xem mục "Chạy tất cả bằng 1 lệnh". |
| `./04_concat.sh <name>` | Tên folder (ví dụ `w1-d1/sub`, `w1-d1-concat` hoặc `w1-d1`) | `<name>/<tên-folder>.full.mp4` (folder `sub` lấy tên folder cha, folder `<x>-concat` bỏ hậu tố `-concat`), mỗi phần là 1 chapter | Nối **mọi `.mp4`** trong folder đó thành 1 video dài, theo thứ tự tên file. Cần từ 2 video trở lên. |
| `./04_concat.sh <data.json>` | File JSON | Như trên, cho từng folder khác nhau | Giống trên, mỗi folder chỉ xử lý 1 lần. Lưu ý: JSON trỏ tới folder 1 video thì sẽ không có gì để nối. |
| `./group_by_prefix.sh '<regex>'` | Regex khớp tiền tố tên folder, ví dụ `'^w1-d1'` | `output/<prefix>/<NN>.<ext>`, trường hợp không rõ ràng ghi vào `output/group-by-prefix.errors.json` | Gom các folder `<prefix>-<NN>-slug` vào 1 folder chung và đổi tên file theo số thứ tự `<NN>`. |
| `./run_build_srt_all.sh` | Không có | `.srt` trong từng folder con | Chạy `02_build_srt.sh` cho mọi folder con **của thư mục chứa script này**. Dùng khi copy script sang thư mục video khác, không chạy trong repo. |

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
video gốc — **không sửa/đè file `.mp4` gốc**. Chạy `ffmpeg` native, mã hóa
bằng bộ encode phần cứng của Apple (`h264_videotoolbox`) nên CPU gần như
rảnh, máy không bị nóng. Chất lượng mặc định `-q:v 40` (thang 1–100, cao
hơn = nét hơn/file to hơn), đổi bằng `BURN_QUALITY=<n> ./03_burn_sub.sh ...`.
Lưu ý: encoder phần cứng nén kém hơn x264, nên với video quay màn hình
bitrate thấp, file `.sub.mp4` có thể to gấp ~2–3 lần file gốc.
Cần bản `ffmpeg` có `libass` (filter `subtitles`) — bản `ffmpeg` Homebrew
thường **không có**, nên cài thêm `ffmpeg-full` (keg-only, không đè bản
`ffmpeg` thường mà bước 1 dùng):

```bash
brew install ffmpeg-full
```

Script tự tìm theo thứ tự: biến `FFMPEG=/path/to/ffmpeg` → `ffmpeg-full`
của Homebrew → `ffmpeg` trên PATH (nếu có `subtitles`). File được ghi ra
`<tên>.sub.partial.mp4` rồi mới đổi tên khi thành công, nên nếu bị ngắt giữa
chừng thì lần chạy sau sẽ burn lại chứ không bỏ qua nhầm.
Bỏ qua nếu chưa có `.srt`, hoặc đã có file burned rồi.

Mặc định mỗi folder chỉ burn file `.srt` đầu tiên (1 video/folder, đúng cấu
trúc bước 0 tạo ra). Với folder chứa nhiều video — ví dụ folder đã gộp bằng
skill `group-by-prefix` (`01.mp4/01.srt`, `02.mp4/02.srt`, ...) — thêm tham
số `--group` để burn **tất cả** các cặp `<x>.srt`/`<x>.mp4` trong folder:

```bash
./03_burn_sub.sh --group "w1-d1"
./03_burn_sub.sh --group "/path/to/data.json"
```

Ở chế độ `--group`, video đã burn được đưa vào folder con `sub/` (giữ nguyên
tên file gốc) thay vì nằm cạnh video gốc:

```
w1-d1/01.mp4  ->  w1-d1/sub/01.mp4
w1-d1/02.mp4  ->  w1-d1/sub/02.mp4
```

Từng video được bỏ qua riêng nếu đã có `sub/<x>.mp4` hoặc thiếu `.mp4` khớp
tên, và phần Summary đếm theo từng video. Nếu folder còn file `<x>.sub.mp4`
kiểu cũ (burn trước khi có `sub/`), script **chuyển** nó vào `sub/<x>.mp4`
chứ không burn lại.

### Bước 4 (tuỳ chọn) — `04_concat.sh`
Nối **mọi file `.mp4` trong folder được truyền vào** thành 1 video dài, theo
thứ tự tên file (`01`, `02`, ...), kèm chapter marker cho từng phần (trình
phát như QuickTime/VLC/IINA hiện mục lục để nhảy giữa các phần). Script không
phân biệt video gốc hay video đã có sub: truyền folder nào thì nối đúng các
video trong folder đó (không tính folder con).

```bash
./04_concat.sh "w1-d1/sub"   # nối các video đã burn sub -> output/w1-d1/sub/w1-d1.full.mp4
./04_concat.sh "w1-d1"       # nối các video gốc         -> output/w1-d1/w1-d1.full.mp4
```

- Tên output là `<tên-folder>.full.mp4`, nằm trong chính folder đó. Riêng
  folder tên `sub` thì lấy tên folder cha (`w1-d1/sub` → `w1-d1.full.mp4`),
  folder `<x>-concat` bỏ hậu tố (`w1-d1-concat` → `w1-d1.full.mp4`).
- Các phần cùng định dạng được nối bằng stream copy: **không mã hoá lại**,
  vài giây là xong, gần như không tốn CPU. Nếu khác định dạng (ví dụ có phần
  720p lẫn với phần 1080p) thì tự chuyển sang mã hoá lại bằng
  `h264_videotoolbox`, scale theo kích thước phần đầu tiên. Khi đó thời gian
  chạy gần bằng burn sub cả folder.
- Bỏ qua folder có ít hơn 2 video, hoặc đã có `.full.mp4`. Ghi ra
  `.full.partial.mp4` rồi mới đổi tên khi thành công.
- Nhận cả `<data.json>`: mỗi folder khác nhau chỉ xử lý 1 lần.

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

## Chạy tất cả bằng 1 lệnh — `run_all.sh`

```bash
./run_all.sh "data/w1-d1.json"                                   # bước 0 → 3
./run_all.sh "data/w1-d1.json" --prefix '^w\d+-d\d+'              # + gom vào w1-d1-concat/
./run_all.sh "data/w1-d1.json" --prefix '^w\d+-d\d+' --concat     # + nối thành 1 video (hỏi trước)
./run_all.sh "data/w1-d1.json" --from burn --prefix '^w\d+-d\d+'  # bắt đầu từ bước burn
```

Thứ tự chạy: `download` (00) → `transcribe` (01) → `translate` → `srt` (02)
→ `burn` (03) → `collect` (03b, chỉ khi có `--prefix`) → `concat` (04, chỉ
khi có `--concat`).

- **translate**: gọi Claude Code headless
  (`claude -p "/translate-chunks-vi <folder>"`), **mỗi folder 1 lần gọi** để
  context không phình to khi batch dài. Claude chỉ được dùng các tool đọc/ghi
  file. Sau mỗi lần gọi, script tự kiểm tra `vi_translations.json` có đúng số
  dòng với `chunks.json` không. Nếu sai, file được đổi tên thành
  `vi_translations.invalid.json` và entry đó được ghi vào
  `output/<json>.errors.json` với `Step: "translate"`. Mỗi lần dịch tốn usage
  Claude. Biến môi trường: `CLAUDE_BIN` (mặc định `claude`),
  `TRANSLATE_MODEL` (truyền `--model` cho lần gọi dịch).
- **collect**: xem `03b_collect_sub.sh` trong bảng tổng hợp. Video nào chưa
  burn xong thì được liệt kê là `missing`, folder `-concat` khi đó còn thiếu
  phần.
- **concat**: trước khi chạy, script liệt kê các folder `-concat` cùng các
  phần trong từng folder, rồi **dừng lại hỏi `[y/N]`**. Không có terminal để
  hỏi (ví dụ chạy qua pipe/cron) thì bỏ qua và in sẵn lệnh `04_concat.sh` để
  chạy tay. Lưu ý: folder đã có `.full.mp4` sẽ không nối lại. Nếu sau đó có
  thêm phần mới, cần xoá `.full.mp4` cũ trước.
- Một entry lỗi không làm dừng cả batch. Cuối cùng script tóm tắt các bước
  có lỗi. Chạy lại đúng lệnh cũ thì các bước tự bỏ qua phần đã xong.

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
- Bước 0 (download): chạy qua Docker, image `local-yt-dlp` tự build ở lần
  chạy đầu, định nghĩa sẵn trong `docker-compose.yml` + `docker/`.
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
  vì đây là bản `mlx-whisper` tự gọi để giải mã audio.

Bước 3 (burn sub) cũng chạy native trên macOS: cần `ffmpeg-full` (có
`libass`) và encoder `h264_videotoolbox` (chỉ có trên macOS) — xem mục
"Bước 3" ở trên.

Nếu đưa tool cho máy không phải Mac (Windows/Linux): bước 0, 2 vẫn chạy
bình thường qua Docker/python3, còn bước 1 và 3 sẽ không chạy được — cần
transcribe và burn sub trên 1 máy Mac (bước 1 cần Apple Silicon), hoặc copy
`chunks.json` qua, hoặc đổi sang 1 thư viện Whisper khác chạy CPU/Docker
được (sẽ chậm hơn nhiều, không phải phạm vi tool hiện tại).

**Yêu cầu chung còn lại trên host (không thể bootstrap qua Docker vì bản
thân là CLI điều phối, không phải thứ chạy trong container):**
- `jq` — dùng để parse JSON trong các script, cho cả 4 bước.
- Docker Desktop (hoặc Docker Engine) đã cài và đang chạy — chỉ cần cho
  bước 0.
- `ffmpeg-full` (Homebrew) — chỉ cần cho bước 3.

## Lưu ý

- Không chạy transcribe song song nhiều video cùng lúc — `mlx-whisper` đã
  dùng hết GPU/ANE cho 1 job, chạy nhiều job sẽ chỉ làm chậm lẫn nhau. Các
  script đã xử lý tuần tự (từng video một).
- Burn sub (bước 3) encode lại toàn bộ video nên chậm hơn — cũng chạy tuần
  tự khi dùng chế độ JSON.
- Mọi output trung gian (`transcript.json`, `chunks.json`,
  `vi_translations.json`) đều bị xoá sau bước 2 — chỉ còn lại `.mp4` gốc và
  `.srt` trong mỗi folder, cộng thêm `.sub.mp4` sau bước 3.
