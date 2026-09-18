---
name: pipeline
description: Chay vong lap plan -> giao viec cho OpenCode hoac Codex -> review -> task tiep theo. Dung khi user muon Claude orchestration va giao phan coding cho mot coding agent.
---

# Pipeline: Claude plan → OpenCode/Codex code → Claude review

Bạn là **orchestrator**. Bạn KHÔNG viết code tính năng. Bạn plan, review, quyết định.

## Luật cứng của repo

Đọc `.pipeline/pipeline.config.json` và `.pipeline/PROJECT_RULES.md` trước khi plan. Mọi
luật cứng của repo (ví dụ không restart service production, đổi hành vi phải cập nhật
tài liệu, không test lên dữ liệu thật, vùng cấm đụng) nằm ở `PROJECT_RULES.md`; brief
giao cho coding agent phải nhắc lại các luật liên quan.

Lệnh verify lấy từ config:

```
# test mục tiêu trước
<test_command_targeted>
# rồi toàn bộ. Baseline KHÔNG cố định: đo lại ngay trước khi giao task
<test_command>
```

Không tự bịa lệnh test khác; config chưa điền thì hỏi user.

Vùng cấm đụng: lấy từ `forbidden_paths` trong `pipeline.config.json`.

## Coding backend

OpenCode và Codex là hai lựa chọn **ngang hàng**. Mỗi task phải có trường `coder`
trong `.pipeline/state.json` với giá trị `opencode` hoặc `codex`. Nếu user chỉ định
backend thì làm đúng; nếu không, Claude chọn trong lúc plan và trình user duyệt.

| Coder | Runner Claude | Script | Model |
|---|---|---|---|
| OpenCode | `oc-coder` | `.pipeline/bin/oc-run.ps1` | `deepseek-v4.1-flash` (`max`), fallback theo chuỗi policy |
| Codex | `codex-coder` | `.pipeline/bin/codex-run.ps1` | `gpt-5.6-luna` + `xhigh`; leo thang `gpt-5.6-terra` + `high` |

Để dùng backend Codex, máy chạy Claude phải có lệnh `codex` trong `PATH` và Codex
CLI đã đăng nhập. Runner dùng authentication đã lưu của CLI, không đọc hoặc ghi API
key vào repository.

Fallback bên trong OpenCode **chỉ chạy khi lượt đầu không đụng vào file nào**. Không
tự chuyển OpenCode ↔ Codex trong cùng task. Nếu coder đã sửa dở dang rồi hỏng, giữ
nguyên để review; không thả coder thứ hai vào đè lên thay đổi. Muốn đổi backend phải
đảm bảo worktree sạch, cập nhật plan và xin user duyệt lại.

### Chính sách model

| Lane | Mặc định | Leo thang |
|---|---|---|
| OpenCode | `opencode-go/deepseek-v4.1-flash` + `--variant max` | chuỗi fallback theo policy bên dưới |
| Codex | `gpt-5.6-luna` + `model_reasoning_effort=xhigh` | `gpt-5.6-terra` + `model_reasoning_effort=high` |

**Cấm dùng để implement code:** `gpt-5.6-sol` và `gpt-6-astra`, kể cả khi task khó; muốn
dùng phải hỏi user trước. Runner `.pipeline/bin/codex-run.ps1` chặn cứng hai model này bằng `exit 2`.

Thang leo bậc khi review fail:

1. Lượt 1 dùng mặc định của lane.
2. Review fail thì **chẩn đoán trước khi leo**: nếu fix brief chỉ ra được đúng `file:dòng`,
   sai gì, kỳ vọng gì → lỗi cơ học, giữ nguyên model và `-Resume`. Nếu không nói chính xác
   được sai ở đâu → lỗi nằm ở brief, viết lại brief, vẫn giữ nguyên model.
3. Fail lần hai **dù brief đã chính xác** → mới leo sang bậc escalated.
4. `attempts >= 3` → dừng, báo user (giữ nguyên luật cũ).

Khi leo bậc bắt buộc chạy **thread mới với `-FreshSession`**, và worktree phải sạch trước khi
đổi model — thread cũ mang theo chuỗi suy luận hỏng, còn worktree đang chứa sửa dở của model
trước; thả model mới đè lên thì không biết ai làm phần nào.

Chính sách nằm trong `model_policy` của `.pipeline/pipeline.config.json`.

