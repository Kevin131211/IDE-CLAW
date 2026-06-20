---
description: Use IDE Claw for mandatory blocking user communication in this workspace. Trigger whenever you need a user decision, clarification, branch choice, milestone review, long-running task completion confirmation, or any situation where .windsurfrules requires dialog.py. Do not use for deterministic read/list operations.
when_to_use: Invoke this skill before asking the user a question, choosing between multiple implementation paths, requesting review at a milestone, or asking for confirmation after a long task in the IDE Claw project.
user-invocable: true
disable-model-invocation: false
---

# IDE Claw blocking communication protocol

This skill packages the IDE Claw tool for Claude Code. It wraps the canonical runtime in this repository:

- `cascade/dialog.py` — blocking push + wait for desktop/mobile reply.
- `cascade/notify.py` — non-blocking acknowledgement after the reply is read.
- `dist/ide-claw-windows/ide_claw.exe` — optional local desktop client for low-latency IPC.

## Non-negotiable rule

When an IDE Claw trigger applies, do **not** ask in the chat panel. Do **not** continue coding after starting `dialog.py`. Run the blocking dialog command in the foreground, wait until it exits normally, read the exact response file path printed by the script, send the ACK with `notify.py`, then execute the user's returned instruction.

## Triggers

Use this skill when any of these happen:

- A user decision or clarification is needed.
- There are multiple valid paths and the user must choose.
- A major development milestone is ready for review.
- A long-running or large task completed and needs user confirmation or follow-up instructions.

Do **not** invoke it for single-step deterministic operations such as reading files, listing directories, or running an unambiguous check.

## Required workflow

1. Determine the absolute project root/workspace path. In this repository it is normally:

   ```text
   C:/Users/FC/Desktop/IDE-claw-main
   ```

2. Before `dialog.py`, pre-check the desktop client unless the user explicitly said they will reply from mobile only:

   ```powershell
   Invoke-RestMethod -Uri "http://127.0.0.1:13800/ping" -TimeoutSec 2
   ```

   If that fails or times out, start the desktop EXE **non-blocking**, then wait 3-5 seconds:

   ```powershell
   Start-Process -FilePath "C:/Users/FC/Desktop/IDE-claw-main/dist/ide-claw-windows/ide_claw.exe"
   Start-Sleep -Seconds 4
   ```

3. Run the blocking dialog command in the foreground. Never use background execution for this command:

   ```powershell
   python "C:/Users/FC/Desktop/IDE-claw-main/cascade/dialog.py" "<message for the user>" --workspace "<absolute workspace path>"
   ```

   Helper wrapper equivalent:

   ```powershell
   & "C:/Users/FC/Desktop/IDE-claw-main/.claude/skills/ide-claw/scripts/Ask-IdeClaw.ps1" "<message for the user>" -Workspace "<absolute workspace path>"
   ```

4. While `dialog.py` is running, stop all other work. Do not generate code, refactor, run commands, or continue analysis until it exits.

5. After exit, read the exact file path printed after `📄 完整响应已保存到:`. With `--workspace`, it usually looks like:

   ```text
   C:/Users/FC/Desktop/IDE-claw-main/data/workspaces/ws-<hash8>/phone_response.md
   ```

6. Immediately after reading that file, send the mandatory ACK before executing the returned instruction:

   ```powershell
   python "C:/Users/FC/Desktop/IDE-claw-main/cascade/notify.py" --workspace "<same absolute workspace path>"
   ```

   Helper wrapper equivalent:

   ```powershell
   & "C:/Users/FC/Desktop/IDE-claw-main/.claude/skills/ide-claw/scripts/Notify-IdeClaw.ps1" -Workspace "<same absolute workspace path>"
   ```

   `notify.py` is the only allowed non-blocking channel. Do not use `dialog.py` for ACK.

7. Execute every instruction in the response file strictly. Repeat this workflow at the next IDE Claw trigger.

## Helper scripts

- `scripts/Ask-IdeClaw.ps1` resolves the IDE Claw root, checks/starts the desktop client, and invokes `dialog.py` synchronously.
- `scripts/Notify-IdeClaw.ps1` resolves the IDE Claw root and invokes `notify.py` for the fixed acknowledgement.

Environment overrides:

- `IDE_CLAW_HOME` — full IDE Claw checkout path.
- `IDE_CLAW_DESKTOP_EXE` — desktop executable path.
- `IDE_CLAW_PYTHON` — Python executable name/path.

## References

- `references/strict-rules.md` contains the copied IDE Claw strict rule block.
- `references/runtime-layout.md` documents runtime assets and packaging boundaries.
- `cascade/config/push_config.template.json` is a sanitized config template. Do not package or publish `cascade/config/push_config.json` because it may contain real credentials.
