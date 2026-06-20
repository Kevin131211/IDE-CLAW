IDE Claw 桌面端 - 文件说明
==================================================

[必需]
  ide_claw.exe        — 主程序，双击启动桌面端
  data\               — Flutter 资源
  *.dll               — Flutter 引擎和插件库

[可选 - 仅 Cascade 集成需要]
  setup-cascade.bat        — 一键安装 Python + dialog.py 依赖
  cascade-requirements.txt — pip 依赖清单

==================================================
快速上手：

  1. 只想用桌面端收消息：
       双击 ide_claw.exe 即可。
       桌面端会在 127.0.0.1:13800 起本地 IPC 服务，
       同机的 dialog.py 会直接推送过来。

  2. 想让 Cascade (Windsurf 的 AI) 通过 dialog.py 推送消息：
       a) 双击 setup-cascade.bat 安装 Python + 依赖
       b) 在你的项目里准备好 dialog.py
          (从 https://push.shoot-game.cn/ 下载完整项目)
       c) 配置 .windsurfrules 让 Cascade 知道 dialog.py 的路径

==================================================
更新：
  桌面端下次启动会自动检查更新（手机端类似）。
  最新版下载：https://push.shoot-game.cn/

技术细节：
  本地 IPC 端口   13800
  服务器地址     push.shoot-game.cn
  TURN 端口      3478 (UDP/TCP), 5349 (TLS/DTLS)
