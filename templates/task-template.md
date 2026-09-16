# <ID>: <tiêu đề ngắn>

## Bối cảnh
<2-5 câu. Hệ thống Jellyfin LAN: stack Docker (Jellyfin + downloader Flask + Nginx gateway).
Phần cần sửa nằm ở đâu, hiện đang hoạt động thế nào.>

## Việc cần làm
<Cụ thể. Nêu tên hàm / endpoint / class thật. Không mô tả chung chung.>

## File được phép sửa
- downloader/<file>.py
- downloader/test_<file>.py
- docs/<doc>.md

## File CẤM đụng vào
- Mọi file không có trong danh sách trên
- `.env`, `config/`, `cache/`, `logs/`, `state/`
- `docker-compose.yml`, `Dockerfile` (trừ khi được liệt kê ở trên)

## Luật bắt buộc của repo
- KHÔNG start/stop/restart/rebuild/reset Docker service. Không chạy `docker compose` gì cả.
- Đổi hành vi thì phải cập nhật tài liệu trong `docs/` ở cùng thay đổi này.
- Không lưu URL media / cookie / header bắt từ browser vào database.
- Không làm yếu kiểm tra SSRF / DRM / cookie boundary.
- Không thêm package vào `downloader/requirements.txt`.
- Test phải dùng fixture / temp directory, không đụng dữ liệu production.

## Quy ước phải theo
<Dẫn file mẫu cụ thể trong repo, ví dụ: "theo pattern logging JSON như trong
downloader/app.py hàm _log_event", "theo cách viết test như downloader/test_permissions.py">

## Tiêu chí chấp nhận
- [ ] `python -m unittest discover -s downloader -p "test_<module>.py" -v` pass
- [ ] `python -m unittest discover -s downloader -p "test_*.py"` vẫn >= <BASELINE> test, không có FAIL/ERROR (điền <BASELINE> = số test đo được TRƯỚC khi giao task, đừng hardcode — nó đổi theo commit)
- [ ] <hành vi quan sát được>

## Không làm
- Không refactor ngoài phạm vi
- Không sửa, xoá, hay skip test có sẵn để cho pass
- Không đổi format log / schema DB nếu task không yêu cầu
