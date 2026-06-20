"""对话脚本 — 推送消息到 IDE Claw，等待用户回复

用法：
    python dialog.py "消息内容"
    python dialog.py "消息内容" --file /path/to/image.png
    python dialog.py "消息内容" --workspace "E:/path/to/project"

工作流程：
    1. 推送消息到 Push Server（手机端 + Windows桌面端 均可收到）
    2. 同时尝试本地 IPC（127.0.0.1:13800）直连同机桌面端 ide_claw.exe
    3. WebSocket 监听用户回复（来自任一客户端）
    4. 收到回复 → 保存到响应文件 → 退出

多工作区会话（--workspace）：
    传入当前项目根目录后，脚本会根据路径派生稳定的会话 ID（ws-<hash8>），
    自动在服务端创建/复用该工作区专属会话，消息推送到对应会话；
    桌面端按 workspace 自动创建/切换对话区，手机端在会话列表中按工作区查看。
    响应文件按工作区分开存放：data/workspaces/<会话ID>/phone_response.md
    （脚本退出时会打印实际路径，AI 必须读取打印出的那个文件）

供 Cascade 通过 run_command(Blocking=true) 调用。
"""
import sys
import os
import json
import time
import ssl
import re
import threading
import subprocess
import hashlib

# Windows GBK 控制台下 emoji 输出会抛 UnicodeEncodeError，强制 UTF-8 输出
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)  # 上一级为项目根目录
RESPONSE_FILE = os.path.join(PROJECT_DIR, 'data', 'phone_response.md')
MEMORY_DB = os.path.join(PROJECT_DIR, 'data', 'memory.db')
VOCAB_DIR = os.path.join(PROJECT_DIR, 'data', 'vocab')
LOCK_FILE = os.path.join(PROJECT_DIR, '.ai_lock')
MODE_FILE = os.path.join(PROJECT_DIR, 'config', 'ai_mode.json')

# 本地 IPC：同机桌面端 ide_claw.exe 监听的端口
IPC_PORT = 13800
DESKTOP_EXE = os.path.join(PROJECT_DIR, 'dist', 'ide-claw-windows', 'ide_claw.exe')

# ==================== 多工作区会话支持 ====================
# AI 调用时携带 --workspace <项目目录>，按目录自动派生会话：
#   - 会话不存在 → 服务端/桌面端自动创建并以文件夹名命名
#   - 会话已存在 → 自动路由/切换到该对话区
#   - 响应文件按工作区分开存放，多工作区并行等待时互不覆盖

# 当前工作区目录（--workspace 传入），为空时退回单会话旧行为
WORKSPACE_DIR = ''


def _normalize_workspace(path):
    """规范化工作区路径：绝对路径、统一正斜杠、去尾斜杠、小写。
    必须与桌面端 Dart 侧 WorkspaceSession.normalize 算法保持一致。"""
    p = os.path.abspath(path).replace('\\', '/')
    while p.endswith('/'):
        p = p[:-1]
    return p.lower()


def workspace_session_id(path):
    """根据工作区路径派生稳定会话 ID：ws-<sha1前8位>。
    必须与桌面端 Dart 侧 WorkspaceSession.idForPath 算法保持一致。"""
    norm = _normalize_workspace(path)
    return 'ws-' + hashlib.sha1(norm.encode('utf-8')).hexdigest()[:8]


def workspace_folder_name(path):
    """工作区文件夹显示名（保留原始大小写）"""
    p = os.path.abspath(path).replace('\\', '/').rstrip('/')
    return os.path.basename(p) or p


def workspace_response_file(session_id):
    """按工作区分开存放的响应文件路径"""
    return os.path.join(PROJECT_DIR, 'data', 'workspaces', session_id, 'phone_response.md')


def _register_workspace_session(server_url, token, session_id, workspace_dir):
    """在服务端注册/更新工作区会话元数据（自动创建会话）。失败 silent。

    服务端 /api/sessions/meta 内部 GetOrCreateSession：会话不存在时自动创建，
    存在时仅更新元数据 —— 客户端会话列表因此能按文件夹名显示。
    """
    try:
        import socket
        import requests
        requests.post(
            f"{server_url}/api/sessions/meta",
            json={
                'session_id': session_id,
                'machine_name': socket.gethostname(),
                'project_name': workspace_dir,
                'ide_type': os.environ.get('IDE_CLAW_IDE', 'cursor'),
                'display_name': workspace_folder_name(workspace_dir),
            },
            headers={
                'Authorization': f'Bearer {token}',
                'Content-Type': 'application/json',
            },
            timeout=10,
        )
    except Exception:
        pass  # 注册失败不影响主流程（推送时服务端也会自动建会话）