**Fallback OpenCode:** nếu lượt không sửa file, thử theo thứ tự DeepSeek V4 Flash (`max`)
→ Vision Exp (`max`) → MiMo V2.5 Pro (không truyền variant) → LongCat-2.0 (`high`) →
Qwen3.8 Flash (`xhigh`). Nếu primary DeepSeek V4.1 Flash báo quota/rate limit/model
unavailable, dùng chuỗi ngược: Qwen → LongCat → MiMo → Vision Exp → DeepSeek V4 Flash.
Dừng khi có thay đổi file, timeout hoặc lỗi tham số; không thả model khác đè lên worktree
đã có sửa dở.

## Giai đoạn 1 — Plan

1. Đọc `.pipeline/PROJECT_RULES.md` và tài liệu của repo liên quan tới task.
2. Bẻ mục tiêu thành task **nhỏ, độc lập, verify được**:
   - Chạm ≤ 3–4 file
   - Tiêu chí chấp nhận kiểm chứng bằng lệnh test cụ thể
   - Không phụ thuộc task chưa xong
   - Cần > ~300 dòng diff → chẻ nhỏ tiếp
3. Ghi `.pipeline/state.json`:

```json
{
  "goal": "...",
  "verify": {
    "all": "<test_command>",
    "baseline": "<đo lại trước mỗi task>"
  },
  "tasks": [
    { "id": "T1", "title": "...", "coder": "codex", "status": "pending", "attempts": 0, "depends_on": [] }
  ]
}
```

4. **Trình plan cho user duyệt trước khi chạy.** Không tự ý bắt đầu vòng lặp.

## Giai đoạn 2 — Vòng lặp mỗi task

### a) Viết brief `.pipeline/tasks/<id>.md`

Coding agent không thấy hội thoại này. Brief phải **tự chứa** — dùng `.pipeline/tasks/_TEMPLATE.md`.

### b) Commit sạch rồi giao coding agent

Worktree PHẢI sạch trước khi chạy coder, để `git diff` sau đó đúng bằng phần coding agent vừa làm.
Nếu worktree bẩn: **dừng, hỏi user**. Không tự `git stash`, không tự commit gộp việc của người ta.

#### Chọn OpenCode

- **Lưu ý truyền brief:** `oc-run.ps1` pipe toàn bộ brief UTF-8 vào standard input của `opencode`, không đưa brief vào dòng lệnh. Vì vậy brief dài hơn giới hạn 8,191 ký tự của `cmd.exe`, tiếng Việt, và dấu nháy đều an toàn. Nếu thấy opencode in help rồi thoát với exit 5 mà không đụng file nào thì đó là dấu hiệu bug truyền tham số quay lại, không phải model từ chối task.

**TUI bật mặc định** khi giao việc; chỉ thêm `-NoTui` khi muốn tắt cửa sổ. Cờ `-NewTui` cũ vẫn được chấp nhận để lệnh cũ không gãy, nhưng không còn tác dụng riêng:

```
powershell -NoProfile -File .pipeline/bin/oc-run.ps1 -TaskFile .pipeline/tasks/<id>.md
```

Sau khi runner trả URL/session, luôn chuyển nguyên dòng `TUI: opencode attach <URL> -s <session-id>` cho người dùng. Với `-NoTui`, runner không mở CMD nhưng vẫn cấp session và in dòng này để người dùng tự mở lại TUI. `--auto` là cờ quyền tự duyệt, không phải chế độ hiển thị.

Nó đóng cửa sổ CMD đang mở, rồi **tra bản đồ phiên Claude → phiên opencode**:

- Phiên Claude này đã có phiên opencode và phiên đó còn sống → **dùng lại**, giữ nguyên lịch sử
- Chưa có, hoặc phiên cũ đã mất trên server → tạo mới rồi ghi vào bản đồ

Nghĩa là mở lại một phiên Claude cũ và giao task tiếp thì cửa sổ TUI quay về đúng phiên
opencode của nó, không phải phiên trắng. Hai phiên Claude khác nhau giữ hai phiên opencode
riêng, nhưng chỉ một cửa sổ CMD tồn tại tại một thời điểm — cửa sổ luôn thuộc về phiên
Claude vừa giao việc gần nhất.

Khoá là `CLAUDE_CODE_HOST_SESSION_ID` (fallback `CLAUDE_CODE_SESSION_ID`).
Bản đồ: `.pipeline/tui-map.json`. Cửa sổ đang mở: `.pipeline/tui.json`.

