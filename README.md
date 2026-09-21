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
nhiều lần: lần sau cập nhật phần code, giữ nguyên `state.json` và các field riêng của
`pipeline.config.json`. Schema fallback OpenCode được tự migrate và setting
`session_rollover.context_percent` được bổ sung nếu chưa có. Thêm `-Force` nếu muốn đè cả file dữ liệu — khi đó install in rõ
từng file bị đè.

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
| OpenCode | `opencode-go/deepseek-v4.1-flash` + `--variant max` | fallback theo chuỗi bên dưới |
| Codex | `gpt-5.6-luna` + `model_reasoning_effort=xhigh` | `gpt-5.6-terra` + `model_reasoning_effort=high` |

Cấm dùng `gpt-5.6-sol` và `gpt-6-astra` để implement code; runner Codex chặn cứng bằng
`exit 2`. Thang leo bậc và luật worktree sạch nằm trong `SKILL.md`.

### Fallback OpenCode

Nếu lượt trước không tạo thay đổi file, runner lần lượt thử: **DeepSeek V4 Flash**
(`max`) → **DeepSeek V4 Flash Vision Exp** (`max`) → **MiMo V2.5 Pro** (không có
variant) → **LongCat-2.0** (`high`) → **Qwen3.8 Flash** (`xhigh`).

Nếu primary DeepSeek V4.1 Flash báo hết quota/rate limit hoặc model không khả dụng, runner
đổi thứ tự để ưu tiên phương án rẻ hơn trước: **Qwen3.8 Flash** (`xhigh`) →
**LongCat-2.0** (`high`) → **MiMo V2.5 Pro** → **DeepSeek V4 Flash Vision Exp** (`max`)
→ **DeepSeek V4 Flash** (`max`).
Runner dừng chuỗi khi một model đã sửa file, timeout, hoặc lỗi tham số CLI.

## Lane Codex

- Mỗi phiên Claude có **một Codex thread đang hoạt động**. Runner tự resume thread này ở task
  sau và đóng TUI pipeline cũ của repo trước khi mở TUI mới, nên không tích nhiều cửa sổ Codex.
  Dùng `-FreshSession` khi cần chủ động tạo thread mới.
- Danh tính phiên lấy theo thứ tự `-Key`, `CLAUDE_CODE_HOST_SESSION_ID`,
  `CLAUDE_CODE_SESSION_ID`. Thiếu cả ba thì runner in `BLOCKED:` và thoát `11` thay vì
  gộp các lần chạy khác nhau vào một key chung (không còn key `no-claude-session`).
- Bản đồ TUI lưu cả PID lẫn thời điểm khởi động của tiến trình; runner chỉ đóng TUI khi
  PID còn sống, đúng tên `codex` và đúng thời điểm khởi động. Bản ghi cũ thiếu thời điểm
  khởi động bị bỏ qua (cửa sổ cũ có thể còn mở) thay vì giết nhầm PID đã bị tái sử dụng.
- Mỗi repo chỉ chạy một `codex-run.ps1` tại một thời điểm nhờ **run lock** theo repo
  (`.pipeline/logs/codex-run.lock`, đã ignore). Lượt chồng lên thoát ngay với
  `BLOCKED: ... (PID ...)` và không đụng TUI của lượt đang chạy; lock của tiến trình
  đã chết được tự thu hồi. Không giành được lock vì lý do khác cũng `exit 10` — runner
  không bao giờ chạy khi thiếu lock.
- Nếu không đóng được TUI cũ đã quản lý, runner dừng với `exit 10` thay vì mở thêm
  TUI. Khi timeout mà `taskkill` không giết được Codex, lock được chuyển sang PID
  Codex còn sống; các lượt sau vẫn bị chặn đến khi tiến trình đó tự kết thúc hoặc được
  người dùng đóng thủ công.
- `-Exec` hoặc `-NoTui` chạy headless, không mở cửa sổ nào.
  Nếu đã có thread, runner in `TUI: codex resume <thread-id>` để mở lại đúng phiên;
  lượt tạo thread mới sẽ in lệnh này ngay khi Codex trả về thread ID.
- TUI cần thư mục repo nằm trong danh sách tin cậy của Codex (`~/.codex/config.toml`, mục
  `[projects.'...']` với `trust_level = "trusted"`). Thư mục lạ thì TUI chặn lại hỏi xác
  nhận, runner chỉ biết chờ tới timeout. Cách mồi: chạy một lượt `-NoTui` nhỏ trong repo
  đó trước — lượt headless tự đăng ký tin cậy.