def check_ai_lock():
    """检查AI操作锁状态，返回 (is_locked, mode_str)"""
    locked = os.path.exists(LOCK_FILE)
    mode = 'full'
    try:
        with open(MODE_FILE, 'r', encoding='utf-8') as f:
            mode = json.load(f).get('mode', 'full')
    except Exception:
        pass
    return locked or mode == 'chat_only', mode


def handle_lock_command(text):
    """处理 @lock / @unlock 命令，返回 True 如果是锁定命令"""
    cmd = text.strip().lower()
    if cmd in ('@lock', '锁定', '仅问答'):
        _run_lock('lock')
        return True
    elif cmd in ('@unlock', '解锁', '恢复操作'):
        _run_lock('unlock')
        return True
    return False


def _run_lock(action):
    """运行 ai_lock.py"""
    lock_script = os.path.join(PROJECT_DIR, 'ai_lock.py')
    if os.path.exists(lock_script):
        subprocess.run([sys.executable, lock_script, action], timeout=30)
    else:
        # 简单模式：直接创建/删除锁文件
        if action == 'lock':
            with open(LOCK_FILE, 'w') as f:
                f.write('locked')
            print("🔒 已锁定（仅问答模式）")
        else:
            if os.path.exists(LOCK_FILE):
                os.remove(LOCK_FILE)
            print("🔓 已解锁（完全操作模式）")

# 延迟加载记忆中间件（避免import失败影响基础功能）
_memory_mw = None


def get_memory_middleware():
    """懒加载记忆中间件（faceted_memory 是可选依赖，没装时静默跳过）"""
    global _memory_mw
    if _memory_mw is None:
        try:
            sys.path.insert(0, PROJECT_DIR)
            from faceted_memory.middleware import MemoryMiddleware
            _memory_mw = MemoryMiddleware(
                db_path=MEMORY_DB,
                vocab_dir=VOCAB_DIR if os.path.exists(VOCAB_DIR) else None,
                top_k=3,
                min_score=0.1,
            )
        except ImportError:
            # 模块没装是预期情况（可选功能），不打印噪音
            _memory_mw = False
        except Exception as e:
            # 模块装了但初始化失败 —— 这才需要警告
            print(f"⚠️ 记忆系统加载失败: {e}", file=sys.stderr)
            _memory_mw = False
    return _memory_mw if _memory_mw is not False else None


_WS_REF_RE = re.compile(r'@file:([^\s]+)')


def _extract_workspace_refs(text):
    """从 text 提取 @file:xxx 引用，返回去重的相对路径列表"""
    if not text:
        return []
    seen = set()
    out = []
    for m in _WS_REF_RE.finditer(text):
        rel = m.group(1).strip().rstrip('.,;:!?)】')  # 去掉常见尾标点
        if not rel or rel in seen:
            continue
        seen.add(rel)
        out.append(rel)
    return out


# 规则块提取标记（与各规则文件中的标记保持一致）
_RULES_START = '# === IDE CLAW RULES START ==='
_RULES_END = '# === IDE CLAW RULES END ==='
# 依次尝试读取的规则文件（内容一致，取第一个可读的）
_RULES_FILES = ('.cursorrules', '.windsurfrules', '.clinerules',
                os.path.join('.github', 'copilot-instructions.md'),
                os.path.join('.kiro', 'rules.md'))

# 兜底精简版规则（所有规则文件都读不到时使用）
_FALLBACK_RULES = """## 工具调用规则（精简版）

1. **何时调用**：需要用户决策/澄清、多方案二选一、完成里程碑需审阅、长任务结束需确认时，
   必须调用 dialog.py 并阻塞等待；单步确定性小操作（读文件、列目录等）不要调用。
2. **如何调用**（必须 Blocking=true 阻塞执行，禁止异步/后台运行，禁止在聊天面板直接提问）：

```bash
python "c:/Users/FC/Desktop/IDE-claw-main/cascade/dialog.py" "要发给用户的消息" --workspace "<当前项目根目录绝对路径>"
```

3. **调用前**：先查看当前项目根目录（工作区路径），作为 --workspace 参数携带；
   再 `curl --max-time 2 http://127.0.0.1:13800/ping` 检测桌面端，
   不通则用 Start-Process 非阻塞启动 dist/ide-claw-windows/ide_claw.exe 并等 3-5 秒。
4. **脚本退出后**：立即 read_file 读取脚本打印的响应文件路径，严格执行用户指令，
   到下一个里程碑再次调用。
"""


