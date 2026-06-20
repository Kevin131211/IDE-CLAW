# IDE Claw — AI Assistant Cross-Terminal Notification & Zero-Install Web Ecosystem (Full Guide)

> Let your AI coding assistant (Windsurf/Cascade, Cursor, Cline, GitHub Copilot) push progress to your Android App, or let you submit instructions on your computer via an automatically popping-up temporary self-destructing local Web server, enabling 100% background programming.

[🇨🇳 Chinese Guide](./README_CN.md) | English Guide

---

## 📖 1. What Pain Points Do We Solve? (Why IDE Claw)

During daily usage of high-agentic AI coding assistants like **Windsurf (Cascade Agent)**, **Cursor**, **Cline / Roo Code**, or **GitHub Copilot**, developers often face three frustrating bottlenecks:

*   **Tethered to the screen**: When AI is executing complex refactoring, long compilation tasks, or multi-step terminal commands, it frequently pauses to wait for users to clarify generation paths. If you walk away for even five minutes, the AI stalls.
*   **Hate heavy desktop background clients**: Most notification systems force you to install, run, and maintain a heavy desktop application running constantly in the system tray, consuming memory and background resources.
*   **Unable to monitor progress on the go**: When running a massive code migration task while relaxing on the sofa, there is no way to monitor the AI's execution status or respond to questions or confirmation prompts.

**IDE Claw introduces a revolutionary architectural paradigm!**
We have completely stripped away heavy binaries and desktop applications, replacing them with a **fully-automated local lightweight HTTP service** combined with an **Android Mobile App**:
1.  **100% Zero-Install on Computer**: No `.exe` to download, no daemon processes to keep running in the background! When the AI gets stuck, the system automatically spins up a **lightweight, elegant web page locally (`http://127.0.0.1:13800`)** in your default browser. Simply type your feedback and press `Ctrl + Enter` to submit. The browser tab closes automatically in 3 seconds, and the temporary HTTP server self-destructs instantly!
2.  **Stuck-Alert Auto-Pushes**: If you walk away, the push alert goes straight to your **Mobile App**. Reply remotely from your sofa or bed, and the AI resumes coding.
3.  **Multi AI IDE Adaptability**: The helper extension automatically detects paths and injects 4 major core rules files into your workspace, working out of the box on any AI IDE.

---

## ⚙️ 2. Architectural Design & Closed-Loop Workflow

The entire IDE Claw ecosystem operates on the following highly reliable and self-destructing closed-loop feedback loop:

```
 +-----------------------------------------------------------+
 |       AI Coding Environment (Windsurf, Cursor, Cline, etc) |
 |                                                           |
 | 1. Triggers intervention or question                      |
 | 2. Activates the auto-injected rules (e.g. .cursorrules)  |
 | 3. Blocks & calls local cascade/dialog.py                 |
 +--------------------+--------------------------------------+
                      |
                      v 
            [dialog.py Push Script] 
            (Spins up WebSocket for mobile + Temporary HTTP Server)
                      |
        +-------------+-------------+
        | (A. Auto Opens Webpage)   | (B. Remote WebSocket Signal)
        | http://127.0.0.1:13800    | Push Server (Relay)
        v                           v
  +-----------+               +-----------+
  |  Browser  |               |  Mobile   |
  |  Tab      |               |    App    |
  +-----+-----+               +-----+-----+
        |                           |
        +-------------+-------------+
                      |
                      v (Receives reply from either end)
             [Writes to phone_response.md]
                      |
                      v (Port 13800 HTTP Server self-destructs)
  +-----------------------------------------------------------+
  |               AI reads response, resumes work             |
  +-----------------------------------------------------------+
```

---

## 📂 3. Release Directory Tree

The distribution package has been organized into clean folders for immediate distribution. We suggest keeping this layout after extraction:

```
IDE-claw-release/
├── README.md                           # 📖 Multi-language Gateway Entry
├── README_CN.md                        # 🇨🇳 Chinese Full Guide
├── README_EN.md                        # 🇺🇸 English Full Guide
│
├── Mobile/                             # 📲 Mobile App (Android Client)
│   └── ide-claw-latest.apk             # Android installer
│
└── VSCode-Plugin/                      # 🔌 VS Code Helper Extension
    └── ide-claw-rules-injector-0.2.0.vsix # VSIX extension package (zero hardcoded paths, auto-detection, multi-rules)
```

---

## 🛠️ 4. Prerequisites

| Tool | Recommended Version | Required For |
|------|---------------------|--------------|
| **Node.js** | ≥ 18 | VS Code plugin repackaging & compilation |
| **Go** | ≥ 1.21 | Self-hosted Push Server backend compilation |
| **Flutter** | ≥ 3.19 | Android Mobile App development and compilation |
| **Python** | ≥ 3.9 | Running `dialog.py` locally in workspaces (Zero dependencies) |
| **Linux VPS** | Any | Hosting the Go Relay Server (Requires a Domain & SSL) |

---

## 🚀 5. Full Installation & Usage Guide

Assemble the ecosystem following these three simple steps:

### Step 1: Deploy Push Server (Go Backend)

The Push Server is a lightweight Go service. Deploy it on any Linux VPS with a domain and SSL certificate.

#### 1.1 Compile Go Binary
On Windows PowerShell or macOS terminal:
```bash
cd server/
# Cross-compile for Linux VPS (amd64)
$env:GOOS="linux"; $env:GOARCH="amd64"; go build -o push-server-linux .
```

