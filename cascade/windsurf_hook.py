#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""IDE Claw - Windsurf 额度耗尽 / 切号钩子脚本

当 cascade 检测到 Windsurf 出现以下情况时调用本脚本:
  - 当前账号 daily/weekly 余量低于阈值 (默认 5%)
  - 收到 "out of credits" / "quota exhausted" / "rate limited" 错误
  - 用户主动让你"换一个 windsurf 账号"

本脚本:
  1. 读 cascade/config/push_config.json 拿 server_url + token + session_id
  2. 调 POST /api/windsurf/accounts/quota-exhausted (默认) 或 /switch (手动)
  3. 服务端会:
     a) 标记当前账号 daily=0
     b) 找下一个可用账号 (daily/weekly% >= 5%)
     c) 通过 WebSocket 广播 windsurf_switch 命令给桌面端 ide_claw.exe
     d) 桌面端调 WindsurfPatchService 自动 kill + 清缓存 + 重启 Windsurf + 复制密码到剪贴板

用法:
  # 自动切到下一个 (推荐)
  python cascade/windsurf_hook.py auto-switch \
      --current-email <现在用的邮箱> \
      --error-message "对话被强制停止: out of credits"

  # 手动切到指定账号
  python cascade/windsurf_hook.py switch \
      --target-email next@example.com \
      --reason manual

  # 查询账号池状态 (诊断用)
  python cascade/windsurf_hook.py status

  # 列出账号池
  python cascade/windsurf_hook.py list

退出码:
  0 = 成功
  1 = 配置缺失
  2 = HTTP 失败
  3 = 没有可切换的账号
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "config" / "push_config.json"


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        print(f"[hook] config 不存在: {CONFIG_PATH}", file=sys.stderr)
        sys.exit(1)
    try:
        cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"[hook] config 解析失败: {e}", file=sys.stderr)
        sys.exit(1)
    server_url = cfg.get("server_url", "").rstrip("/")
    session_id = cfg.get("session_id", "")
    token = cfg.get("auth_token") or cfg.get("token") or ""
    if not (server_url and session_id and token):
        print("[hook] config 不完整 (server_url/session_id/auth_token 必填)", file=sys.stderr)
        sys.exit(1)
    return {"server_url": server_url, "session_id": session_id, "token": token}


