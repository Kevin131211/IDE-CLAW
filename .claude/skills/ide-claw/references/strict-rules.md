# IDE Claw strict blocking rules

Copied from `.windsurfrules` / `data/ide-claw-rules-current.md` for Claude Code skill use.

# === IDE CLAW RULES START ===
# IDE Claw - Cross-Terminal Push & Desktop EXE Blocking Communication Rules (Strict AI Locking Rule)

## 📌 Core Principle: Physical Session Lock

**CRITICAL RULE**: 
1. You **MUST** execute the `dialog.py` script in **absolute blocking mode (Blocking=true)**. Any form of asynchronous background execution (`Blocking=false`), multi-threaded running, or asking questions directly in the chat panel is **STRICTLY PROHIBITED**!
2. While `dialog.py` is running, you **MUST** suspend the current session (Wait indefinitely) and **wait on the spot for the script to exit normally**.
3. Before the script exits, **you are strictly forbidden from executing any subsequent code generation, refactoring, or command execution**. Otherwise, it will be treated as a severe session crash and security violation!

## ⚙️ When MUST You Invoke & Lock the Session?

When any of the following conditions are met, invoke the communication command below directly, and block/freeze on the spot waiting for user input:

- You need the user to make a decision or clarify a question.
- You encounter multiple paths and need the user to choose one.
- You completed a major developmental milestone and need the user to review.
- You completed a long-running massive script or task, requiring user confirmation or subsequent instructions.

Do NOT invoke this command for single-step, 100% deterministic simple operations (e.g. reading files, listing directories, etc.).

## 🖥️ Desktop Client (ide_claw.exe) Pre-Check

The reply channel is the **IDE Claw desktop client** (`ide_claw.exe`), which runs a local IPC HTTP service on `127.0.0.1:13800`:

- `GET  /ping`    → health check, returns `{"status":"ok","has_pending":bool}`.
- `POST /message` → used internally by `dialog.py`, do NOT call it directly.

Before invoking `dialog.py`, make sure the desktop client is running:

1. Check whether the desktop client is alive:

```bash
curl --max-time 2 http://127.0.0.1:13800/ping
```

2. If the command fails or times out, launch the desktop EXE in a **NON-BLOCKING** way (NEVER use a blocking call, otherwise the whole session deadlocks), then wait 3-5 seconds for the local IPC to become ready:

```powershell
Start-Process -FilePath "c:/Users/FC/Desktop/IDE-claw-main/dist/ide-claw-windows/ide_claw.exe"
```

Do NOT launch the desktop EXE when the user explicitly said they are replying from the mobile phone, or when the task is a single-step trivial operation that does not need `dialog.py` at all.

## 🚀 Communication & Locking Command Format

**STEP 0 (MANDATORY)**: Before every call, check the current project root directory (your current workspace folder, e.g. via `pwd` or the IDE workspace path). You MUST carry it with `--workspace`.

You MUST execute the synchronous command exactly like this (with **Blocking=true**):

```bash
python "c:/Users/FC/Desktop/IDE-claw-main/cascade/dialog.py" "Your questions, details, and context for the user" --workspace "<absolute path of current project root>"
```

With `--workspace`, the tool derives a stable per-project session (ws-<hash8>): if the conversation for this directory does not exist yet it is **created automatically**; if it exists, clients **switch to that conversation automatically**. The desktop EXE shows the conversation list in its left sidebar; the mobile app shows it in its session list. Each workspace gets its own response file, so parallel AI sessions in different projects never overwrite each other.

## 🔄 Execution & Response Flow

1. Execute the above python blocking instruction (always with `--workspace`).
2. One push is delivered to all clients simultaneously, ordered by latency: **Local IPC** (`http://127.0.0.1:13800`, same-machine desktop EXE, millisecond-level; the EXE auto-creates/switches to the workspace conversation) → **Desktop client** via remote WebSocket relay → **Android Mobile App** via Push Server. Whichever client replies first wins; the other channels are cancelled automatically.
3. You must remain in a fully blocked waiting state in the background. Do NOT exit on timeout. Wait until the user types the reply and submits it from either the desktop EXE window or the mobile app.
4. Upon receiving the user's response, it is written to the workspace-specific response file: `c:/Users/FC/Desktop/IDE-claw-main/data/workspaces/<session_id>/phone_response.md` (without `--workspace` it falls back to `c:/Users/FC/Desktop/IDE-claw-main/data/phone_response.md`). The script prints the exact path on exit ("📄 完整响应已保存到: ...").
5. **Immediately after the script exits**, you MUST read the exact response file path printed by the script, e.g.:

```bash
read_file "c:/Users/FC/Desktop/IDE-claw-main/data/workspaces/<session_id>/phone_response.md"
```

6. **MANDATORY NON-BLOCKING ACK**: right after reading the user's instruction (and BEFORE starting to execute it), you MUST send the fixed acknowledgement message in a **non-blocking** way (fire-and-forget, exits within seconds, never waits):

```bash
python "c:/Users/FC/Desktop/IDE-claw-main/cascade/notify.py" --workspace "<same workspace as above>"
```

This pushes the fixed text "🤖 AI 已开始执行本条指令，完成后会再次推送汇报。" to the user's clients so they instantly know the AI picked up the instruction. Do NOT use dialog.py for this (dialog.py is blocking); notify.py is the only allowed non-blocking channel.

7. Execute every single instruction written in the file strictly. Begin the next development cycle. Repeat this blocking-loop at the next interactive milestone (always carrying the same `--workspace`).

# === IDE CLAW RULES END ===
