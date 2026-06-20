import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../services/update_service.dart';

/// 关于页面：版本号、服务器、检查更新、官方主页、备案号。
///
/// 手机端从 SessionListScreen AppBar 进入；桌面端从侧边栏 header 进入。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _version = '';
  String _build = '';
  bool _checkingUpdate = false;
  String? _checkResult; // 检查更新后的反馈文案

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _version = pkg.version;
        _build = pkg.buildNumber;
      });
    } catch (_) {
      // ignore
    }
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() {
      _checkingUpdate = true;
      _checkResult = null;
    });
    try {
      final hasUpdate = await UpdateService().checkNow(autoDownload: true);
      if (!mounted) return;
      setState(() {
        _checkResult = hasUpdate
            ? '发现新版本，正在后台下载…下载完成会自动弹窗。'
            : '当前已是最新版本。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checkResult = '检查失败：$e';
      });
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }
  }

  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败：$url')),
        );
      }
    }
  }

  String _platformLabel() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return Platform.operatingSystem;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final supportsAutoUpdate = Platform.isAndroid || Platform.isWindows;

    return Scaffold(
      appBar: AppBar(
        title: const Text('关于'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        children: [
          // ===== 头部：图标 + 名字 + 版本 =====
          Center(
            child: Column(
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    Icons.bolt,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'IDE Claw',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _version.isEmpty
                      ? '加载中…'
                      : '版本 $_version (build $_build) · ${_platformLabel()}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // ===== 操作卡片 =====
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                if (supportsAutoUpdate)
                  ListTile(
                    leading: _checkingUpdate
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.system_update_alt),
                    title: const Text('检查更新'),
                    subtitle: Text(
                      _checkResult ?? '从官方服务器拉取最新版本信息',
                    ),
                    trailing: _checkingUpdate ? null : const Icon(Icons.chevron_right),
                    onTap: _checkingUpdate ? null : _checkForUpdate,
                  ),
                if (supportsAutoUpdate) const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('服务器'),
                  subtitle: SelectableText(AppConfig.defaultServerUrl),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.auto_mode_outlined),
                  title: Text('Cascade 自动续接'),
                  subtitle: Text(
                    'dialog.py 收到回复后，会自动按 Windsurf 的 Continue 按钮，'
                    '让暂停的 Cascade 恢复对话（仅 Windows + 已装 uiautomation）',
                  ),
                  isThreeLine: true,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.public),
                  title: const Text('官方主页'),
                  subtitle: const Text('https://push.shoot-game.cn/'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _openUrl('https://push.shoot-game.cn/'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('更新日志'),
                  subtitle: const Text('查看历史版本变更'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _openUrl('https://push.shoot-game.cn/#changelog'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ===== 备案号 =====
          Center(
            child: TextButton(
              onPressed: () => _openUrl('https://beian.miit.gov.cn/'),
              child: Text(
                '粤ICP备2026002668号-1',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
          Center(
            child: Text(
              '© 2026 IDE Claw',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
