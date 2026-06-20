import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 本地 IPC 服务：在 localhost 上运行 HTTP 服务器，
/// 让同一台电脑上的 dialog.py 直接推送消息并接收回复，无需绕远程服务器。
///
/// 多工作区会话：dialog.py 携带 session_id / workspace 字段时，
/// 等待中的长轮询按会话 ID 分开挂起，多个工作区并行等待互不串扰。
class LocalIpcService {
  static const int defaultPort = 13800;

  /// 旧版 dialog.py（不带 session_id）使用的兜底会话键
  static const String defaultSessionKey = '_default';

  HttpServer? _server;
  final int port;
  bool _running = false;

  /// 等待回复的 HTTP 长轮询请求，按会话 ID 分开存放
  final Map<String, Completer<Map<String, dynamic>>> _pendingReplies = {};

  /// 新消息流（UI 监听此流来显示本地推送的消息，
  /// data 中可能包含 session_id / workspace / workspace_name 字段）
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  /// 是否有任意会话的消息正在等待回复
  bool get hasPendingReply =>
      _pendingReplies.values.any((c) => !c.isCompleted);

  /// 指定会话是否有消息正在等待回复
  bool hasPendingFor(String sessionId) {
    final c = _pendingReplies[sessionId];
    return c != null && !c.isCompleted;
  }

  LocalIpcService({this.port = defaultPort});

  /// 启动本地 HTTP 服务器
  Future<bool> start() async {
    if (_running) return true;
    try {
      _server = await HttpServer.bind('127.0.0.1', port, shared: true);
      _running = true;
      _server!.listen(_handleRequest);
      return true;
    } catch (e) {
      // 端口占用等错误，静默失败
      return false;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // CORS headers for local requests
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST');
    request.response.headers
        .add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = 200;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    if (path == '/ping' && request.method == 'GET') {
      await _handlePing(request);
    } else if (path == '/message' && request.method == 'POST') {
      await _handleMessage(request);
    } else {
      request.response.statusCode = 404;
      request.response.write('Not Found');
      await request.response.close();
    }
  }

  /// GET /ping — 健康检查，dialog.py 用来检测桌面端是否在运行
  Future<void> _handlePing(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'status': 'ok',
      'has_pending': hasPendingReply,
    }));
    await request.response.close();
  }

  /// POST /message — 接收消息并等待用户回复（长轮询，按会话分开挂起）
  Future<void> _handleMessage(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final message = data['message'] as String? ?? '';

      if (message.isEmpty) {
        request.response.statusCode = 400;
        request.response.write('{"error": "empty message"}');
        await request.response.close();
        return;
      }

      final rawSession = (data['session_id'] as String? ?? '').trim();
      final sessionKey =
          rawSession.isNotEmpty ? rawSession : defaultSessionKey;

      // 同一会话有旧的等待时先结束旧请求（返回 timeout，旧 dialog.py 会重新挂起或退出）
      final old = _pendingReplies[sessionKey];
      if (old != null && !old.isCompleted) {
        old.complete({'text': '', 'action': 'timeout'});
      }

      // 通知 UI 显示新消息（UI 据此自动创建/切换工作区会话）
      _messageController.add(data);

      // 创建该会话专属的 Completer 等待用户回复
      final completer = Completer<Map<String, dynamic>>();
      _pendingReplies[sessionKey] = completer;

      try {
        // 最长等待 30 分钟
        final reply = await completer.future.timeout(
          const Duration(minutes: 30),
          onTimeout: () => {'text': '', 'action': 'timeout'},
        );

        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(reply));
      } catch (e) {
        request.response.statusCode = 500;
        request.response.write('{"error": "internal error"}');
      }
    } catch (e) {
      request.response.statusCode = 400;
      request.response.write('{"error": "invalid request"}');
    }
    await request.response.close();
  }

  /// 提交用户回复（由 UI 调用）。
  /// [sessionId] 指定回复哪个会话的等待；找不到时，若全局只有一个
  /// 等待中的请求则回它（兼容旧版 dialog.py 无 session_id 的情况）。
  void submitReply(String text, {String action = 'reply', String? sessionId}) {
    Completer<Map<String, dynamic>>? target;

    if (sessionId != null && sessionId.isNotEmpty) {
      final c = _pendingReplies[sessionId];
      if (c != null && !c.isCompleted) target = c;
    }

    // 兜底：指定会话没有等待中的请求时，如果全局只有一个等待中的请求就回它
    if (target == null) {
      final waiting =
          _pendingReplies.values.where((c) => !c.isCompleted).toList();
      if (waiting.length == 1) target = waiting.first;
    }

    if (target != null && !target.isCompleted) {
      target.complete({
        'text': text,
        'action': action,
        'source': 'desktop',
      });
    }
  }

  /// 停止服务器
  Future<void> stop() async {
    _running = false;
    // 取消所有等待中的回复
    for (final c in _pendingReplies.values) {
      if (!c.isCompleted) {
        c.complete({'text': '', 'action': 'shutdown'});
      }
    }
    _pendingReplies.clear();
    await _server?.close();
    _server = null;
  }

  void dispose() {
    stop();
    _messageController.close();
  }
}
