import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/update_service.dart';

/// 监听 UpdateService 的事件流，自动弹窗提示用户安装新版本。
///
/// 流程：
/// - 后台检测到新版本 → 短提示"发现新版本，正在后台下载..."
/// - 下载中 → 偶尔弹进度提示
/// - 下载完成 → 弹出安装对话框（"立即安装" / "稍后"）
/// - 用户点"立即安装" → 调用 UpdateService.installDownloaded()，跳转到系统安装器
class UpdateDialogListener extends StatefulWidget {
  final Widget child;

  const UpdateDialogListener({super.key, required this.child});

  @override
  State<UpdateDialogListener> createState() => _UpdateDialogListenerState();
}

class _UpdateDialogListenerState extends State<UpdateDialogListener> {
  StreamSubscription<UpdateProgress>? _sub;
  bool _dialogShowing = false;

  @override
  void initState() {
    super.initState();
    // Android (APK) + Windows (zip) 都启用更新弹窗。其他平台 UpdateService 不工作。
    if (Platform.isAndroid || Platform.isWindows) {
      _sub = UpdateService().progressStream.listen(_handleProgress);
      // 如果服务已经跑完并处于 ready 状态（热启动场景），立刻提示
      final last = UpdateService().lastProgress;
      if (last.stage == UpdateStage.ready) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _handleProgress(last));
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _handleProgress(UpdateProgress progress) async {
    if (!mounted) return;
    switch (progress.stage) {
      case UpdateStage.available:
        _showSnack('发现新版本 ${progress.remote?.latestVersion ?? ''}，正在后台下载...');
        break;
      case UpdateStage.ready:
        await _showInstallDialog(progress);
        break;
      case UpdateStage.error:
        _showSnack('检查更新失败：${progress.errorMessage ?? '未知错误'}');
        break;
      case UpdateStage.idle:
      case UpdateStage.checking:
      case UpdateStage.upToDate:
      case UpdateStage.downloading:
      case UpdateStage.installing:
        break;
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _showInstallDialog(UpdateProgress progress) async {
    if (_dialogShowing || !mounted) return;
    final remote = progress.remote;
    if (remote == null || progress.localApkPath == null) return;

    _dialogShowing = true;
    try {
      final isWin = Platform.isWindows;
      // Android 报 apkSize（来自 /api/version）；Windows 没有权威 size，显示"已下载完成"
      final sizeText = isWin
          ? '已下载并解压完成'
          : (remote.apkSize > 0
              ? '${(remote.apkSize / 1024 / 1024).toStringAsFixed(1)} MB'
              : '未知大小');
      final changelog = remote.changelog?.trim();
      final actionLabel = isWin ? '立即更新' : '立即安装';
      final actionHint = isWin
          ? '点击"立即更新"后应用会自动关闭并替换为新版本（约 5 秒）。'
          : '点击"立即安装"后会打开系统安装器，需要你在系统界面确认安装。';

      final install = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text('发现新版本 ${remote.latestVersion}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('更新包：$sizeText'),
                if (remote.releaseDate != null && remote.releaseDate!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('发布日期：${remote.releaseDate}'),
                ],
                if (changelog != null && changelog.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('更新内容：',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(changelog),
                ],
                const SizedBox(height: 12),
                Text(actionHint),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(actionLabel),
            ),
          ],
        ),
      );

      if (install == true) {
        final ok = await UpdateService().installDownloaded();
        if (!ok && mounted) {
          _showSnack(isWin
              ? '启动更新失败，请稍后重试或访问 https://push.shoot-game.cn/ 手动下载。'
              : '启动安装器失败，请稍后重试或手动打开更新包。');
        }
      }
    } finally {
      _dialogShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
