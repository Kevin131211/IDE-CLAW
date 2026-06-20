# Release Notes

## v0.4.0 — 规则注入器新增 Kiro 适配（.kiro/rules.md）

发布日期：2026-06-19

### ✨ 新功能
- **规则注入器扩展**现在会自动创建 `.kiro` 文件夹，并在其中生成 `rules.md`，内容与其它规则文件完全一致。
- 打开任意工作区时，插件同时注入**五大** AI 规则文件，全面覆盖主流 AI 编程工具：
  - `.windsurfrules`（Windsurf / Cascade）
  - `.cursorrules`（Cursor）
  - `.clinerules`（Cline / Roo Code）
  - `.github/copilot-instructions.md`（GitHub Copilot / VS Code Chat）
  - `.kiro/rules.md`（Kiro，新增）

### 🔧 改动明细
- `extension.js`：`RULE_FILES` 新增 `.kiro/rules.md`；状态栏与「重新生成」确认框文案同步为五大规则文件。
- `package.json`：版本号升至 `0.4.0`，描述更新。
- `extension.vsixmanifest`：版本与描述同步。
- `cascade/dialog.py`：规则读取列表 `_RULES_FILES` 加入 `.kiro/rules.md`。
- 重新打包 `dist/ide-claw-rules-injector.vsix`（已验证包内含 `.kiro` 注入逻辑）。
- `README.md` / `README_CN.md` / `README_EN.md`：3.3「多 IDE 规则文件自动注入」章节更新为五大规则文件。
- `.gitignore`：新增忽略 `*.vsix`（排除第三方大文件打包产物）。

### 📦 升级方式
在 Windsurf / VS Code 的扩展面板中通过「Install from VSIX...」安装新的
`dist/ide-claw-rules-injector.vsix`，安装后重启一次 IDE 即可生效。
