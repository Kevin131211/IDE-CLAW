# IDE Claw skill runtime layout

This local Claude Code skill is an instruction/wrapper package. It intentionally uses the repository's canonical runtime instead of copying runtime scripts into the skill directory.

## Canonical runtime files

- `cascade/dialog.py` — blocking push/wait command. Required.
- `cascade/notify.py` — fixed non-blocking acknowledgement command. Required.
- `cascade/requirements.txt` — Python dependencies for the dialog runtime.
- `cascade/config/push_config.json` — local runtime configuration. Required for actual use, but may contain secrets and must not be published.
- `cascade/config/push_config.template.json` — sanitized template for distribution.
- `dist/ide-claw-windows/ide_claw.exe` — optional Windows desktop client for local IPC.

## Skill files

- `.claude/skills/ide-claw/SKILL.md` — skill entrypoint and protocol.
- `.claude/skills/ide-claw/scripts/Ask-IdeClaw.ps1` — foreground wrapper for `dialog.py`.
- `.claude/skills/ide-claw/scripts/Notify-IdeClaw.ps1` — wrapper for `notify.py`.
- `.claude/skills/ide-claw/references/strict-rules.md` — copied strict rule block.
- `.claude/skills/ide-claw/references/runtime-layout.md` — this file.

## Packaging boundary

Include in a distributable skill/package:

- `SKILL.md`
- `scripts/*.ps1`
- `references/*.md`
- `cascade/dialog.py` and `cascade/notify.py` only if the package is meant to be standalone and path resolution is adapted.
- `cascade/requirements.txt`
- `cascade/config/push_config.template.json`

Do not publish without sanitization:

- `cascade/config/push_config.json`
- Machine-specific `windsurf_dialog_config.json`
- Build outputs from `app/build`, `dist`, Android APKs, or extracted VSIX folders unless the release explicitly needs them.

## Environment overrides

The wrappers support:

- `IDE_CLAW_HOME` — root of a full IDE Claw checkout.
- `IDE_CLAW_DESKTOP_EXE` — explicit `ide_claw.exe` path.
- `IDE_CLAW_PYTHON` — Python executable.
