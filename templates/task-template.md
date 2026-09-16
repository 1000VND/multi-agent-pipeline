# <ID>: <tiêu đề ngắn>

## Bối cảnh
<2-5 câu: hệ thống này là gì, phần cần sửa nằm ở đâu, hiện đang hoạt động thế nào>

## Việc cần làm
<Cụ thể. Nêu tên hàm / endpoint / class thật. Không mô tả chung chung.>

## File được phép sửa
- <path/to/file>
- <path/to/test_file>
- <path/to/doc.md>

## File CẤM đụng vào
- Mọi file không có trong danh sách trên
- <các vùng cấm đụng của repo này, ví dụ: `.env`, thư mục dữ liệu, file cấu hình dùng chung>

## Luật bắt buộc của repo
- Chép lại các luật trong `.pipeline/PROJECT_RULES.md` của repo này vào đây; coder không đọc được file đó nếu brief không nhắc.
- <các luật cứng khác của repo, ví dụ: không start/stop/rebuild service, không đụng dữ liệu production>

## Quy ước phải theo
<Dẫn file mẫu cụ thể trong repo, ví dụ: "theo pattern logging như trong <path/to/file> hàm
<ten_ham>", "theo cách viết test như <path/to/test_file>">

## Tiêu chí chấp nhận
- [ ] `<test_command trong .pipeline/pipeline.config.json>` pass
- [ ] Chạy full suite vẫn >= <BASELINE> test, không có FAIL/ERROR (điền <BASELINE> = số test đo được TRƯỚC khi giao task, đừng hardcode — nó đổi theo commit)
- [ ] <hành vi quan sát được>

## Không làm
- Không refactor ngoài phạm vi
- Không sửa, xoá, hay skip test có sẵn để cho pass
- Không đổi format log / schema DB nếu task không yêu cầu
