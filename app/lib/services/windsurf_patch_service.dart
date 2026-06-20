import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windsurf 桌面端补丁服务（仅 Windows/macOS/Linux 桌面端可用）
///
/// 接收到 windsurf_switch 命令后的处理流程（"软切换"模式，**不**修改 binary）：
///   1. 把待切换账号的 password 复制到剪贴板（用户登录时直接粘贴）
///   2. 终止当前 Windsurf 进程
///   3. 清空 globalStorage 中 Codeium / windsurf 扩展相关的 token 缓存
///   4. 启动 Windsurf（如果之前在跑）
///   5. 弹通知告知用户：用 X 邮箱登录（密码已复制）
///
/// 这个方案不依赖逆向 Windsurf 内部存储格式，对 Windsurf 版本兼容性强。
/// 缺点：用户仍需手动点一次 "Sign in with email"，没有完全无感切换。
/// （要做无感切换需要修补 extension.js，每次 Windsurf 更新都会失效，风险高，已弃用。）
class WindsurfPatchService {
  /// 执行账号切换
  ///
  /// data 来自 WS 推送的 windsurf_switch 事件，包含：
  ///   email, id_token, refresh_token, auth1_token, account_id, reason
  ///
  /// 返回 {success: bool, message: string, paths: [...] }
  static Future<Map<String, dynamic>> performSwitch({
    required String email,
    String password = '',
    String reason = 'manual',
    bool restartWindsurf = true,
    bool clearAuthState = true,
  }) async {
    if (!_isDesktop()) {
      return {
        'success': false,
        'message': '仅桌面端支持自动切换',
      };
    }

    final logs = <String>[];
    final installRoot = await _findWindsurfInstallRoot();
    final globalStorageRoot = _windsurfGlobalStorageRoot();

    logs.add('install_root=${installRoot ?? "(未找到)"}');
    logs.add('global_storage=${globalStorageRoot ?? "(未找到)"}');

    // 1. 复制密码到剪贴板（如果有）
    if (password.isNotEmpty) {
      try {
        await Clipboard.setData(ClipboardData(text: password));
        logs.add('密码已复制到剪贴板');
      } catch (e) {
        logs.add('复制密码失败: $e');
      }
    }

    // 2. kill Windsurf 进程
    final wasRunning = await _isWindsurfRunning();
    if (wasRunning) {
      final killed = await _killWindsurf();
      logs.add(killed ? '已终止 Windsurf 进程' : 'Windsurf 进程终止失败/未在跑');
      // 等进程完全退出
      await Future.delayed(const Duration(milliseconds: 800));
    } else {
      logs.add('Windsurf 当前未运行');
    }

    // 3. 清空 codeium / windsurf 扩展缓存
    if (clearAuthState && globalStorageRoot != null) {
      final cleared = await _clearWindsurfAuthCache(globalStorageRoot);
      logs.add('清空缓存: $cleared 个目录/文件');
    }

    // 4. 重启 Windsurf
    if (restartWindsurf && (wasRunning || installRoot != null)) {
      final exe = installRoot != null ? _findWindsurfExe(installRoot) : null;
      if (exe != null) {
        try {
          await Process.start(exe, [], mode: ProcessStartMode.detached);
          logs.add('已启动 Windsurf: $exe');
        } catch (e) {
          logs.add('启动 Windsurf 失败: $e');
        }
      } else {
        logs.add('未找到 Windsurf 可执行文件，跳过重启');
      }
    }

    return {
      'success': true,
      'message': '切换流程完成（请在 Windsurf 中用 $email 登录，密码已复制）',
      'email': email,
      'reason': reason,
      'logs': logs,
    };
  }

  static bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  /// 找 Windsurf 安装目录
  static Future<String?> _findWindsurfInstallRoot() async {
    final candidates = <String>[];

    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      final programFiles = Platform.environment['PROGRAMFILES'] ?? r'C:\Program Files';
      final programFiles86 = Platform.environment['PROGRAMFILES(X86)'] ??
          r'C:\Program Files (x86)';
      candidates.addAll([
        '$localAppData\\Programs\\Windsurf',
        '$programFiles\\Windsurf',
        '$programFiles86\\Windsurf',
      ]);
    } else if (Platform.isMacOS) {
      candidates.add('/Applications/Windsurf.app/Contents/Resources/app');
    } else if (Platform.isLinux) {
      candidates.addAll([
        '/opt/windsurf',
        '/usr/share/windsurf',
        '${Platform.environment['HOME']}/.local/share/windsurf',
      ]);
    }