**Mỗi repo một server riêng:** server opencode gắn chặt với thư mục nó được khởi động, nên
attach vào server của repo khác là coder đọc/sửa nhầm dự án. `oc-tui.ps1` tự dò dải cổng
`4096-4105`: thấy server có `worktree` đúng repo hiện tại thì dùng, không thì khởi động
server mới cho repo đó (chờ tối đa 30 giây rồi tự kiểm lại). Vì vậy chạy nhiều repo song
song được, mỗi repo chiếm một cổng trong dải. Nếu runner in
`BLOCKED: phien opencode dang o ...` thì nghĩa là server đang bị repo khác chiếm — dùng
`-NoTui`, hoặc đóng server đang chiếm cổng đó rồi chạy lại.

**Đánh đổi khi dùng lại phiên:** context của opencode tích lũy qua các task, tốn thêm
input token và có thể lẫn chỉ dẫn của task cũ. Khi muốn bắt đầu sạch cho một task,
thêm `-FreshTui` để ép tạo phiên opencode mới cho phiên Claude này.

KHÔNG tự `Stop-Process` cửa sổ nào ngoài PID ghi trong `tui.json`.

Gọi subagent `oc-coder` với đường dẫn brief. (Qua subagent để log OpenCode không tràn vào context bạn.)

#### Chọn Codex

```
powershell -NoProfile -File .pipeline/bin/codex-run.ps1 -TaskFile .pipeline/tasks/<id>.md
```

Mỗi phiên Claude được gắn với **một Codex thread**. Lần giao task đầu tạo thread; các
lần sau tự resume đúng thread đó, kể cả khi không truyền `-Resume`. Mặc định runner mở **TUI gốc của Codex**
(`codex --approve-for-me -C <repo> "<prompt trỏ tới brief>"`) để người dùng thấy đúng
giao diện Codex đang làm việc. `-Exec` hoặc `-NoTui` chạy headless (`codex exec`)
**không cửa sổ**, dùng khi thư mục chưa được Codex tin cậy hoặc khi chạy tự động không
ai ngồi xem. Thread
ID được ghi theo khóa `-Key` (nếu truyền), rồi `CLAUDE_CODE_HOST_SESSION_ID`, rồi
`CLAUDE_CODE_SESSION_ID` trong `.pipeline/codex-map.json` (file ignore), không dùng
`--last`. Chạy ngoài Claude Code phải truyền `-Key`; thiếu cả ba nguồn thì runner in
`BLOCKED:` và thoát mã `11` chứ không gộp lịch sử vào một key chung. Cửa sổ TUI cũ do
runner mở được đóng trước khi mở TUI của lần giao mới, vì vậy chỉ có một cửa sổ Codex của
pipeline trong mỗi repo tồn tại tại một thời điểm và nó luôn thuộc về phiên Claude vừa
giao việc gần nhất. Bản đồ TUI lưu cả PID lẫn thời điểm khởi động của tiến trình; runner
chỉ đóng khi PID còn sống, đúng tên `codex` và đúng thời điểm khởi động, còn bản ghi cũ
thiếu thời điểm khởi động thì bỏ qua để không giết nhầm PID đã bị tái sử dụng. Dùng
`-FreshSession` khi thật sự cần bỏ lịch sử và tạo thread Codex mới (ví dụ lúc leo thang model).
Khi headless có thread, runner in `TUI: codex resume <thread-id>`; chuyển nguyên dòng này cho người dùng để họ tự mở lại đúng TUI.

Việc đóng TUI cũ rồi mở TUI mới chỉ an toàn khi các lượt chạy **tuần tự**, nên runner
giữ một **run lock theo repo** tại `.pipeline/logs/codex-run.lock` (đã ignore). Lượt thứ
hai chồng lên sẽ thoát ngay với `BLOCKED: ... (PID ...)` thay vì đóng nhầm TUI mà lượt
đang chạy còn cần; lock của tiến trình đã chết được tự thu hồi, còn lock của tiến trình
còn sống thì không ai được xóa. Lock không thu hồi được vì lý do khác (file lock hỏng,
không truy cập được) cũng làm runner `exit 10` chứ **không chạy không lock**. Gặp thông
báo này hãy chờ lượt kia xong rồi chạy lại, không tự tắt tiến trình/TUI của PID đó.
Nếu runner không đóng được TUI cũ đã quản lý thì nó cũng `exit 10`, không mở thêm TUI.
Khi timeout mà `taskkill` không giết được Codex, lock được chuyển sang PID Codex còn
sống; lượt sau bị chặn đến khi tiến trình đó kết thúc hoặc người dùng đóng thủ công.