#### 1.2 Upload and Run
Upload the compiled binary to your VPS:
```bash
scp push-server-linux root@your-vps-ip:/var/www/push-server/push-server
ssh root@your-vps-ip "chmod +x /var/www/push-server/push-server"
```

#### 1.3 Create Systemd Daemon Service
Create `/etc/systemd/system/push-server.service` on your Linux VPS:
```ini
[Unit]
Description=IDE Claw Push Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/var/www/push-server
ExecStart=/var/www/push-server/push-server
Environment=JWT_SECRET=your-jwt-secret-key-change-me
Environment=PORT=18900
Environment=DB_PATH=data/push_server.db
Restart=always

[Install]
WantedBy=multi-user.target
```
Start and enable the service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable push-server
sudo systemctl start push-server
```

#### 1.4 Environment Variables
| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `18900` | HTTP listening port |
| `DB_PATH` | `data/push_server.db` | SQLite database file storage path |
| `JWT_SECRET` | — | **Must change!** JWT Token encryption secret |

#### 1.5 Nginx Reverse Proxy (SSL Config)
Configure your Nginx block (typically in `/etc/nginx/sites-available/push-server`):
```nginx
server {
    listen 443 ssl;
    server_name your-domain.com;

    ssl_certificate /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;

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
Link and reload Nginx:
```bash
sudo ln -s /etc/nginx/sites-available/push-server /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

---

### Step 2: Build & Install Mobile App (Android)

#### 2.1 Configure Client-side Endpoint
Edit `app/lib/config/app_config.dart` to match your newly deployed Push Server:
```dart
static const String defaultServerUrl = 'https://your-domain.com';
static const String defaultSessionId = '';  // set in mobile UI
static const String defaultToken = '';       // set in mobile UI
```

#### 2.2 Compile APK
```bash
cd app/
flutter pub get
flutter build apk --release  # Output path: build/app/outputs/flutter-apk/app-release.apk
```
Transfer the APK to your Android device and install it. Upon launching, register/login and grab your exclusive **Push Token**.

---

### Step 3: Install VSIX Extension & Enjoy Multi-Rules Auto-Injection

We designed a lightweight VS Code Extension to eliminate the painful manual absolute-path configurations.

#### 3.1 Install `.vsix` Extension
1. Open Windsurf or VS Code.
2. Go to the **Extensions** sidebar.
3. Click the `...` menu in the top-right corner, and select **`Install from VSIX...`**.
4. Choose the packaged `release/ide-claw-rules-injector-0.2.0.vsix` file.

#### 3.2 Magic Path Auto-Detection
The extension leaves all config paths blank by default. When opening any workspace, it automatically detects paths dynamically:
*   Checks if `cascade/dialog.py` exists in your active workspace. If so, it uses it.
*   Otherwise, fallback to standard locations (like `Desktop/IDE-claw-main`) or relative to the user's home directory (`os.homedir()`).

#### 3.3 Multi-AI IDE Rule File Auto Injection
Once a project is detected, the extension automatically injects the core communication rules into five major rules formats simultaneously in your workspace root:
*   **`.windsurfrules`** (Windsurf / Cascade agent)
*   **`.cursorrules`** (Cursor agent)
*   **`.clinerules`** (Cline / Roo Code agents)
*   **`.github/copilot-instructions.md`** (GitHub Copilot / VS Code Chat)
*   **`.kiro/rules.md`** (Kiro agent; the extension auto-creates the `.kiro` folder and writes the same rules content as the other files)

---

## ⚡ 6. How Local Web Server Popup Works

When the AI assistant runs into blocks and calls `dialog.py`:
1.  **Lightweight HTTP Service**: `dialog.py` immediately spins up a temporary HTTP server on local port `127.0.0.1:13800` using Python's native standard libraries (100% success rate without any external dependencies).
2.  **Auto Browser Pull**: It automatically opens a gorgeous, ChatGPT-themed flat webpage in your system's default browser.
3.  **Millisecond Response**: You review the context, type your response, and press **`Ctrl + Enter`** (or click Submit).
4.  **Auto Closing**: The browser displays a success animation and **automatically closes the tab in 3 seconds**.
5.  **Self-Destruction**: Once the reply is saved to `phone_response.md`, the Python process shut down the server, releases port 13800, and exits. 
6.  **Mobile Reply Fallback**: If you reply on your Mobile App first, a background daemon thread shuts down the local port 13800 in 0.5s to cleanly free up port resources.

---

## ❓ 7. FAQ & Troubleshooting

*   **Q: Why are rule files not generated in my workspace?**
    *   A: If the rule files already exist, the extension will not overwrite them by default. To force regenerate them, press `Ctrl+Shift+P` (or `Cmd+Shift+P`), and run **`IDE Claw: Regenerate AI rule files for current workspace`**.
*   **Q: Local port 13800 is conflicted?**
    *   A: If port 13800 is taken, `dialog.py` automatically retries on 13801, and still opens the web interface smoothly. No manual port-reallocation needed.

---

## 🔒 8. License (Strict Proprietary Notice)

**Copyright © 2026 IDE Claw. All Rights Reserved.**

*   **No Derivative Works**: Modification, refactoring, repackaging, translation, or creation of derivative works based on this project in any form is **STRICTLY PROHIBITED** without prior written consent from the author.
*   **No Redistribution**: Uploading, distributing, mirror hosting, or publishing any original or modified files of this project to any other platforms, websites, app stores, or VCS platforms (e.g. other Gitee/GitHub repositories) is **STRICTLY PROHIBITED**.
*   **Personal Use Only**: Permission is granted solely to individual users to compile, view, and run this code locally for personal, non-commercial use.