def _load_tool_rules():
    """读取规则文档（如何调用工具/何时调用），用于附加到每次用户回复后。

    优先从项目根目录的规则文件中提取 IDE CLAW RULES 区块（单一事实来源，
    规则文件更新后这里自动同步）；全部读不到时退回内置精简版。
    """
    for rel in _RULES_FILES:
        fp = os.path.join(PROJECT_DIR, rel)
        try:
            if not os.path.isfile(fp):
                continue
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            if _RULES_START in content and _RULES_END in content:
                block = content.split(_RULES_START, 1)[1].split(_RULES_END, 1)[0]
                block = block.strip()
                if block:
                    return block
        except Exception:
            continue
    return _FALLBACK_RULES.strip()


def save_response(action, text, source='unknown', images=None, files=None, memory_context=''):
    os.makedirs(os.path.dirname(RESPONSE_FILE), exist_ok=True)
    # 解析用户输入里的 @file: 工作区文件引用
    ws_refs = _extract_workspace_refs(text)
    with open(RESPONSE_FILE, 'w', encoding='utf-8') as f:
        f.write(f"# 📱 Dialog Response\n\n")
        f.write(f"> Received: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"> Source: {source}\n")
        if WORKSPACE_DIR:
            f.write(f"> Workspace: {WORKSPACE_DIR}\n")
        f.write("\n")
        # AI操作锁：注入限制指令
        is_locked, _ = check_ai_lock()
        if is_locked:
            f.write("## 🔒 AI操作限制（仅问答模式）\n\n")
            f.write("**⚠️ 当前处于仅问答模式，严格遵守以下规则：**\n")
            f.write("1. **禁止** 调用 edit / multi_edit / write_to_file 工具\n")
            f.write("2. **禁止** 调用 run_command 工具\n")
            f.write("3. **禁止** 修改任何文件\n")
            f.write("4. **只能** 用文字回答问题\n")
            f.write("5. 如果用户要求操作，回复：'当前处于锁定模式，请先发送 @unlock 解锁'\n\n")
        f.write(f"## ACTION\n\n```\n{action}\n```\n\n")
        f.write(f"## 用户指令\n\n```\n{text}\n```\n")
        if images:
            f.write(f"\n## 📷 附件图片\n\n")
            for img in images:
                f.write(f"- `{img}`\n")
        if files:
            f.write(f"\n## 📎 附件文件\n\n")
            for fp in files:
                f.write(f"- `{fp}`\n")
        if ws_refs:
            f.write(f"\n## 📂 工作区引用文件\n\n")
            f.write("用户通过客户端 `@` 引用了以下工作区文件，请用 `read_file` 读取它们的内容来理解指令：\n\n")
            ref_base = WORKSPACE_DIR or PROJECT_DIR
            for rel in ws_refs:
                abs_path = os.path.normpath(os.path.join(ref_base, rel))
                exists = os.path.isfile(abs_path)
                marker = '' if exists else ' ⚠️ (文件不存在)'
                f.write(f"- `{abs_path}`{marker}\n")
        if memory_context:
            f.write(f"\n{memory_context}\n")
        # 每次回复自动附加规则文档：AI 读取本文件时被重新提醒工具调用规则
        f.write(f"\n---\n\n## 📐 AI 必读：工具调用规则（每次回复自动附加）\n\n")
        f.write("**执行完上面的用户指令后，到达下一个交互节点时，严格按以下规则继续通过 dialog.py 与用户通信：**\n\n")
        if WORKSPACE_DIR:
            f.write(f"**当前工作区: `{WORKSPACE_DIR}`，下次调用 dialog.py 时必须继续携带 "
                    f"`--workspace \"{WORKSPACE_DIR}\"`，并读取本文件（{RESPONSE_FILE}）。**\n\n")
        f.write(_load_tool_rules())
        f.write("\n")


def extract_text(command, params_str):
    text = ''
    try:
        params = json.loads(params_str) if params_str else {}
        if isinstance(params, dict):
            text = params.get('text', str(params))
        else:
            text = str(params)
    except (json.JSONDecodeError, TypeError):
        text = params_str or ''
    return text


def download_file(server_url, token, download_url):
    """下载文件并保存到本地，返回本地路径"""
    import requests
    try:
        full_url = f"{server_url}{download_url}&token={token}" if '?' in download_url else f"{server_url}{download_url}?token={token}"
        r = requests.get(full_url, headers={"Authorization": f"Bearer {token}"}, timeout=30)
        if r.status_code == 200:
            # 从Content-Disposition或URL提取文件名
            fname = download_url.split('/')[-1].split('?')[0]
            if 'Content-Disposition' in r.headers:
                cd = r.headers['Content-Disposition']
                if 'filename=' in cd:
                    fname = cd.split('filename=')[-1].strip('"')
            save_dir = os.path.join(PROJECT_DIR, 'data', 'received_files')
            os.makedirs(save_dir, exist_ok=True)
            save_path = os.path.join(save_dir, f"{int(time.time())}_{fname}")
            with open(save_path, 'wb') as f:
                f.write(r.content)
            return save_path
    except Exception as e:
        print(f"⚠️ 下载文件失败: {e}", file=sys.stderr)
    return None


def desktop_is_running():
    """GET /ping 检测同机桌面端 ide_claw.exe 是否在运行"""
    try:
        import requests
        r = requests.get(f"http://127.0.0.1:{IPC_PORT}/ping", timeout=2)
        return r.status_code == 200
    except Exception:
        return False


def run_local_ipc(message, received, reply_data, session_id='', workspace=''):
    """本地 IPC：直连同机桌面端 ide_claw.exe（127.0.0.1:13800）。

    桌面端启动后会在本机暴露：
      GET  /ping     → {"status":"ok","has_pending":bool} 健康检查
      POST /message  → 接收 {"message", "session_id", "workspace", "workspace_name"}，
                       桌面端按 workspace 自动创建/切换到对应对话区并显示消息，
                       长轮询挂起直到用户在桌面端输入回复（单次最长约 30 分钟），
                       返回 {"text": "...", "action": "reply", "source": "desktop"}

    桌面端没运行时静默退出，由手机端 / 远程 WebSocket 通道兜底。
    """
    try:
        import requests
    except ImportError:
        print("⚠️ requests未安装，无法使用本地 IPC", file=sys.stderr)
        return

    base = f"http://127.0.0.1:{IPC_PORT}"
    if not desktop_is_running():
        return  # 桌面端未运行

    print(f"🖥️ 已直连本地桌面端 ide_claw.exe ({base})")
    sys.stdout.flush()

    payload = {"message": message}
    if session_id:
        payload["session_id"] = session_id
    if workspace:
        payload["workspace"] = workspace
        payload["workspace_name"] = workspace_folder_name(workspace)

    # POST /message 长轮询：任一端先回复后 received 置位，本通道自动作废
    while not received.is_set():
        try:
            r = requests.post(
                f"{base}/message",
                json=payload,
                timeout=1860,  # 桌面端单次等待上限 30 分钟，留缓冲
            )
            if r.status_code != 200:
                return
            data = r.json()
            action = data.get('action', 'reply')
            if action == 'timeout':
                continue  # 桌面端等待超时（无人回复），重新挂起继续等
            if action == 'shutdown':
                return  # 桌面端已退出，由远程通道兜底
            text = (data.get('text') or '').strip()
            if text and not received.is_set():
                reply_data['action'] = 'continue'
                reply_data['text'] = text
                reply_data['source'] = data.get('source', 'desktop')
                received.set()
            return
        except Exception:
            return  # IPC 断开（exe 被关闭等），由远程通道兜底


def _load_last_reply():
    """读取上一次响应文件中的回复文本，用于去重"""
    try:
        if not os.path.exists(RESPONSE_FILE):
            return ''
        with open(RESPONSE_FILE, 'r', encoding='utf-8') as f:
            content = f.read()
        # 提取“用户指令”代码块内容
        marker = '## 用户指令'
        if marker in content:
            after = content.split(marker, 1)[1]
            if '```\n' in after:
                parts = after.split('```\n', 1)
                if len(parts) >= 2:
                    return parts[1].split('\n```')[0].strip()
    except Exception:
        pass
    return ''


def run_ws_listener(server_url, session_id, token, received, reply_data, push_done_time=None):
    """WebSocket 监听用户回复（手机端或桌面端均可）"""
    try:
        import websocket
    except ImportError:
        print("⚠️ websocket-client未安装，无法监听回复", file=sys.stderr)
        return

    ws_base = server_url.replace('https://', 'wss://').replace('http://', 'ws://')
    ws_url = f"{ws_base}/ws?token={token}&session_id={session_id}&role=pc"
    _debounce_sec = 3  # 连接后忽略 N 秒内到达的旧消息
    _ws_connected_time = [0]  # 记录 WS 连接成功时间
    _last_reply = _load_last_reply()  # 上一次回复内容，用于去重

    def on_message(ws, msg):
        if received.is_set():
            ws.close()
            return
        # 防抖：忽略 WS 连接后立即到达的旧消息（服务器缓冲）
        if _ws_connected_time[0] and (time.time() - _ws_connected_time[0]) < _debounce_sec:
            return
        try:
            data = json.loads(msg)
            msg_type = data.get('type', '')

            if msg_type == 'command':
                cmd_data = data.get('data', {})
                command = cmd_data.get('command', 'reply')
                params = cmd_data.get('params', '{}')
                text = extract_text(command, params)
                if not received.is_set():
                    if _last_reply and text.strip() == _last_reply:
                        return  # 去重：与上次回复相同，忽略
                    reply_data['action'] = command
                    reply_data['text'] = text
                    reply_data['source'] = 'phone'
                    received.set()
                    ws.close()

            elif msg_type == 'message':
                msg_data = data.get('data', {})
                if msg_data.get('sender') == 'mobile':
                    content = msg_data.get('content', '')
                    caption = msg_data.get('caption', '')
                    msg_sub_type = msg_data.get('msg_type', 'text')
                    has_image = msg_data.get('has_image', False)
                    download_url = msg_data.get('download_url', '')
                    file_name = msg_data.get('file_name', '')

                    if not received.is_set():
                        # Use caption as primary text if available
                        display_text = caption if caption else content
                        if _last_reply and display_text.strip() == _last_reply:
                            return  # 去重：与上次回复相同，忽略

                        reply_data['action'] = f'message_{msg_sub_type}'
                        reply_data['text'] = display_text
                        reply_data['source'] = 'phone'
                        reply_data['file_name'] = file_name

                        # Download image/file if available
                        if download_url:
                            local_path = download_file(server_url, token, download_url)
                            if local_path:
                                reply_data['file_path'] = local_path
                                if has_image:
                                    reply_data.setdefault('images', []).append(local_path)

                        received.set()
                        ws.close()
        except Exception as e:
            print(f"⚠️ WS消息解析错误: {e}", file=sys.stderr)

    def on_open(ws):
        _ws_connected_time[0] = time.time()
        def heartbeat():
            while not received.is_set():
                try:
                    ws.send(json.dumps({"type": "ping"}))
                except:
                    break
                time.sleep(15)
        threading.Thread(target=heartbeat, daemon=True).start()

    _ws_retry_count = [0]

    def on_error(ws, error):
        if not received.is_set():
            _ws_retry_count[0] += 1
            if _ws_retry_count[0] >= 3:
                print(f"⚠️ WS多次断开，仍在重连...", file=sys.stderr)
                _ws_retry_count[0] = 0

    def on_close(ws, code, msg):
        pass  # 静默断开，自动重连

    ssl_opts = {"cert_reqs": ssl.CERT_NONE}

    while not received.is_set():
        try:
            ws = websocket.WebSocketApp(
                ws_url,
                on_message=on_message,
                on_error=on_error,
                on_close=on_close,
                on_open=on_open,
            )
            ws_thread = threading.Thread(
                target=lambda: ws.run_forever(sslopt=ssl_opts, ping_interval=20, ping_timeout=10),
                daemon=True,
            )
            ws_thread.start()
            while ws_thread.is_alive() and not received.is_set():
                received.wait(timeout=1)
            if received.is_set():
                break
            time.sleep(2)  # 快速重连
        except Exception as e:
            if not received.is_set():
                _ws_retry_count[0] += 1
                if _ws_retry_count[0] >= 3:
                    print(f"⚠️ WS连接错误，仍在重试...", file=sys.stderr)
                    _ws_retry_count[0] = 0
                time.sleep(3)


# 可存入记忆的文本文件后缀
_TEXT_EXTS = {'.md', '.txt', '.py', '.json', '.yaml', '.yml', '.toml', '.csv', '.html', '.css', '.js', '.ts', '.go', '.dart', '.sh', '.bat'}
# 文件大小上限（超过则截断存储）
_MAX_FILE_SIZE = 50000  # 50KB


def _store_file_content(mw, file_path):
    """将文本文件内容存入记忆库"""
    try:
        ext = os.path.splitext(file_path)[1].lower()
        if ext not in _TEXT_EXTS:
            return
        if not os.path.isfile(file_path):
            return
        size = os.path.getsize(file_path)
        if size == 0 or size > _MAX_FILE_SIZE * 2:
            return  # 空文件或过大文件跳过
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read(_MAX_FILE_SIZE)
        if len(content) < 20:
            return  # 内容太短，不值得存储
        fname = os.path.basename(file_path)
        summary = f"📄 文件: {fname} | {content[:120].replace(chr(10), ' ')}"
        mw.store(
            content=content,
            summary=summary,
            metadata={"type": "file", "path": file_path, "file_name": fname, "size": size}
        )
    except Exception as e:
        print(f"⚠️ 存储文件记忆失败 [{file_path}]: {e}", file=sys.stderr)


def _store_referenced_files(mw, message):
    """扫描消息中引用的文件路径，将其内容存入记忆库"""
    import re
    # 匹配常见的文件路径模式（Windows绝对路径或相对路径）
    patterns = [
        r'[A-Za-z]:[/\\][\w\-./\\]+\.\w+',  # Windows绝对路径
        r'(?:^|\s)\.?/?[\w\-]+(?:/[\w\-]+)*\.\w+',  # 相对路径
    ]
    paths = set()
    for pattern in patterns:
        for match in re.finditer(pattern, message):
            paths.add(match.group().strip())

    for p in paths:
        # 标准化路径
        p = p.replace('\\', '/')
        if not os.path.isfile(p):
            # 尝试在项目目录下查找
            alt = os.path.join(PROJECT_DIR, p)
            if os.path.isfile(alt):
                p = alt
            else:
                continue
        _store_file_content(mw, p)


# 工作区扫描时跳过的目录
_WS_SKIP_DIRS = {
    '.git', '.windsurf', '.next', '.idea', '.vscode', '.venv', 'venv',
    'node_modules', '__pycache__', 'data', 'dist', 'build', 'target',
    'out', 'bin', 'obj',
}
# 工作区扫描时跳过的文件后缀
_WS_SKIP_EXTS = {
    '.pyc', '.pyo', '.dll', '.so', '.dylib', '.exe', '.zip', '.tar', '.gz',
    '.apk', '.aab', '.ipa', '.bin', '.lock', '.class', '.jar', '.o',
}
# 单文件大小上限（>5MB 不上报）
_WS_MAX_FILE_SIZE = 5 * 1024 * 1024
# 整个工作区最多上报多少文件
_WS_MAX_FILES = 2000


def _list_workspace_files(project_dir):
    """扫工作区文件树（跳过常见忽略目录/二进制），返回 [{path, size}]"""
    out = []
    if not os.path.isdir(project_dir):
        return out
    for root, dirs, fs in os.walk(project_dir):
        # 原地修改 dirs：跳过隐藏目录和常见忽略目录
        dirs[:] = [d for d in dirs if not d.startswith('.') and d not in _WS_SKIP_DIRS]
        for f in fs:
            if f.startswith('.'):
                continue
            ext = os.path.splitext(f)[1].lower()
            if ext in _WS_SKIP_EXTS:
                continue
            fp = os.path.join(root, f)
            try:
                st = os.stat(fp)
                if st.st_size > _WS_MAX_FILE_SIZE:
                    continue
                rel = os.path.relpath(fp, project_dir).replace('\\', '/')
                out.append({'path': rel, 'size': st.st_size})
                if len(out) >= _WS_MAX_FILES:
                    return out
            except OSError:
                continue
    return out


def _sync_workspace_files(server_url, session_id, token, project_dir):
    """把工作区文件清单上报到服务器，供客户端 @ 引用时拉取。失败 silent。"""
    try:
        import requests
        files = _list_workspace_files(project_dir)
        requests.post(
            f"{server_url}/api/sessions/files",
            json={
                'session_id': session_id,
                'workspace_root': project_dir,
                'files': files,
            },
            headers={
                'Authorization': f'Bearer {token}',
                'Content-Type': 'application/json',
            },
            timeout=10,
        )
    except Exception:
        pass  # 上报失败不影响主流程


def _send_ack_feedback(server_url, session_id, token, user_text):
    """收到用户回复后立刻 push '已收到指令: <预览>' 给客户端，让用户立即看到反馈。"""
    try:
        import requests
        preview = (user_text or '').strip().replace('\n', ' ')
        if len(preview) > 60:
            preview = preview[:60] + '...'
        requests.post(
            f"{server_url}/api/push",
            json={
                'session_id': session_id,
                'content': f'📥 AI 已收到指令: {preview}',
                'msg_type': 'text',
                'is_final': True,
            },
            headers={
                'Authorization': f'Bearer {token}',
                'Content-Type': 'application/json',
            },
            timeout=5,
        )
    except Exception:
        pass  # 反馈失败不影响主流程


def upload_file_to_phone(server_url, session_id, token, file_path, caption=''):
    """上传文件/图片到手机，使用multipart/form-data"""
    import requests
    try:
        if not os.path.isfile(file_path):
            print(f"⚠️ 文件不存在: {file_path}", file=sys.stderr)
            return False
        fname = os.path.basename(file_path)
        with open(file_path, 'rb') as f:
            files = {'file': (fname, f, 'application/octet-stream')}
            data = {'session_id': session_id, 'sender': 'pc', 'caption': caption or fname}
            headers = {'Authorization': f'Bearer {token}'}
            r = requests.post(f"{server_url}/api/files/upload", files=files, data=data, headers=headers, timeout=60)
        if r.status_code == 200:
            resp = r.json()
            if resp.get('success'):
                print(f"📎 文件已推送: {fname} ({resp.get('file_id', '')})")
                return True
            else:
                print(f"⚠️ 上传失败: {resp}", file=sys.stderr)
        else:
            print(f"⚠️ 上传失败 (HTTP {r.status_code}): {r.text[:200]}", file=sys.stderr)
    except Exception as e:
        print(f"⚠️ 上传异常: {e}", file=sys.stderr)
    return False


def main():
    global RESPONSE_FILE, WORKSPACE_DIR

    if len(sys.argv) < 2:
        print('用法: python dialog.py "消息内容" [--file path] [--workspace dir]', file=sys.stderr)
        sys.exit(1)

    # 解析参数：message 和可选的 --file / --workspace
    message = sys.argv[1]
    attach_files = []
    workspace = ''
    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == '--file' and i + 1 < len(sys.argv):
            attach_files.append(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == '--workspace' and i + 1 < len(sys.argv):
            workspace = sys.argv[i + 1].strip()
            i += 2
        else:
            i += 1

    # 加载推送配置
    config_path = os.path.join(SCRIPT_DIR, 'config', 'push_config.json')
    server_url = session_id = token = ''
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        server_url = cfg.get('server_url', '')
        session_id = cfg.get('session_id', '')
        token = cfg.get('auth_token', '') or cfg.get('token', '')
    except Exception:
        pass

    if not (server_url and session_id and token):
        print("❌ 推送配置缺失，请编辑 cascade/config/push_config.json", file=sys.stderr)
        sys.exit(1)

    # 多工作区会话：--workspace 传入时按目录派生会话，覆盖配置中的默认 session
    if workspace:
        if not os.path.isdir(workspace):
            print(f"⚠️ 工作区目录不存在: {workspace}（仍继续，请检查路径）", file=sys.stderr)
        WORKSPACE_DIR = os.path.abspath(workspace).replace('\\', '/').rstrip('/')
        session_id = workspace_session_id(WORKSPACE_DIR)
        RESPONSE_FILE = workspace_response_file(session_id)
        # 同步注册会话元数据（自动创建会话 + 文件夹名作为显示名）
        _register_workspace_session(server_url, token, session_id, WORKSPACE_DIR)
        print(f"📂 工作区会话: {session_id} ({workspace_folder_name(WORKSPACE_DIR)})")
        sys.stdout.flush()

    # 在 push 前先把工作区文件清单上报到服务器
    # 客户端 @ 引用文件时会拉这个清单。
    # 异步上报：不阻塞 push（最多花 100-300ms 扫盘 + 上传，但用户体感是 push 立刻发出）
    _ws_sync_thread = threading.Thread(
        target=_sync_workspace_files,
        args=(server_url, session_id, token, WORKSPACE_DIR or PROJECT_DIR),
        daemon=True,
    )
    _ws_sync_thread.start()

    # 推送消息到 Push Server
    try:
        import requests
        _headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
        # 先发stop_typing清除省略号气泡
        try:
            requests.post(
                f"{server_url}/api/push",
                json={"session_id": session_id, "content": "", "msg_type": "stop_typing"},
                headers=_headers, timeout=5,
            )
        except Exception:
            pass
        # 再发实际消息
        requests.post(
            f"{server_url}/api/push",
            json={"session_id": session_id, "content": message, "msg_type": "text", "is_final": True},
            headers=_headers, timeout=10,
        )
        # 推送附件文件/图片
        for fp in attach_files:
            upload_file_to_phone(server_url, session_id, token, fp)
    except Exception as e:
        print(f"⚠️ 推送失败: {e}", file=sys.stderr)

    received = threading.Event()
    reply_data = {}

    # 记录推送完成时间（用于 WebSocket 防抖）
    push_done_time = time.time()

    # 启动本地 IPC：直连同机桌面端 ide_claw.exe（13800），毫秒级通道
    # 携带 session_id + workspace：桌面端按工作区自动创建/切换对话区
    t_ipc = threading.Thread(
        target=run_local_ipc,
        args=(message, received, reply_data, session_id, WORKSPACE_DIR),
        daemon=True,
    )
    t_ipc.start()

    # 启动 WebSocket 监听（手机端通过此通道回复）
    t_ws = threading.Thread(target=run_ws_listener, args=(server_url, session_id, token, received, reply_data, push_done_time), daemon=True)
    t_ws.start()

    print(f"📤 消息已推送到 IDE Claw [会话: {session_id}]")
    print(f"⏳ 等待回复...")
    sys.stdout.flush()

    # 等待回复
    try:
        while not received.is_set():
            received.wait(timeout=1)
    except KeyboardInterrupt:
        print("\n👋 已取消", file=sys.stderr)
        sys.exit(1)

    action = reply_data.get('action', 'continue')
    text = reply_data.get('text', '')
    source = reply_data.get('source', 'unknown')
    images = reply_data.get('images', [])
    file_path = reply_data.get('file_path', '')
    files = [file_path] if file_path and file_path not in images else []

    # 立即给客户端 push 一条「已收到指令」反馈，让用户立刻看到 AI 已响应
    # 异步发送，不阻塞 dialog.py 退出
    threading.Thread(
        target=_send_ack_feedback,
        args=(server_url, session_id, token, text),
        daemon=True,
    ).start()

    # === 记忆中间件：自动处理 ===
    memory_context = ""
    mw = get_memory_middleware()
    if mw and text:
        try:
            # 入站：检索相关记忆
            results = mw.search_only(text)
            if results:
                memory_context = mw._format_memory_block(results)
            # 出站（上一条AI消息）：存储到记忆库
            mw.on_outgoing(message, sender="ai")
            # 出站（引用文件）：扫描消息中的文件路径，存储文件全文
            _store_referenced_files(mw, message)
            # 入站（用户回复）：存储到记忆库
            mw.on_outgoing(text, sender="user")
            # 入站（用户发送的文件）：如果是文本文件，存储内容
            if files:
                for fp in files:
                    _store_file_content(mw, fp)
        except Exception as e:
            print(f"⚠️ 记忆处理异常: {e}", file=sys.stderr)

    save_response(action, text, source, images=images or None, files=files or None,
                  memory_context=memory_context)

    print(f"\n💬 收到回复 (来源: {source}):")
    print(f"ACTION: {action}")
    print(f"内容: {text}")
    if images:
        print(f"图片: {', '.join(images)}")
    if files:
        print(f"文件: {', '.join(files)}")
    print(f"\n📄 完整响应已保存到: {RESPONSE_FILE}")
    sys.stdout.flush()


if __name__ == '__main__':
    main()