- Log JSONL nằm trong `.pipeline/logs/`: chế độ TUI sao chép rollout của Codex thành
  `<task>-<tag>-native.jsonl`; chế độ headless ghi `<task>-<tag>-codex.jsonl` cộng `.err`
  cho stderr.

## Context và lịch sử session

Cả hai lane kiểm tra context trước khi giao lượt mới. Nếu context **vượt 80%**, runner
tạo session mới gắn với cùng khóa Claude rồi gửi brief vào session mới. Đúng 80% vẫn
dùng tiếp. Với OpenCode, kiểm tra cũng chạy trước lượt fallback. Task đang chạy không
bị ngắt giữa chừng; session mới đọc brief và file của repo, không tự sao chép toàn bộ
hội thoại cũ. Vì vậy brief sửa lỗi cần ghi đủ tiến độ và việc còn lại.

Ngưỡng có thể chỉnh bằng số nguyên 1–99 trong `.pipeline/pipeline.config.json`
(thiếu hoặc giá trị không hợp lệ thì dùng 80):

```json
"session_rollover": { "context_percent": 80 }
```

Runner dùng usage của request gần nhất và context window do CLI/server cung cấp.
Tổng token đã tiêu thụ suốt session không dùng làm context. Khi không đọc được usage
hoặc context window, runner in `CONTEXT:` giải thích và giữ session hiện tại.

Mỗi khóa Claude giữ session đang hoạt động và danh sách **tất cả session đã liên kết**:

| File | Session hiện tại | Lịch sử |
|---|---|---|
| `.pipeline/codex-map.json` | `codex_thread` | `codex_sessions[]` |
| `.pipeline/tui-map.json` | `opencode_session` | `opencode_sessions[]` |

Mỗi mục lịch sử lưu ID, thời điểm ghi nhận/sử dụng và thông tin chuyển phiên khi có.
Map cũ được nhập vào danh sách khi dùng runner; `-FreshSession` / `-FreshTui` cũng giữ
ID cũ. Đây là danh bạ session, không phải bản sao lưu toàn bộ hội thoại: nội dung vẫn
nằm trong kho session của Codex/OpenCode trên máy đó. Các file map được Git ignore,
nên clone/pull repo sang máy khác không mang theo session của máy hiện tại.

Mở lại một session cũ bằng `codex resume <thread-id>` hoặc
`opencode attach <URL-server-của-repo> -s <session-id>`. Runner luôn in dòng `TUI:`
của session được chọn. Chạy ngoài Claude Code cần truyền `-Key <tên-phiên>` cho cả hai
runner để lịch sử được gắn đúng phiên.

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
| 10 | không giành được run lock: runner Codex khác đang chạy, hoặc lock hỏng/không truy cập được — runner từ chối chạy, không đóng TUI của lượt kia (chỉ lane Codex) |
| 11 | thiếu danh tính phiên Claude: không có `-Key` và cả hai env `CLAUDE_CODE_*` đều trống — coder không chạy |
| 124 | quá `timeout_sec`. Lane Codex: thử giết cả cây tiến trình; nếu không giết được thì giữ run lock theo PID còn sống. Lane OpenCode: dừng lượt và không thử fallback. |

## Lưu ý

- Lane OpenCode tự tìm server riêng của từng repo trong dải cổng `4096-4105`, nên chạy
  nhiều repo song song thì mỗi repo chiếm một cổng trong dải đó.
- Mỗi lượt OpenCode đều in `TUI: opencode attach <URL> -s <session-id>`. Kể cả khi dùng
  `-NoTui`, runner vẫn lấy/ghi session nhưng không mở CMD, để có thể dán lệnh này mở lại
  đúng TUI sau khi chạy headless hoặc lỡ đóng cửa sổ.
- Nội dung task brief được pipe vào standard input UTF-8, không nằm trong command line. Vì
  vậy brief dài hơn giới hạn 8,191 ký tự của `cmd.exe`, có tiếng Việt hoặc dấu nháy vẫn chạy
  được.
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
`state.json`, `PROJECT_RULES.md`, `tasks/_TEMPLATE.md` và `.pipeline/.gitignore` giữ
nguyên trừ khi chạy `-Force`. `pipeline.config.json` giữ các field riêng của project,
tự migrate hai chuỗi fallback OpenCode và thêm `session_rollover.context_percent: 80`
nếu chưa có. Ngưỡng đã tùy chỉnh được giữ nguyên; không cần dùng `-Force` để nhận cập nhật này.
