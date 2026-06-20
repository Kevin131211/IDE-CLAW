# IDE Claw — AI 助手跨端推送与极简免安装本地 Web 消息生态 (全景指南)

> 让你的 AI 编程助手（Windsurf/Cascade、Cursor、Cline、GitHub Copilot）在需要确认、卡住或完成里程碑时，将进度推送到你的手机 App；或者在电脑上通过自动弹出的极美临时自毁 Web 网页一键敲入指令回复，实现 100% 后台挂机。

[🇺🇸 English Guide](./README_EN.md) | 简体中文说明书

---

## 📖 1. 我们解决了什么痛点？(Why IDE Claw)

在日常使用 **Windsurf (Cascade)**、**Cursor (Agent)**、**Cline / Roo Code**、**GitHub Copilot** 等高集成度 AI 辅助编程工具时，开发者往往会面临以下三个头疼的问题：

*   **不敢离开电脑屏幕**：AI 在执行复杂的重构、长编译或多步终端指令时，随时需要用户回答一些澄清问题、提供下一步决策或确认。你只要离开五分钟去泡杯咖啡，AI 就会卡在那里干等。
*   **不希望电脑后台常驻臃肿的客户端**：市面上的许多推送工具不仅需要注册、登录，还需要在电脑上安装、运行一个占内存、常驻托盘的重型客户端。
*   **无法躺着控制 AI**：当你在后台跑一个几十步的大型代码迁移任务时，你必须一直坐在电脑前守着进度。

**IDE Claw 迎来了革命性的架构升级！**
我们彻底砍掉了任何重量级的电脑桌面客户端，将其全面升级为了 **全自动本地临时 Web 服务** 结合 **手机 App 极速推送**：
1.  **电脑端 100% 免安装 (Zero Install)**：无需运行任何 `.exe`，不需要任何后台驻留进程！当 AI 遇到问题被卡住时，系统会自动在你的电脑上**秒速拉起一个极其精致的本地网页（`http://127.0.0.1:13800`）**。你直接在网页里打字并按 `Ctrl + Enter` 提交，网页在 3 秒后自动关闭，临时服务彻底自毁释放端口！
2.  **手机端跨端推送**：如果你人走开了，消息也会同时推送到你的**手机 App** 上，你可以躺在任何地方（床、沙发、户外）用手机微信般轻松打字回复 AI，控制 AI 编写代码。
3.  **多 AI IDE 自动适配**：专属辅助插件会智能探测路径并同时在当前项目自动注入 4 大核心规则文件，开箱即用。

---

## ⚙️ 2. 全景系统架构与闭环工作流原理

整个 IDE Claw 生态系统遵循以下极其严密、高效的自毁式闭环回路设计：

```
 +-----------------------------------------------------------+
 |           AI 辅助编程环境 (Windsurf, Cursor, Cline 等)      |
 |                                                           |
 | 1. 触发需要干预/点 Continue                                |
 | 2. 激活自动注入的对应规则文件（如 .cursorrules / .clinerules) |
 | 3. 阻塞调用本地的 cascade/dialog.py                          |
 +--------------------+--------------------------------------+
                      |
                      v 
            [dialog.py 推送脚本] 
            (开启双通道：WebSocket 监听手机 + 本地临时 HTTP 服务)
                      |
        +-------------+-------------+
        | (A. 自动拉起本地临时网页)  | (B. 远程 WebSocket 信令)
        | http://127.0.0.1:13800    | Push Server (中转)
        v                           v
  +-----------+               +-----------+
  | 默认浏览器 |               | 手机端 App |
  | (打字/提交) |               | (打字回复) |
  +-----+-----+               +-----+-----+
        |                           |
        +-------------+-------------+
                      |
                      v (接收到任意一端的指令回复)
             [写入 phone_response.md]
                      |
                      v (13800 端口服务自动 shutdown 自毁)
  +-----------------------------------------------------------+
  |               AI 自动读取回复，无缝继续工作                 |
  +-----------------------------------------------------------+
```

---

## 📂 3. 极详尽发布包目录文件树说明

为了让用户拿到本发布包后一目了然，我们已将庞杂的产物完美归档并整理至如下文件夹：

```
IDE-claw-release/
├── README.md                           # 📖 本中英双语总导引入口（建议先阅读）
├── README_CN.md                        # 🇨🇳 简体中文全景使用手册
├── README_EN.md                        # 🇺🇸 英文全景使用手册
│
├── Mobile/                             # 📲 手机移动端（Android 客户端）
│   └── ide-claw-latest.apk             # 最新版 Android 安装包
│
└── VSCode-Plugin/                      # 🔌 VS Code / Windsurf 专属辅助插件
    └── ide-claw-rules-injector-0.2.0.vsix # 插件安装文件（已完美去除个人路径硬编码，支持全自动智能多规则自探测写入）
```

