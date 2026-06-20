import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/message.dart';

class ApiService {
  final String serverUrl;
  final String token;

  ApiService({required this.serverUrl, required this.token});

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json; charset=utf-8',
      };

  Future<Map<String, dynamic>> healthCheck() async {
    final r = await http
        .get(Uri.parse('$serverUrl/api/health'))
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body);
  }

  Future<Map<String, dynamic>> getMessagesRaw(
      String sessionId, String? since) async {
    final params = {'session_id': sessionId};
    if (since != null) params['since'] = since;
    final uri = Uri.parse('$serverUrl/api/messages')
        .replace(queryParameters: params);
    final r = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    return jsonDecode(r.body);
  }

  Future<List<PushMessage>> getMessages(
      String sessionId, String? since) async {
    final data = await getMessagesRaw(sessionId, since);
    final list = data['messages'] as List? ?? [];
    return list.map((m) => PushMessage.fromJson(m)).toList();
  }

  Future<void> ackMessage(String messageId) async {
    await http
        .post(Uri.parse('$serverUrl/api/messages/$messageId/ack'),
            headers: _headers)
        .timeout(const Duration(seconds: 10));
  }

  Future<Map<String, dynamic>> sendCommand(
      String sessionId, String command, String params) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/commands'),
          headers: _headers,
          body: jsonEncode({
            'session_id': sessionId,
            'command': command,
            'params': params,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body);
  }

  Future<Map<String, dynamic>> uploadFile(
      String sessionId, String filePath, String fileName,
      List<int> fileBytes, {String caption = '', String sender = 'mobile'}) async {
    final uri = Uri.parse('$serverUrl/api/files/upload');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['session_id'] = sessionId
      ..fields['sender'] = sender
      ..fields['caption'] = caption.isEmpty ? fileName : caption
      ..files.add(http.MultipartFile.fromBytes('file', fileBytes, filename: fileName));
    final response = await request.send().timeout(const Duration(seconds: 60));
    final body = await response.stream.bytesToString();
    return jsonDecode(body);
  }

  String getFileDownloadUrl(String fileId, String sessionId) {
    return '$serverUrl/api/files/$fileId?session_id=$sessionId&token=$token';
  }

  Future<List<int>> downloadFile(String fileId, String sessionId) async {
    final r = await http.get(
      Uri.parse('$serverUrl/api/files/$fileId')
          .replace(queryParameters: {'session_id': sessionId}),
      headers: _headers,
    ).timeout(const Duration(seconds: 60));
    return r.bodyBytes;
  }

  Future<List<Map<String, dynamic>>> getSessions() async {
    final r = await http
        .get(Uri.parse('$serverUrl/api/sessions'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final data = jsonDecode(r.body);
    final list = data['sessions'] as List? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  /// 获取PC端直连端点（P2P发现）
  Future<Map<String, dynamic>> getEndpoint(String sessionId) async {
    final uri = Uri.parse('$serverUrl/api/sessions/endpoint')
        .replace(queryParameters: {'session_id': sessionId});
    final r = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 5));
    return jsonDecode(r.body);
  }

  Future<void> markSessionRead(String sessionId) async {
    await http
        .post(
          Uri.parse('$serverUrl/api/sessions/mark_read'),
          headers: _headers,
          body: jsonEncode({'session_id': sessionId}),
        )
        .timeout(const Duration(seconds: 5));
  }

  /// 重命名会话（修改 display_name）
  Future<void> renameSession(String sessionId, String displayName) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/sessions/rename'),
          headers: _headers,
          body: jsonEncode({
            'session_id': sessionId,
            'display_name': displayName,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception('重命名失败: ${r.body}');
    }
  }

  /// 注册/更新会话元数据（会话不存在时服务端自动创建）
  /// 用于工作区会话：display_name=文件夹名, project_name=完整路径
  Future<void> updateSessionMeta(
    String sessionId, {
    String machineName = '',
    String projectName = '',
    String ideType = '',
    String displayName = '',
    String description = '',
  }) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/sessions/meta'),
          headers: _headers,
          body: jsonEncode({
            'session_id': sessionId,
            'machine_name': machineName,
            'project_name': projectName,
            'ide_type': ideType,
            'display_name': displayName,
            'description': description,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception('更新会话元数据失败: ${r.body}');
    }
  }

  /// 删除会话及其所有消息（不可恢复）
  Future<void> deleteSession(String sessionId) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/sessions/delete'),
          headers: _headers,
          body: jsonEncode({'session_id': sessionId}),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception('删除失败: ${r.body}');
    }
  }

  /// 拉取工作区文件清单（按 query 模糊匹配 path）
  /// 返回 [{path: 'lib/main.dart', size: 1234}, ...]
  Future<List<Map<String, dynamic>>> getWorkspaceFiles(
      String sessionId, String query, {int limit = 100}) async {
    final params = <String, String>{
      'session_id': sessionId,
      'limit': '$limit',
    };
    if (query.isNotEmpty) params['q'] = query;
    final uri = Uri.parse('$serverUrl/api/sessions/files')
        .replace(queryParameters: params);
    final r = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception('查询文件失败: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final list = data['files'] as List? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  // ==================== Windsurf 账号池（星火换号集成） ====================

  /// 列出账号池
  /// 返回 {accounts: [...], count, active_email, login_proxies, default_thresh}
  Future<Map<String, dynamic>> listWindsurfPool() async {
    final r = await http
        .get(Uri.parse('$serverUrl/api/windsurf/accounts/pool'),
            headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception('查询账号池失败: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 添加账号（自动登录拿 token，可能耗时较久）
  /// 返回 {success, email, [login_error, note]}
  Future<Map<String, dynamic>> addWindsurfAccount(
      String email, String password,
      {bool skipLogin = false}) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/windsurf/accounts/add'),
          headers: _headers,
          body: jsonEncode({
            'email': email,
            'password': password,
            'skip_login': skipLogin,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('添加失败: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 删除账号
  Future<void> deleteWindsurfAccount(String email) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/windsurf/accounts/delete'),
          headers: _headers,
          body: jsonEncode({'email': email}),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception('删除失败: ${r.body}');
    }
  }

  /// 刷新单个账号额度
  Future<Map<String, dynamic>> refreshWindsurfQuota(String email) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/windsurf/accounts/refresh-quota'),
          headers: _headers,
          body: jsonEncode({'email': email}),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('刷新失败: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 刷新所有账号额度
  Future<Map<String, dynamic>> refreshAllWindsurfQuotas() async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/windsurf/accounts/refresh-all-quotas'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw Exception('全部刷新失败: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 切换账号（email 留空 = 自动找下一个）
  Future<Map<String, dynamic>> switchWindsurfAccount(
      {String? email, String reason = 'manual', String? targetSessionId}) async {
    final body = <String, dynamic>{
      'reason': reason,
    };
    if (email != null && email.isNotEmpty) body['email'] = email;
    if (targetSessionId != null && targetSessionId.isNotEmpty) {
      body['target_session_id'] = targetSessionId;
    }
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/windsurf/accounts/switch'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('切换失败: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// **(已废弃)** 让服务端调 register.windsurf.com
  ///
  /// 国内 VPS 直连 register.windsurf.com 超时（Cloudflare CDN），
  /// 改用 [saveWindsurfRegisterResult] —— 客户端本地调 RegisterUser 后再上报。
  @Deprecated('VPS 国内直连超时, 改用 saveWindsurfRegisterResult')
  Future<Map<String, dynamic>> registerWindsurfWithToken({
    required String email,
    required String firebaseIdToken,
    String password = '',
  }) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/windsurf/accounts/register-with-token'),
          headers: _headers,
          body: jsonEncode({
            'email': email,
            'firebase_id_token': firebaseIdToken,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 45));
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) {
      throw Exception(body['error'] ?? '注册失败 (${r.statusCode})');
    }
    return body;
  }

  /// **推荐的添加账号方式**：客户端在本地调 register.windsurf.com 拿到 apiKey 后，
  /// 上传给服务端入库（绕开国内 VPS 不能访问 windsurf.com 的问题）
  Future<Map<String, dynamic>> saveWindsurfRegisterResult({
    required String email,
    required String apiKey,
    String name = '',
    String apiServerUrl = '',
    String password = '',
  }) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/windsurf/accounts/save-register-result'),
          headers: _headers,
          body: jsonEncode({
            'email': email,
            'api_key': apiKey,
            'name': name,
            'api_server_url': apiServerUrl,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 30));
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) {
      throw Exception(body['error'] ?? '保存失败 (${r.statusCode})');
    }
    return body;
  }

  /// 客户端直连代理登录后，把 token 上传服务端保存
  Future<Map<String, dynamic>> saveWindsurfTokens({
    required String email,
    String password = '',
    required String idToken,
    String refreshToken = '',
    String auth1Token = '',
    String accountId = '',
    String primaryOrgId = '',
  }) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/windsurf/accounts/save-tokens'),
          headers: _headers,
          body: jsonEncode({
            'email': email,
            'password': password,
            'id_token': idToken,
            'refresh_token': refreshToken,
            'auth1_token': auth1Token,
            'account_id': accountId,
            'primary_org_id': primaryOrgId,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('保存 token 失败: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 拉某账号的明文凭据（password + token），桌面端 patch 时用
  /// 警告：返回明文密码，仅在 HTTPS + 已认证客户端使用
  Future<Map<String, dynamic>> getWindsurfCredentials(String email) async {
    final r = await http
        .get(
          Uri.parse('$serverUrl/api/windsurf/accounts/credentials?email=${Uri.encodeQueryComponent(email)}'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception('拉取凭据失败: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 上报"额度耗尽"事件，触发自动切换
  Future<Map<String, dynamic>> reportQuotaExhausted(
      {required String email, required String errorMessage,
      String? targetSessionId}) async {
    final body = <String, dynamic>{
      'email': email,
      'error_message': errorMessage,
    };
    if (targetSessionId != null) body['target_session_id'] = targetSessionId;
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/windsurf/accounts/quota-exhausted'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('上报失败: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getAuthToken(
      String sessionId, String secret) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/auth/token'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'session_id': sessionId,
            'secret': secret,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body);
  }
}
