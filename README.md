# multi-agent-pipeline

Not affiliated with Anthropic or OpenAI.

Gói tooling cho vòng lặp **Claude plan → giao task cho OpenCode hoặc Codex → Claude review**.
Gói chỉ chứa tooling; không chứa code của dự án nào.

## Yêu cầu

Gói **chỉ chạy trên Windows**: toàn bộ là Windows PowerShell 5.1, có dùng `taskkill /T /F`,
`Start-Process`, và đường dẫn `%USERPROFILE%\.codex\sessions`.

- Windows PowerShell 5.1 (`install.ps1` cảnh báo nếu không phải bản này)
- git
- `codex` trong PATH và **đã đăng nhập** — cần cho lane Codex
- `opencode` trong PATH — cần cho lane OpenCode
- python hoặc runtime test của dự án — tùy `test_command`

`install.ps1` in báo cáo `== DIEU KIEN CHAY ==` với OK/THIEU cho từng thứ; thiếu thì không
fail, chỉ báo lane nào không dùng được.

## Cài đặt

```powershell
git clone https://github.com/1000VND/multi-agent-pipeline.git
cd multi-agent-pipeline
.\install.ps1 -Target <duong-dan-repo-dich>
```

`<repo-dich>` phải là git repo (chạy `git init` trước nếu chưa). Install chạy lại được
nhiều lần: lần sau chỉ cập nhật phần code, giữ nguyên `pipeline.config.json` và
`state.json`. Thêm `-Force` nếu muốn đè cả file dữ liệu — khi đó install in rõ từng file
bị đè.

### -NoGitTrack

Dùng khi repo đích đã commit `.claude/` và bạn không muốn file của pipeline hiện trong
`git status` hay bị push lên remote chung:

```powershell
.\install.ps1 -Target <duong-dan-repo-dich> -NoGitTrack
```

Cờ này ghi `.gitignore` chứa đúng một dòng `*` vào `.pipeline/`, `.claude/agents/` và
`.claude/skills/pipeline/`. Ba file đó tự ignore chính nó nên không được commit: clone
repo đích ở máy khác là mất, phải chạy lại `install.ps1 -NoGitTrack`.

Giới hạn: nó giấu **cả thư mục** với git, không chỉ file của gói. Nếu team có agent riêng
trong `.claude/agents/`, file **mới chưa tracked** của họ cũng biến mất khỏi `git status`
và dễ bị quên commit; file đã tracked từ trước vẫn tracked bình thường.

Đây **không** phải hàng rào chống đồng nghiệp lỡ tay commit. Muốn vậy phải thêm rule vào
`.gitignore` gốc của repo đích và chấp nhận diff của chính rule đó.

## Cây thư mục sau khi cài

```
<repo>/
├── .claude/
│   ├── agents/oc-coder.md, codex-coder.md
│   └── skills/pipeline/SKILL.md
└── .pipeline/
    ├── bin/oc-run.ps1, oc-tui.ps1, codex-run.ps1
    ├── logs/
    ├── tasks/_TEMPLATE.md
    ├── pipeline.config.json
    ├── state.json
    ├── PROJECT_RULES.md
    └── .gitignore
```

`.claude/agents` và `.claude/skills/pipeline/SKILL.md` phải nằm đúng vị trí đó theo quy
định của Claude Code; runner và state nằm gọn trong `.pipeline/`.

## Chạy một task

Giao một task cho coder bằng một trong hai runner (chạy trong repo đích):

```powershell
powershell -NoProfile -File .pipeline\bin\oc-run.ps1    -TaskFile .pipeline\tasks\<id>.md
powershell -NoProfile -File .pipeline\bin\codex-run.ps1 -TaskFile .pipeline\tasks\<id>.md
```

`-Resume` vẫn dùng được cho lượt sửa lỗi tương thích với luồng cũ; bình thường runner Codex
tự nối lại thread đã gắn với phiên Claude hiện tại. Brief phải **tự chứa** vì coder không
thấy hội thoại này. Chi tiết quy trình nằm trong `SKILL.md` mà Claude đọc.

## pipeline.config.json

| Khóa | Ý nghĩa |
|---|---|
| `project_name` | Tên repo; install tự điền theo tên thư mục đích. |
| `test_command` | Lệnh test toàn bộ; runner tự chạy khi coder có thay đổi file. Để trống thì runner không chạy gì và in `TESTS: khong co test_command trong .pipeline/pipeline.config.json - bo qua` — hành vi có chủ đích, không phải lỗi. |
| `test_command_targeted` | Lệnh test mục tiêu; orchestrator dùng khi review. |
| `timeout_sec` | Timeout mặc định cho mỗi lượt runner (giây). |
| `forbidden_paths` | Vùng cấm đụng; brief giao coder phải nhắc lại. |
| `rules_docs` | Danh sách tài liệu luật của repo (tùy chọn). |
| `model_policy` | Chính sách model của hai lane (xem dưới). |