---

## 🛠️ 4. 环境依赖要求

| 工具 | 推荐版本 | 用途 |
|------|---------|--------------|
| **Node.js** | ≥ 18 | 用于插件端（VSCode-Plugin）的修改与二次打包编译 |
| **Go** | ≥ 1.21 | 用于自建 Push Server 后端服务编译 |
| **Flutter** | ≥ 3.19 | 用于手机端 Android 源码开发和编译 |
| **Python** | ≥ 3.9 | 用于本地项目在执行推送时运行 `dialog.py`（无任何第三方依赖） |
| **Linux VPS** | 任意配置 | 用于部署 Go 消息中转服务器（需绑定域名及 SSL 证书） |

---

## 🚀 5. 全端全自动极速安装与使用指南

要想完美发挥 IDE Claw 的全部神力，仅需以下三步即可：

### 第一步：自建并部署服务器 (Go Backend)

Push Server 是用 Go 语言编写的轻量级消息转发与 WebSocket 交互中心。只需部署一次，所有工程项目即可共享该服务。

#### 1.1 编译 Go 二进制程序
在 Windows PowerShell 或 macOS 终端中运行：
```bash
cd server/
# 交叉编译成适用于 Linux VPS (amd64 架构) 的可执行二进制
$env:GOOS="linux"; $env:GOARCH="amd64"; go build -o push-server-linux .
```

#### 1.2 上传并赋予运行权限
上传编译好的二进制文件到你的 VPS：
```bash
scp push-server-linux root@你的服务器IP:/var/www/push-server/push-server
ssh root@你的服务器IP "chmod +x /var/www/push-server/push-server"
```

#### 1.3 创建 Systemd 守护进程
在你的 Linux VPS 上创建 `/etc/systemd/system/push-server.service` 配置文件：
```ini
[Unit]
Description=IDE Claw Push Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/var/www/push-server
ExecStart=/var/www/push-server/push-server
Environment=JWT_SECRET=你自定义的JWT加密密钥（必改）
Environment=PORT=18900
Environment=DB_PATH=data/push_server.db
Restart=always

[Install]
WantedBy=multi-user.target
```
载入并运行守护进程：
```bash
sudo systemctl daemon-reload
sudo systemctl enable push-server
sudo systemctl start push-server
```

#### 1.4 配置环境变量说明
| 变量名 | 默认值 | 作用描述 |
|----------|---------|-------------|
| `PORT` | `18900` | HTTP 与 WebSocket 监听端口 |
| `DB_PATH` | `data/push_server.db` | 存放会话与客户端信息的 SQLite 数据库路径 |
| `JWT_SECRET` | — | **核心安全密钥！** 强烈建议修改为复杂随机字符串 |

#### 1.5 配置 Nginx SSL 反向代理
在你的 Nginx 虚拟主机配置文件中加入反向代理配置（通常为 `/etc/nginx/sites-available/push-server`）：
```nginx
server {
    listen 443 ssl;
    server_name 你的域名.com;

    ssl_certificate /你的路径/fullchain.pem;
    ssl_certificate_key /你的路径/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:18900;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
    }
}
```
使配置生效并重载 Nginx：
```bash
sudo ln -s /etc/nginx/sites-available/push-server /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```
配置完成后，在浏览器中请求 `https://你的域名.com` 应该能看到服务的健康自检状态。

---

### 第二步：编译与安装手机端 (Mobile) 并绑定通道

#### 2.1 修改客户端网关配置
在编译前，编辑手机端源码 `app/lib/config/app_config.dart` 填写你的服务器地址：
```dart
static const String defaultServerUrl = 'https://你的域名.com';
static const String defaultSessionId = '';  // 留空，可在 App 界面自定义
static const String defaultToken = '';       // 留空，可在 App 界面自定义
```

#### 2.2 极速编译 APK
```bash
cd app/
flutter pub get
flutter build apk --release  # 输出文件位置：build/app/outputs/flutter-apk/app-release.apk
```
将编译出的 APK 安装包发送到你的安卓手机并运行。注册并登录你自建的服务器，在 App 中获取你专属的 **Push Token**（格式为 `你的会话ID:JWT密钥`）。

---

### 第三步：安装 VSIX 插件并享受“多规则格式自动注入”

我们提供了一个零配置、高智能的 VS Code 插件，它会自动帮所有工作区绑定本地的 `dialog.py` 通讯。

