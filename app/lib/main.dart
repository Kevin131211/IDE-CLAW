import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'config/app_config.dart';
import 'services/api_service.dart';
import 'services/permission_service.dart';
import 'services/download_service.dart';
import 'services/notification_service.dart';
import 'services/local_ipc_service.dart';
import 'services/update_service.dart';
import 'screens/session_list_screen.dart';
import 'screens/desktop_home_screen.dart';
import 'widgets/update_dialog_listener.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端窗口配置
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1000, 700),
      minimumSize: Size(800, 500),
      center: true,
      title: 'IDE Claw',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    // 拦截关闭事件，改为最小化到托盘
    await windowManager.setPreventClose(true);
  }

  // 启动时申请所有必要权限
  await PermissionService.requestAll();
  // 初始化下载服务（加载已下载记录）
  await DownloadService().init();
  // 初始化通知服务
  await NotificationService().init();
  // 桌面端启动本地 IPC 服务（让 dialog.py 直连，不走远程服务器）
  final localIpc = LocalIpcService();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await localIpc.start();
  }
  // 手机端启动后台自动检查更新（每 24h 一次，发现新版本自动下载 APK）
  if (Platform.isAndroid) {
    unawaited(UpdateService().startBackgroundChecks());
  }
  runApp(IDEClawApp(localIpcService: localIpc));
}

class IDEClawApp extends StatefulWidget {
  final LocalIpcService? localIpcService;
  const IDEClawApp({super.key, this.localIpcService});

  @override
  State<IDEClawApp> createState() => _IDEClawAppState();
}

class _IDEClawAppState extends State<IDEClawApp>
    with WindowListener, TrayListener {
  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    if (isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initSystemTray();
    }
  }

  @override
  void dispose() {
    if (isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      trayManager.destroy();
    }
    super.dispose();
  }

  Future<void> _initSystemTray() async {
    String iconPath;
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      iconPath = '$exeDir\\app_icon.ico';
    } else {
      iconPath = 'assets/app_icon.png';
    }
    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip('IDE Claw');
    final menu = Menu(
      items: [
        MenuItem(key: 'show', label: '显示窗口'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  // 点击关闭按钮 → 隐藏窗口到托盘
  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  // 双击托盘图标 → 显示窗口
  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // 右键托盘图标 → 弹出菜单
  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  // 托盘菜单点击
  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'quit':
        await trayManager.destroy();
        await windowManager.setPreventClose(false);
        await windowManager.close();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final apiService = ApiService(
      serverUrl: AppConfig.defaultServerUrl,
      token: AppConfig.defaultToken,
    );

    return MaterialApp(
      title: 'IDE Claw',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: UpdateDialogListener(
        child: isDesktop
            ? DesktopHomeScreen(
                apiService: apiService,
                localIpcService: widget.localIpcService,
              )
            : SessionListScreen(apiService: apiService),
      ),
    );
  }
}
