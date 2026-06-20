import 'package:crypto/crypto.dart';
import 'dart:convert';

/// 工作区 → 会话 的派生算法。
/// 必须与 cascade/dialog.py 中 _normalize_workspace / workspace_session_id 保持一致：
///   normalize: 统一正斜杠、去尾斜杠、全小写
///   id: 'ws-' + sha1(norm)[:8]
class WorkspaceSession {
  /// 规范化工作区路径（与 Python 侧 _normalize_workspace 一致）
  static String normalize(String path) {
    var p = path.trim().replaceAll('\\', '/');
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p.toLowerCase();
  }

  /// 工作区路径 → 稳定会话 ID（与 Python 侧 workspace_session_id 一致）
  static String idForPath(String path) {
    final norm = normalize(path);
    final digest = sha1.convert(utf8.encode(norm)).toString();
    return 'ws-${digest.substring(0, 8)}';
  }

  /// 工作区文件夹显示名（保留原始大小写）
  static String folderName(String path) {
    var p = path.trim().replaceAll('\\', '/');
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    final idx = p.lastIndexOf('/');
    final name = idx >= 0 ? p.substring(idx + 1) : p;
    return name.isEmpty ? p : name;
  }
}
