# IDE Claw Claude Code instructions

- 始终用中文回复用户；代码、命令、文件内容按项目需要保持原样。
- 本项目的 IDE Claw 规则源在 `.windsurfrules` 与 `data/ide-claw-rules-current.md`。
- 当需要用户决策、澄清、路径选择、阶段性审查，或长任务完成后的确认/后续指令时，先调用项目本地 skill：`ide-claw`。
- 触发 IDE Claw 规则时，不要在聊天面板直接提问；必须通过 `cascade/dialog.py` 阻塞等待用户回复。
- 每次调用 `dialog.py` 都必须带当前工作区绝对路径：`--workspace "C:/Users/FC/Desktop/IDE-claw-main"`。
- `dialog.py` 退出后，必须读取其打印的响应文件路径，然后在执行响应里的指令前调用 `cascade/notify.py --workspace "C:/Users/FC/Desktop/IDE-claw-main"` 发送非阻塞 ACK。
- 单步确定性操作（读文件、列目录、无歧义检查）不需要 IDE Claw 对话。
