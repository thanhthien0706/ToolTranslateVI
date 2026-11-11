---
name: group-by-prefix
description: Gom các folder trong output/ có cùng tiền tố (match bởi regex do người dùng truyền vào) thành 1 folder chung, đổi tên file trong từng folder nguồn thành <số-thứ-tự>.<ext> dựa trên số đứng ngay sau prefix. Dùng khi muốn gộp nhiều bài/video cùng ngày (w1-d1-01-..., w1-d1-02-...) vào 1 folder w1-d1/ duy nhất. Idempotent — tình huống không rõ ràng (thiếu số thứ tự, trùng số, đích đã có file) được ghi ra output/group-by-prefix.errors.json và giữ nguyên folder nguồn, không tự suy đoán hay đè file.
---

# Gom nhóm folder trong output/ theo prefix

Gọi: `/group-by-prefix <regex>`, ví dụ:
```
/group-by-prefix ^w\d+-d\d+
```

Logic gom nhóm/move/rename nằm trong `scripts/group_by_prefix.py` (stdlib
python3, không phụ thuộc gì thêm), gọi qua wrapper `group_by_prefix.sh` ở gốc
tool. Việc này cần làm chính xác tuyệt đối (sai 1 bước là mất/đè dữ liệu
video), nên để script quyết định theo đúng luật cố định dưới đây, không nhờ
agent tự gõ `mv` theo cảm tính.

## Việc cần làm khi skill này được gọi

1. Lấy `<regex>` người dùng truyền vào — bắt buộc, nếu không có thì hỏi lại
   trước khi chạy gì cả.
2. Chạy từ gốc repo: `./group_by_prefix.sh '<regex>'`
3. Đọc output của script: số group tìm được, số file đã move, số folder
   nguồn đã gom sạch và bị xoá, số folder bị giữ nguyên vì có lỗi.
4. Nếu `output/group-by-prefix.errors.json` tồn tại sau khi chạy, đọc và
   tóm tắt từng lỗi cho người dùng (folder nào, file nào, lý do gì). Không
   tự sửa gì cả — người dùng sẽ xử lý tay các trường hợp này.
5. Báo cáo ngắn gọn kết quả.

## Quy tắc gom nhóm (đã code cứng trong script, mô tả lại để biết điều gì xảy ra)

- `<regex>` được match ở **đầu** tên mỗi folder nằm trực tiếp dưới
  `output/`. Folder không khớp → bỏ qua hoàn toàn, không đụng tới.
- Phần khớp được là **tên group**, cũng là tên folder chung tạo dưới
  `output/<group>/`.
- Phần còn lại của tên folder sau prefix (bỏ dấu `-`, `_`, `.`, khoảng
  trắng ở đầu) phải bắt đầu bằng số — đó là **số thứ tự**, giữ nguyên định
  dạng gốc (`02` giữ số 0 ở đầu, không rút gọn thành `2`). Không tìm được
  số nào → ghi lỗi, giữ nguyên folder, không đụng file nào trong đó.
- Hai folder trong cùng 1 group ra cùng số thứ tự → xung đột, ghi lỗi cho cả
  hai, giữ nguyên cả hai.
- Với mỗi file trong 1 folder nguồn hợp lệ (bỏ qua `.DS_Store`): đuôi file =
  phần từ dấu `.` **đầu tiên** trong tên file trở đi (vd `name.sub.mp4` →
  `.sub.mp4`), tên file mới = `<số-thứ-tự><đuôi>`, move vào
  `output/<group>/`.
- File đích đã tồn tại sẵn (chạy lại skill, hoặc trùng số) → **không ghi
  đè, không move** — ghi lỗi, để file nguồn nằm nguyên tại chỗ.
- 1 folder nguồn chỉ bị xoá khi **toàn bộ** file trong đó move thành công,
  không lỗi gì (`.DS_Store` còn sót cũng bị dọn luôn khi đó). Có bất kỳ lỗi
  nào xảy ra với 1 file trong folder → cả folder đó được giữ nguyên (file
  khác trong cùng folder đã move trước lúc gặp lỗi thì vẫn đã move — trạng
  thái dở này thể hiện rõ qua các entry lỗi tương ứng để biết đường xử lý
  tay).

## File báo lỗi

`output/group-by-prefix.errors.json` — ghi lại ở mỗi lần chạy, mỗi phần tử:
`Folder`, `Group`, `File` (null nếu lỗi ở cấp folder, không phải 1 file cụ
thể), `Step: "group-by-prefix"`, `Error`. Lần chạy hiện tại không có lỗi
nào → file này bị xoá nếu còn sót từ lần chạy trước, để không báo lỗi cũ đã
hết tác dụng.

## Lưu ý

- Không tự chạy lại nhiều lần liên tiếp mong lỗi "tự hết" — lỗi được ghi ra
  vì tình huống không đủ rõ để script tự quyết (thiếu số thứ tự, trùng số,
  hoặc đích đã có file); cần sửa tên folder / dọn file trùng tay trước khi
  chạy lại.
- Script chỉ xử lý folder nằm **trực tiếp** dưới `output/`, không đệ quy
  vào folder con.