#### 3.1 导入 `.vsix` 插件包
1. 打开 Windsurf / VS Code，点击左侧的 `Extensions` (扩展) 图标。
2. 点击右上角的 `...` 菜单，选择 **`Install from VSIX...`** (从 VSIX 安装)。
3. 选择发布包里的 `release/ide-claw-rules-injector-0.2.0.vsix` 文件完成极速导入。

#### 3.2 神奇的零配置智能自探测与多格式注入
*   **自探测机制**：新版本 0.2.0 默认路径设为空白。插件在打开任意项目工作区时，会自动智能探测：
    1. 优先检测当前工作区下是否存在 `cascade/dialog.py`，如果是，生成的规则直接以此为绝对路径。
    2. 其次探测桌面上的 `Desktop/IDE-claw-main`。
    3. 否则，通过跨平台的 `os.homedir()` 动态算出你主目录下的真实绝对路径，**彻底去除了硬编码个人路径的尴尬**。
*   **多 IDE 适配**：探测到项目后，插件会同时自动在当前工作区注入以下五大核心规则文件：
    *   `.windsurfrules`（适配 Windsurf / Cascade 智能体）
    *   `.cursorrules`（适配 Cursor 智能体）
    *   `.clinerules`（适配 Cline / Roo Code 等 Agent）
    *   `.github/copilot-instructions.md`（适配 GitHub Copilot / VS Code Chat 规则提示）
    *   `.kiro/rules.md`（适配 Kiro 智能体；插件会自动创建 `.kiro` 文件夹并写入与其它规则文件一致的内容）
    *   **全面覆盖市面上所有的主流 AI 编程工具，任何电脑、任何 IDE 装上即用！**

---

## ⚡ 6. 本地临时 Web 输入的工作原理

当 AI 编程助手（如 Cascade）执行到需要用户干预的步骤时，触发注入的规则运行本地 `dialog.py`：
1.  **极速拉起服务**：`dialog.py` 内部会利用 Python 的标准库（无需安装任何 Flask、FastAPI 等第三方库，100% 成功率）在本地 `127.0.0.1:13800` 极速起一个临时的 HTTP 服务器。
2.  **自动唤起浏览器**：自动在电脑的默认浏览器中拉起一个 ChatGPT 黑金科技质感的极精美网页。
3.  **敲击键盘，秒级响应**：你在本地网页里能直接看到 AI 刚才提出的上下文信息，并在输入框中打字。输入完成后：
    *   点击“提交”按钮或按下 **`Ctrl + Enter`** 快捷键，数据自动回传给 Python 主进程。
    *   网页会优雅地显示一个“提交成功”的渐变小动画，并在 3 秒后**自动关闭该网页标签页**。
4.  **安全自毁**：主进程拿到回复后写入 `phone_response.md`。同时，本地临时 Web 服务立即执行 `shutdown` 关闭自己并安全释放 13800 端口。
5.  **如果手机先回复**：若你不在电脑前、使用手机端 App 完成了回复。本地临时网页服务的后台监控线程也会在 0.5 秒内自动释放端口并完美销毁！

---

## ❓ 7. FAQ & 常见问题解答手册

*   **Q: 为什么插件安装后没有在项目里生成规则文件？**
    *   答：插件具备安全检测，如果工作区中已经存在了对应的规则文件，为了防止覆盖你原有的自定义规则，它默认不会执行写入。如果你想强制生成/更新它们，可在 IDE 中按下 `Ctrl+Shift+P` (macOS 为 `Cmd+Shift+P`) 搜索并执行 **`IDE Claw：重新生成当前工作区的 AI 规则文件`** 即可。
*   **Q: 本地 13800 端口提示冲突？**
    *   答：如果 13800 端口被本地其他软件占用，`dialog.py` 具备自动端口降级重试逻辑（会自动尝试 13801 等端口），依然可以完美打开页面并成功运行！

---

## 🔒 8. 许可证 (严格专有版权声明)

**Copyright © 2026 IDE Claw. 保留所有权利 (All Rights Reserved).**

*   **禁止任何形式的二次创作**：在未获得原作者事先书面授权的情况下，严格禁止任何组织、团体或个人基于本项目进行二次创作、修改、重构、汉化、重新打包、功能裁剪或开发派生作品。
*   **禁止任何形式的重新发布**：严格禁止将本项目的任何原版、修改版或衍生版文件，打包并上传发布至任何第三方平台、网站、应用商店或代码托管平台（包括但不限于其他 GitHub 仓库、Gitee、各类论坛、下载站等）。
*   **仅限个人非商业自用**：本项目仅授予个人用户出于学习、查看、研究或个人自用的目的免费编译和本地运行。
