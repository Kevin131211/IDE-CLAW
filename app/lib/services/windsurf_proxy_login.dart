import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 客户端直连星火代理登录
///
/// 服务端调代理常被 Cloudflare 1027 拦（数据中心 IP 黑名单）；
/// 改由用户家庭 / 移动 IP 直连代理通常能绕开。
class WindsurfProxyLogin {
  /// 代理 URL 列表（按顺序尝试）
  static const proxies = <String>[
    'https://api.willxin666.xyz',
    'https://windsurf.aiapi.indevs.in',
  ];

  static const _path = '/_devin-auth/password/login';

  /// 多种 User-Agent 候选（尝试绕开 Cloudflare 浏览器指纹检测）
  static const _userAgents = <String>[
    // 模拟真实 Windsurf IDE 内核
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Windsurf/1.10.0 Chrome/130.0.0.0 Electron/33.2.0 Safari/537.36',
    // 普通 Chrome
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36',
  ];

  /// 直连代理登录
  /// 返回 {success, [tokens...], error, attempts: [...]}
  static Future<Map<String, dynamic>> login(String email, String password) async {
    final attempts = <String>[];
    Object? lastError;

    for (final base in proxies) {
      for (final ua in _userAgents) {
        try {
          final r = await http.post(
            Uri.parse(base + _path),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': ua,
              'Origin': 'https://windsurf.com',
              'Referer': 'https://windsurf.com/',
            },
            body: jsonEncode({'email': email, 'password': password}),
          ).timeout(const Duration(seconds: 20));

          attempts.add('$base [UA=${ua.substring(0, 30)}...] HTTP ${r.statusCode}');
          if (r.statusCode != 200) {
            lastError = 'HTTP ${r.statusCode}: ${_truncate(r.body, 200)}';
            continue;
          }

          // 解析多种字段命名
          Map<String, dynamic> data;
          try {
            data = jsonDecode(r.body) as Map<String, dynamic>;
          } catch (e) {
            lastError = '响应非 JSON: ${_truncate(r.body, 200)}';
            continue;
          }
          final pickStr = (List<String> keys) {
            for (final k in keys) {
              final v = data[k];
              if (v is String && v.isNotEmpty) return v;
            }
            return '';
          };
          final idToken = pickStr(['idToken', 'id_token', 'token']);
          var refreshToken = pickStr(['refreshToken', 'refresh_token']);
          var auth1Token = pickStr(['auth1Token', 'auth1_token', 'auth1']);
          final accountId = pickStr(['accountId', 'account_id']);
          final primaryOrgId =
              pickStr(['primaryOrgId', 'primary_org_id', 'orgId', 'org_id']);

          if (idToken.isEmpty && auth1Token.isEmpty) {
            lastError = '响应未含 token: ${_truncate(r.body, 200)}';
            continue;
          }
          if (refreshToken.isEmpty) refreshToken = idToken;
          if (auth1Token.isEmpty) auth1Token = idToken;

          return {
            'success': true,
            'proxy': base,
            'id_token': idToken,
            'refresh_token': refreshToken,
            'auth1_token': auth1Token,
            'account_id': accountId,
            'primary_org_id': primaryOrgId,
            'attempts': attempts,
          };
        } catch (e) {
          attempts.add('$base [UA=${ua.substring(0, 30)}...] EXC ${_summarizeError(e)}');
          lastError = e;
          continue;
        }
      }
    }
    return {
      'success': false,
      'error': lastError?.toString() ?? '所有代理都失败',
      'attempts': attempts,
    };
  }

  static String _truncate(String s, int n) {
    if (s.length <= n) return s;
    return '${s.substring(0, n)}...';
  }

  static String _summarizeError(Object e) {
    final s = e.toString();
    if (s.length > 80) return '${s.substring(0, 80)}...';
    return s;
  }

  /// 检测网络环境（GET 代理 / 看是否被 Cloudflare 拦）
  static Future<List<Map<String, dynamic>>> diagnose() async {
    final results = <Map<String, dynamic>>[];
    for (final base in proxies) {
      try {
        final r = await http
            .get(Uri.parse(base + '/'),
                headers: {'User-Agent': _userAgents.first})
            .timeout(const Duration(seconds: 8));
        results.add({
          'proxy': base,
          'reachable': true,
          'status': r.statusCode,
          'body': _truncate(r.body, 100),
          'cloudflare_blocked':
              r.body.contains('error code: 1027') || r.statusCode == 1027,
        });
      } catch (e) {
        results.add({
          'proxy': base,
          'reachable': false,
          'error': _summarizeError(e),
          'platform': Platform.operatingSystem,
        });
      }
    }
    debugPrint('[WindsurfProxyLogin] diagnose: $results');
    return results;
  }
}