Ưu tiên khi chạy runner: **tham số dòng lệnh > config > mặc định built-in**. Thiếu file
hoặc file hỏng thì runner in `CONFIG: khong doc duoc .pipeline/pipeline.config.json` và
chạy tiếp bằng mặc định built-in, không fail.

## Hai lane và chính sách model

| Lane | Mặc định | Leo thang |
|---|---|---|
| OpenCode | `opencode-go/deepseek-v4.1-flash` + `--variant max`, fallback `opencode-go/mimo-v2.5-pro` | (không đổi) |
| Codex | `gpt-5.6-luna` + `model_reasoning_effort=xhigh` | `gpt-5.6-terra` + `model_reasoning_effort=high` |

Cấm dùng `gpt-5.6-sol` và `gpt-6-astra` để implement code; runner Codex chặn cứng bằng
`exit 2`. Thang leo bậc và luật worktree sạch nằm trong `SKILL.md`.

## Lane Codex

- Mỗi phiên Claude dùng đúng **một Codex thread**. Runner tự resume thread này ở task
  sau và đóng TUI pipeline cũ của repo trước khi mở TUI mới, nên không tích nhiều cửa sổ Codex.
  Dùng `-FreshSession` khi cần chủ động tạo thread mới.
- `-Exec` hoặc `-NoTui` chạy headless, không mở cửa sổ nào.
- TUI cần thư mục repo nằm trong danh sách tin cậy của Codex (`~/.codex/config.toml`, mục
  `[projects.'...']` với `trust_level = "trusted"`). Thư mục lạ thì TUI chặn lại hỏi xác
  nhận, runner chỉ biết chờ tới timeout. Cách mồi: chạy một lượt `-NoTui` nhỏ trong repo
  đó trước — lượt headless tự đăng ký tin cậy.
- Log JSONL nằm trong `.pipeline/logs/`: chế độ TUI sao chép rollout của Codex thành
  `<task>-<tag>-native.jsonl`; chế độ headless ghi `<task>-<tag>-codex.jsonl` cộng `.err`
  cho stderr.

## Mã thoát

| Mã | Nghĩa |
|---|---|
| 0 | xong, có thay đổi file |
| 2 | không phải git repo / không thấy task file / model bị cấm |
| 3 | worktree bẩn (chỉ lượt không `-Resume`) |
| 4 | thiếu Codex CLI, hoặc không có thread đã lưu để `-Resume` (chỉ lane Codex) |
| 5 | lượt này không sửa gì — coi như thất bại |
| 6 | `oc-tui.ps1` không trả về session id (chỉ lane OpenCode) |
| 7 | CLI hỏng cứng, không phải model từ chối task |
| 8 | có thay đổi nhưng `test_command` fail |
| 9 | phiên opencode thuộc repo khác — chặn để khỏi sửa nhầm dự án (chỉ lane OpenCode) |
| 124 | quá `timeout_sec`. Lane Codex: `codex-run.ps1` giết cả cây tiến trình rồi thoát 124. Lane OpenCode: in `TIMEOUT` và báo `exit=124` trong tóm tắt, còn mã thoát cuối theo kết quả (5/0/8). |

## Lưu ý

- Lane OpenCode tự tìm server riêng của từng repo trong dải cổng `4096-4105`, nên chạy
  nhiều repo song song thì mỗi repo chiếm một cổng trong dải đó.
- Nếu runner in `BLOCKED: phien opencode dang o '<duong dan>'` thì phiên opencode đang
  thuộc repo khác — dùng `-NoTui`, hoặc đóng server đang chiếm cổng, rồi chạy lại. Lỗi
  này từng làm coder sửa nhầm sang một dự án khác nên chốt chặn cố ý `exit 9` (chặn hẳn
  thay vì cảnh báo).

## Cập nhật

```powershell
git pull
.\install.ps1 -Target <duong-dan-repo-dich>
```

Phần code trong `.pipeline/bin`, `.claude/agents`, `.claude/skills/pipeline` được copy đè;
`pipeline.config.json`, `state.json`, `PROJECT_RULES.md`, `tasks/_TEMPLATE.md` và
`.pipeline/.gitignore` giữ nguyên trừ khi chạy `-Force`.
