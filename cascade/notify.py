"""非阻塞通知脚本 — 推送一条固定确认消息后立即退出（不等待回复）

用法：
    python notify.py                                  # 推送到默认会话
    python notify.py --workspace "E:/path/to/project" # 推送到工作区专属会话
    python notify.py --text "自定义消息"               # 覆盖固定文本（可选）

与 dialog.py 的区别：
    dialog.py = 阻塞模式（推送 + 挂起等待用户回复）
    notify.py = 非阻塞模式（推送即退，几秒内结束，绝不等待）

供 AI 在【收到用户指令后、开始执行前】调用（fire-and-forget），
让用户在客户端立刻看到"AI 已开始干活"的确认。
"""
import sys
import os
import json

if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
# 复用 dialog.py 的工作区会话派生算法，保证两个脚本永远落在同一个会话
from dialog import workspace_session_id  # noqa: E402

# 固定确认文本（规则文档要求每次收到指令后发送）
FIXED_TEXT = "🤖 AI 已开始执行本条指令，完成后会再次推送汇报。"


def main():
    workspace = ''
    text = FIXED_TEXT
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == '--workspace' and i + 1 < len(args):
            workspace = args[i + 1].strip()
            i += 2
        elif args[i] == '--text' and i + 1 < len(args):
            text = args[i + 1]
            i += 2
        else:
            i += 1

    config_path = os.path.join(SCRIPT_DIR, 'config', 'push_config.json')
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        server_url = cfg.get('server_url', '')
        session_id = cfg.get('session_id', '')
        token = cfg.get('auth_token', '') or cfg.get('token', '')
    except Exception:
        print("❌ 推送配置缺失: cascade/config/push_config.json", file=sys.stderr)
        sys.exit(1)

    if not (server_url and session_id and token):
        print("❌ 推送配置不完整", file=sys.stderr)
        sys.exit(1)

    if workspace:
        session_id = workspace_session_id(workspace)

    try:
        import requests
        r = requests.post(
            f"{server_url}/api/push",
            json={
                "session_id": session_id,
                "content": text,
                "msg_type": "text",
                "is_final": True,
            },
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            timeout=8,
        )
        if r.status_code == 200:
            print(f"✅ 非阻塞通知已发送 [会话: {session_id}]")
        else:
            print(f"⚠️ 推送失败 (HTTP {r.status_code}): {r.text[:150]}", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"⚠️ 推送异常: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