    for (final p in candidates) {
      if (await Directory(p).exists()) {
        return p;
      }
    }
    return null;
  }

  /// 找 Windsurf 可执行文件
  static String? _findWindsurfExe(String installRoot) {
    if (Platform.isWindows) {
      final exe = '$installRoot\\Windsurf.exe';
      if (File(exe).existsSync()) return exe;
    } else if (Platform.isMacOS) {
      // installRoot = /Applications/Windsurf.app/Contents/Resources/app
      // 启动用 'open -a /Applications/Windsurf.app'
      return '/Applications/Windsurf.app';
    } else if (Platform.isLinux) {
      final exe = '$installRoot/windsurf';
      if (File(exe).existsSync()) return exe;
    }
    return null;
  }

  /// Windsurf globalStorage 根目录
  static String? _windsurfGlobalStorageRoot() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? '';
      if (appData.isEmpty) return null;
      return '$appData\\Windsurf\\User\\globalStorage';
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      return '$home/Library/Application Support/Windsurf/User/globalStorage';
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '';
      return '$home/.config/Windsurf/User/globalStorage';
    }
    return null;
  }

  /// 检测 Windsurf 是否在跑
  static Future<bool> _isWindsurfRunning() async {
    try {
      ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq Windsurf.exe'],
            runInShell: false);
        return result.stdout.toString().toLowerCase().contains('windsurf.exe');
      } else if (Platform.isMacOS || Platform.isLinux) {
        result = await Process.run('pgrep', ['-fi', 'windsurf'], runInShell: false);
        return result.exitCode == 0;
      }
    } catch (e) {
      debugPrint('[WindsurfPatch] _isWindsurfRunning error: $e');
    }
    return false;
  }

  /// kill Windsurf 进程（所有相关进程）
  static Future<bool> _killWindsurf() async {
    try {
      ProcessResult result;
      if (Platform.isWindows) {
        // 用 taskkill 强杀 Windsurf.exe（含所有子进程）
        result = await Process.run(
            'taskkill', ['/F', '/T', '/IM', 'Windsurf.exe'],
            runInShell: false);
        return result.exitCode == 0;
      } else if (Platform.isMacOS || Platform.isLinux) {
        result = await Process.run('pkill', ['-9', '-fi', 'windsurf'],
            runInShell: false);
        return result.exitCode == 0 || result.exitCode == 1;
      }
    } catch (e) {
      debugPrint('[WindsurfPatch] _killWindsurf error: $e');
    }
    return false;
  }

  /// 清空 Codeium / windsurf 扩展的 auth 缓存
  /// 返回清理的文件 / 目录数量
  static Future<int> _clearWindsurfAuthCache(String globalStorageRoot) async {
    int count = 0;
    final root = Directory(globalStorageRoot);
    if (!await root.exists()) return 0;

    // 1. 删除扩展的 secret/cookie 目录
    // 命名通常含 codeium / windsurf
    final keywords = ['codeium', 'windsurf', 'devin'];
    try {
      await for (final entry in root.list(followLinks: false)) {
        final name = entry.path.split(Platform.pathSeparator).last.toLowerCase();
        if (keywords.any((k) => name.contains(k))) {
          try {
            if (entry is Directory) {
              await entry.delete(recursive: true);
              count++;
            } else if (entry is File) {
              await entry.delete();
              count++;
            }
          } catch (e) {
            debugPrint('[WindsurfPatch] 删除 ${entry.path} 失败: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('[WindsurfPatch] 列出 globalStorage 失败: $e');
    }

    // 2. 备份 + 删除 state.vscdb（VSCode 的 sqlite state DB）
    // 这一步会让 Windsurf 重置所有窗口/会话状态，但也会清掉登录态。
    // 默认不删，太激进；只删 backup
    final backup = File('$globalStorageRoot${Platform.pathSeparator}state.vscdb.backup');
    if (await backup.exists()) {
      try {
        await backup.delete();
        count++;
      } catch (_) {}
    }

    return count;
  }

  /// 检查桌面端能否进行 Windsurf 切换（用于 UI 判断）
  static Future<Map<String, dynamic>> diagnose() async {
    final installRoot = await _findWindsurfInstallRoot();
    final globalStorage = _windsurfGlobalStorageRoot();
    final running = await _isWindsurfRunning();

    return {
      'platform': Platform.operatingSystem,
      'is_desktop': _isDesktop(),
      'install_root': installRoot,
      'has_install': installRoot != null,
      'global_storage': globalStorage,
      'has_global_storage':
          globalStorage != null && await Directory(globalStorage).exists(),
      'is_running': running,
      'exe_path':
          installRoot != null ? _findWindsurfExe(installRoot) : null,
    };
  }
}