def http_post(url: str, token: str, body: dict, timeout: int = 30) -> tuple[int, dict | str]:
    try:
        import requests  # type: ignore
    except ImportError:
        print("[hook] 缺少 requests 库, 请 pip install requests", file=sys.stderr)
        sys.exit(2)
    try:
        r = requests.post(url, json=body, headers={"Authorization": f"Bearer {token}"}, timeout=timeout)
    except Exception as e:
        print(f"[hook] 请求 {url} 失败: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        return r.status_code, r.json()
    except Exception:
        return r.status_code, r.text


def http_get(url: str, token: str, timeout: int = 15) -> tuple[int, dict | str]:
    try:
        import requests  # type: ignore
    except ImportError:
        print("[hook] 缺少 requests 库, 请 pip install requests", file=sys.stderr)
        sys.exit(2)
    try:
        r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=timeout)
    except Exception as e:
        print(f"[hook] 请求 {url} 失败: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        return r.status_code, r.json()
    except Exception:
        return r.status_code, r.text


def cmd_auto_switch(cfg: dict, current_email: str, error_message: str) -> int:
    """额度耗尽自动切下一个号"""
    url = f"{cfg['server_url']}/api/windsurf/accounts/quota-exhausted"
    body = {
        "email": current_email,
        "error_message": error_message,
        "target_session_id": cfg["session_id"],
    }
    code, resp = http_post(url, cfg["token"], body)
    if code != 200:
        print(f"[hook] HTTP {code}: {resp}", file=sys.stderr)
        return 2
    if not isinstance(resp, dict):
        print(f"[hook] 响应非 JSON: {resp}", file=sys.stderr)
        return 2
    if resp.get("switched"):
        new_email = resp.get("new_email", "(unknown)")
        print(f"[hook] 已自动切到: {new_email}")
        print(f"[hook] 桌面端会自动 kill+清缓存+重启 Windsurf, 密码已复制到剪贴板")
        print(f"[hook] 请等 5-10 秒让 Windsurf 重启完成, 然后用 {new_email} 重新登录继续对话")
        return 0
    else:
        reason = resp.get("reason", "unknown")
        print(f"[hook] 没有可用账号 (reason={reason})", file=sys.stderr)
        print(f"[hook] 请在 IDE Claw 客户端「Windsurf 账号池」添加新账号或检查全部余量", file=sys.stderr)
        return 3


def cmd_switch(cfg: dict, target_email: str, reason: str) -> int:
    """手动切到指定账号"""
    url = f"{cfg['server_url']}/api/windsurf/accounts/switch"
    body = {
        "email": target_email,
        "reason": reason,
        "target_session_id": cfg["session_id"],
    }
    code, resp = http_post(url, cfg["token"], body)
    if code != 200:
        print(f"[hook] HTTP {code}: {resp}", file=sys.stderr)
        return 2
    print(f"[hook] 已切到: {target_email} (reason={reason})")
    return 0


def cmd_status(cfg: dict) -> int:
    """查询账号池统计"""
    code, resp = http_get(f"{cfg['server_url']}/api/windsurf/status", cfg["token"])
    if code != 200:
        print(f"[hook] HTTP {code}: {resp}", file=sys.stderr)
        return 2
    if isinstance(resp, dict):
        print(json.dumps(resp, indent=2, ensure_ascii=False))
    return 0


def cmd_list(cfg: dict) -> int:
    """列出账号池详情 (含余量百分比)"""
    code, resp = http_get(f"{cfg['server_url']}/api/windsurf/accounts/pool", cfg["token"])
    if code != 200:
        print(f"[hook] HTTP {code}: {resp}", file=sys.stderr)
        return 2
    if not isinstance(resp, dict):
        print(resp)
        return 0
    accounts = resp.get("accounts", [])
    active = resp.get("active_email", "")
    print(f"=== Windsurf 账号池 ({len(accounts)} 个, 当前激活: {active or '(无)'}) ===")
    for a in accounts:
        email = a.get("email", "")
        d = a.get("daily_remaining_percent")
        w = a.get("weekly_remaining_percent")
        plan = a.get("plan_name", "")
        is_active = "★" if a.get("is_active") else " "
        is_expired = "✗" if a.get("is_expired") else " "
        d_str = f"{d:.1f}%" if d is not None else "?"
        w_str = f"{w:.1f}%" if w is not None else "?"
        print(f"{is_active}{is_expired} {email:40s}  daily={d_str:>7s}  weekly={w_str:>7s}  plan={plan}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="IDE Claw Windsurf 切号钩子", formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp_auto = sub.add_parser("auto-switch", help="额度耗尽时自动切下一个号 (cascade 主用)")
    sp_auto.add_argument("--current-email", required=True, help="当前 windsurf 账号 (用于标记 daily=0)")
    sp_auto.add_argument("--error-message", default="quota exhausted", help="错误信息(用于审计)")

    sp_sw = sub.add_parser("switch", help="手动切到指定账号")
    sp_sw.add_argument("--target-email", required=True, help="要切到的账号")
    sp_sw.add_argument("--reason", default="manual", help="切换原因")

    sub.add_parser("status", help="账号池统计")
    sub.add_parser("list", help="列出所有账号 (含余量)")

    args = ap.parse_args()
    cfg = load_config()

    if args.cmd == "auto-switch":
        return cmd_auto_switch(cfg, args.current_email, args.error_message)
    elif args.cmd == "switch":
        return cmd_switch(cfg, args.target_email, args.reason)
    elif args.cmd == "status":
        return cmd_status(cfg)
    elif args.cmd == "list":
        return cmd_list(cfg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
