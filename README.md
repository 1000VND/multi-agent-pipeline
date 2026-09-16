# claude-pipeline

Not affiliated with Anthropic or OpenAI.

Gói tooling cho vòng lặp **Claude plan → giao task cho OpenCode hoặc Codex → Claude review**.
Gói chỉ chứa tooling; không chứa code của dự án nào.

## Cài đặt

```powershell
git clone <repo-goi-nay>
cd claude-pipeline
.\install.ps1 -Target <duong-dan-repo-dich>
```

`<repo-dich>` phải là git repo (chạy `git init` trước nếu chưa). Install chạy lại được
nhiều lần: lần sau chỉ cập nhật phần code, giữ nguyên `pipeline.config.json` và
`state.json`. Thêm `-Force` nếu muốn đè cả file dữ liệu — khi đó install in rõ từng file
bị đè.

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

## pipeline.config.json

| Khóa | Ý nghĩa |
|---|---|
| `project_name` | Tên repo; install tự điền theo tên thư mục đích. |
| `test_command` | Lệnh test toàn bộ; runner tự chạy khi coder có thay đổi file. |
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

## Lưu ý

- Lane OpenCode tự tìm server riêng của từng repo trong dải cổng `4096-4105`, nên chạy
  nhiều repo song song thì mỗi repo chiếm một cổng trong dải đó.

## Cập nhật

```powershell
git pull
.\install.ps1 -Target <duong-dan-repo-dich>
```

Phần code trong `.pipeline/bin`, `.claude/agents`, `.claude/skills/pipeline` được copy đè;
`pipeline.config.json`, `state.json`, `PROJECT_RULES.md`, `tasks/_TEMPLATE.md` và
`.pipeline/.gitignore` giữ nguyên trừ khi chạy `-Force`.
