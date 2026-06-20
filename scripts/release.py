"""IDE Claw 一键发布脚本。

功能：
  1. 用 SSH key（优先）或 root 密码（环境变量 VPS_PASSWORD）登录 VPS
  2. 把本机公钥写入 /root/.ssh/authorized_keys（幂等）
  3. 上传 APK 到 /var/www/<host>/dl/ide-claw-latest.apk
  4. 写 /opt/push-server/data/version.json（同时更新本地副本）
  5. 重启 push-server 服务并通过 /api/version 验证

用法：
  python scripts/release.py \
      --host push.shoot-game.cn \
      --apk app/build/app/outputs/flutter-apk/app-release.apk \
      --version 1.0.0 --build 2 \
      --changelog "新增自动检查更新功能"

如果服务器还没装公钥，会自动用 $env:VPS_PASSWORD 登录一次完成密钥安装。
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import io
import json
import os
import sys
import time
from pathlib import Path

import paramiko


# push-server 的 WorkingDirectory=/var/www/push-server
# main.go 里 /dl/ 映射到相对路径 data/uploads/
REMOTE_APK_DIR = "/var/www/push-server/data/uploads"
REMOTE_APK_NAME = "ide-claw-latest.apk"
REMOTE_DESKTOP_NAME = "ide-claw-windows.zip"
REMOTE_VERSION_PATH = "/var/www/push-server/data/version.json"
REMOTE_SERVICE = "push-server"
REMOTE_BIN_PATH = "/var/www/push-server/push-server"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_pubkey() -> str:
    pub = Path.home() / ".ssh" / "id_ed25519.pub"
    if not pub.exists():
        sys.exit(f"找不到本地公钥 {pub}，请先 ssh-keygen -t ed25519")
    return pub.read_text(encoding="utf-8").strip()


def connect(host: str, *, password: str | None) -> paramiko.SSHClient:
    cli = paramiko.SSHClient()
    cli.load_system_host_keys()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    key_path = Path.home() / ".ssh" / "id_ed25519"
    # 1) 先试 key
    try:
        cli.connect(host, username="root", key_filename=str(key_path), timeout=10, allow_agent=False, look_for_keys=False)
        print("[ssh] 公钥登录成功")
        return cli
    except paramiko.AuthenticationException:
        pass
    if not password:
        sys.exit("公钥登录失败，且没有提供 VPS_PASSWORD 环境变量")
    cli.connect(host, username="root", password=password, timeout=10, allow_agent=False, look_for_keys=False)
    print("[ssh] 密码登录成功，正在安装公钥...")
    install_pubkey(cli)
    return cli


def run(cli: paramiko.SSHClient, cmd: str, *, check: bool = True) -> str:
    stdin, stdout, stderr = cli.exec_command(cmd)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if check and code != 0:
        sys.exit(f"远程命令失败 (exit={code}): {cmd}\nstdout: {out}\nstderr: {err}")
    return out.strip()


def install_pubkey(cli: paramiko.SSHClient) -> None:
    pub = load_pubkey()
    cmd = (
        "mkdir -p /root/.ssh && chmod 700 /root/.ssh && "
        f"grep -qxF {json.dumps(pub)} /root/.ssh/authorized_keys 2>/dev/null || "
        f"echo {json.dumps(pub)} >> /root/.ssh/authorized_keys && "
        "chmod 600 /root/.ssh/authorized_keys && echo OK"
    )
    out = run(cli, cmd)
    print(f"[ssh] authorized_keys: {out}")


def upload(cli: paramiko.SSHClient, local: Path, remote: str) -> None:
    sftp = cli.open_sftp()
    try:
        # 确保父目录存在
        run(cli, f"mkdir -p {os.path.dirname(remote)}")
        size = local.stat().st_size
        sent = [0]
        last_pct = [-1]

        def cb(transferred: int, _total: int) -> None:
            sent[0] = transferred
            pct = int(transferred * 100 / size) if size else 100
            if pct != last_pct[0] and pct % 5 == 0:
                last_pct[0] = pct
                print(f"\r[upload] {remote} {pct:3d}%", end="", flush=True)

        print(f"[upload] {local} -> {remote} ({size/1024/1024:.1f} MB)")
        sftp.put(str(local), remote, callback=cb)
        print()
    finally:
        sftp.close()


def write_remote_json(cli: paramiko.SSHClient, remote: str, data: dict) -> None:
    sftp = cli.open_sftp()
    try:
        run(cli, f"mkdir -p {os.path.dirname(remote)}")
        payload = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        with sftp.open(remote, "wb") as f:
            f.write(payload)
        print(f"[ver] 写入 {remote} ({len(payload)} bytes)")
    finally:
        sftp.close()


def main() -> int:
    ap = argparse.ArgumentParser(description="IDE Claw 发布脚本")
    ap.add_argument("--host", default="push.shoot-game.cn")
    ap.add_argument("--apk", required=True, help="本地 APK 路径")
    ap.add_argument("--version", required=True, help="版本号 e.g. 1.0.0")
    ap.add_argument("--build", required=True, type=int, help="buildNumber e.g. 2")
    ap.add_argument("--changelog", default="", help="更新说明（中文）")
    ap.add_argument("--min-build", default=1, type=int)
    ap.add_argument("--no-restart", action="store_true", help="不重启 push-server")
    ap.add_argument("--server-bin", default="", help="新版 push-server linux binary 路径（可选，传则替换并重启）")
    ap.add_argument("--desktop-zip", default="", help="桌面端 zip 路径（可选，传则上传到 /dl/ide-claw-windows.zip）")
    args = ap.parse_args()

    apk = Path(args.apk).resolve()
    if not apk.exists():
        sys.exit(f"APK 不存在: {apk}")

    sha = sha256_file(apk)
    size = apk.stat().st_size
    print(f"[apk] {apk}\n      size={size} sha256={sha}")

    version_data = {
        "latest_version": args.version,
        "latest_build": args.build,
        "apk_url": f"https://{args.host}/dl/{REMOTE_APK_NAME}",
        "apk_size": size,
        "apk_sha256": sha,
        "release_date": _dt.date.today().isoformat(),
        "changelog": args.changelog,
        "min_supported_build": args.min_build,
    }
    # 可选：桌面 zip 信息（用于桌面端自动检查更新）
    desktop_zip = Path(args.desktop_zip).resolve() if args.desktop_zip else None
    if desktop_zip:
        if not desktop_zip.exists():
            sys.exit(f"桌面 zip 不存在: {desktop_zip}")
        d_sha = sha256_file(desktop_zip)
        d_size = desktop_zip.stat().st_size
        print(f"[zip] {desktop_zip}\n      size={d_size} sha256={d_sha}")
        version_data["desktop_url"] = f"https://{args.host}/dl/{REMOTE_DESKTOP_NAME}"
        version_data["desktop_size"] = d_size
        version_data["desktop_sha256"] = d_sha
    # 可选：服务端 binary（不进 version.json，仅热替换）
    server_bin = Path(args.server_bin).resolve() if args.server_bin else None
    if server_bin and not server_bin.exists():
        sys.exit(f"server binary 不存在: {server_bin}")

    # 同步写本地一份
    local_version = Path(__file__).resolve().parent.parent / "server" / "data" / "version.json"
    local_version.parent.mkdir(parents=True, exist_ok=True)
    local_version.write_text(json.dumps(version_data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[ver] 本地副本: {local_version}")

    password = os.environ.get("VPS_PASSWORD")
    cli = connect(args.host, password=password)
    try:
        install_pubkey(cli)  # 幂等：再确保一次
        remote_apk = f"{REMOTE_APK_DIR.format(host=args.host)}/{REMOTE_APK_NAME}"
        upload(cli, apk, remote_apk)
        # 上传桌面 zip（可选）
        if desktop_zip:
            remote_zip = f"{REMOTE_APK_DIR}/{REMOTE_DESKTOP_NAME}"
            upload(cli, desktop_zip, remote_zip)
            actual_d_sha = run(cli, f"sha256sum {remote_zip} | awk '{{print $1}}'")
            if actual_d_sha != version_data["desktop_sha256"]:
                sys.exit(f"远程 desktop zip SHA256 不匹配!")
            print(f"[verify] 桌面 zip SHA256 OK: {actual_d_sha[:16]}...")
        # 上传 server binary 并替换（可选）
        if server_bin:
            tmp_bin = "/tmp/push-server.new"
            upload(cli, server_bin, tmp_bin)
            run(cli, f"chmod +x {tmp_bin}")
            run(cli, f"mv {tmp_bin} {REMOTE_BIN_PATH}")
            print(f"[svc] 已替换 server binary -> {REMOTE_BIN_PATH}")
        write_remote_json(cli, REMOTE_VERSION_PATH, version_data)

        # 校验下载链接和 hash
        actual_sha = run(cli, f"sha256sum {remote_apk} | awk '{{print $1}}'")
        if actual_sha != sha:
            sys.exit(f"远程 SHA256 不匹配! local={sha} remote={actual_sha}")
        print(f"[verify] 远程 SHA256 一致: {actual_sha}")

        # 替换 binary 后必须重启
        force_restart = bool(server_bin)
        if (not args.no_restart) or force_restart:
            run(cli, f"systemctl restart {REMOTE_SERVICE}", check=False)
            # 等服务真正起来（最多 10 秒），避免下面 verify 时拿到旧响应
            for _ in range(20):
                state = run(cli, f"systemctl is-active {REMOTE_SERVICE}", check=False)
                if state.strip() == "active":
                    break
                time.sleep(0.5)
            # 多等 1 秒让 HTTP listener 真正接收
            time.sleep(1)
            print(f"[svc] 已重启 {REMOTE_SERVICE}")

        # 拉一下 /api/version 验证（用本地 sha256 与响应里的 apk_sha256 比对）
        out = run(cli, f"curl -fsS https://{args.host}/api/version", check=False)
        if sha[:16] in out:
            print(f"[verify] /api/version sha256 OK ({sha[:16]}...)")
        else:
            print(f"[verify] /api/version 响应未含新 sha256，可能服务还没真正切到新数据，请稍后手动 curl 验证。响应：{out[:300]}")
    finally:
        cli.close()
    # 用 ASCII 标记替代 emoji，兼容 Windows GBK 终端
    print("\n[OK] 发布完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
if __name__ == "__main__":
    raise SystemExit(main())
