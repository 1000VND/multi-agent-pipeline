# Luật cứng của repo

Ghi các luật bắt buộc của repo này vào đây. Orchestrator đọc file này trước khi plan,
và brief giao cho coding agent phải nhắc lại các luật liên quan.

Cách điền: mỗi luật một gạch đầu dòng, nói rõ làm gì / không được làm gì / cập nhật tài
liệu nào khi đổi hành vi. Ví dụ:

- Không start/stop/restart service production; chỉ sửa source và chạy test an toàn.
- Đổi hành vi thì phải cập nhật tài liệu trong cùng thay đổi.
- Vùng cấm đụng: file secret, dữ liệu thật, thư mục build/cache.
- Không thêm dependency mới khi chưa xin phép.