**Điều kiện của TUI gốc:** thư mục repo phải được Codex tin cậy
(`~/.codex/config.toml`, mục `[projects.'...']` với `trust_level = "trusted"`). Thư mục
lạ thì TUI chặn hỏi xác nhận và runner chỉ biết chờ tới `-TimeoutSec`; muốn dùng TUI
trong repo mới thì chạy một lượt `-Exec`/`-NoTui` nhỏ trong repo đó trước (exec tự
đăng ký tin cậy), rồi hãy để mặc định. Thread liên thông hai chiều: thread do TUI tạo
vẫn `codex exec resume <id>` được, và thread do `codex exec` tạo vẫn mở lại được bằng TUI.

Runner tự ép model theo chính sách (`-Model gpt-5.6-luna`, `-ReasoningEffort xhigh`),
không phụ thuộc `~/.codex/config.toml` của máy nữa; chỉ đổi khi leo thang theo mục
**Chính sách model** ở trên.

Ở chế độ headless (`-Exec`/`-NoTui`), runner không mở cửa sổ nào; Codex chạy ngầm và
output trả về Claude chỉ có diffstat, kết quả test và final message. Gọi subagent
`codex-coder` với đường dẫn brief.

Khi timeout, runner thử giết cả cây tiến trình Codex/TUI bằng `taskkill /T /F`. Nếu
không giết được, nó giữ run lock theo PID còn sống thay vì buông tay. Thread id được lưu
vào `codex-map.json` ngay khi nhận ra (TUI: từ rollout,
exec: khi `thread.started` xuất hiện), nên `-Resume` vẫn dùng được kể cả khi lượt trước
chết giữa chừng. Ở chế độ `-Exec`, stderr của Codex nằm ở file `<log>.err` cạnh file
JSONL; ở chế độ TUI, rollout được sao chép vào `.pipeline/logs/<base>-<tag>-native.jsonl`.

### c) Review

Đúng thứ tự, không bỏ bước:

1. `git diff` — đọc toàn bộ thay đổi
2. Chạy test mục tiêu, rồi chạy **toàn bộ** suite. So với baseline đã đo ở bước b. **Chạy thật, đừng đoán.**
3. Đối chiếu từng tiêu chí chấp nhận
4. Soát checklist lỗi hay gặp:
   - Sửa/xoá/skip test có sẵn cho pass thay vì sửa code
   - Nuốt exception (`except: pass`), trả giá trị giả
   - Hardcode giá trị lẽ ra lấy từ config/secret
   - Đụng file ngoài danh sách cho phép
   - Vi phạm luật cứng trong `.pipeline/PROJECT_RULES.md`
   - Đổi hành vi mà quên cập nhật tài liệu theo luật repo
   - Lưu URL/cookie/header/secret/credential vào DB, log hoặc output
   - Làm yếu kiểm tra an toàn (auth, SSRF, DRM, cookie...) nếu repo có
   - Thêm dependency không xin phép

### d) Quyết định

- **Pass** → `git commit -m "<id>: <title>"`, status `done`, sang task kế.
- **Fail, attempts < 3** → viết `.pipeline/tasks/<id>.fix-<n>.md` chứa **chỉ phát hiện cụ thể** (trích `file:dòng`, sai ở đâu, kỳ vọng gì). Gọi lại đúng runner đã chọn (`oc-coder` hoặc `codex-coder`) với `-Resume`. Tăng `attempts`.
- **Fail, attempts >= 3** → dừng. Báo user: task nào, hỏng gì, đề xuất (chẻ nhỏ / Claude tự làm / đổi cách). Đừng im lặng tự làm thay.

## Nguyên tắc

- Mỗi task = mỗi commit. Không gộp.
- Không tự sửa code của coding agent rồi commit chung — sẽ không biết coder thực sự làm được tới đâu. Hoặc feedback bắt sửa, hoặc escalate.
- Sau mỗi task báo user một dòng: `T3 ✓ (2 lượt) — 4 file, N test pass`.
- Cập nhật `.pipeline/state.json` trước khi sang task kế.
