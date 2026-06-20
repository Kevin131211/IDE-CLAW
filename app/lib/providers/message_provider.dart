import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/ws_service.dart';
import '../services/webrtc_service.dart';
import '../services/local_message_store.dart';
import '../services/notification_service.dart';

class MessageProvider extends ChangeNotifier {
  final ApiService apiService;
  final WsService wsService;
  final String sessionId;
  WebRTCService? _webrtcService;
  late final LocalMessageStore _localStore;

  List<PushMessage> _messages = [];
  WsStatus _wsStatus = WsStatus.disconnected;
  P2PStatus _p2pStatus = P2PStatus.waiting;
  bool _loading = false;
  String? _error;
  bool _pcTyping = true;

  List<PushMessage> get messages => _messages;
  WsStatus get wsStatus => _wsStatus;
  P2PStatus get p2pStatus => _p2pStatus;
  bool get loading => _loading;
  String? get error => _error;
  bool get isP2PConnected => _p2pStatus == P2PStatus.connected;
  bool get pcTyping => _pcTyping;

  final Set<String> _seenIds = {};
  Timer? _pollTimer;

  /// 回复回调（本地 IPC 用）
  void Function(String text)? onReplyCallback;

  MessageProvider({
    required this.apiService,
    required this.wsService,
    required this.sessionId,
  }) {
    _localStore = LocalMessageStore(sessionId);
    // 启动时从本地加载消息
    _loadLocal();

    // Listen to WebSocket messages
    wsService.messages.listen((msg) {
      // typing信号忽略（默认一直显示省略号）
      if (msg.msgType == 'typing') return;
      // stop_typing：AI回复完毕，隐藏省略号
      if (msg.msgType == 'stop_typing') {
        _pcTyping = false;
        notifyListeners();
        return;
      }
      // 普通消息
      if (!_seenIds.contains(msg.id)) {
        _seenIds.add(msg.id);
        _messages.add(msg);
        _persistLocal();
        // PC发来消息说明AI已完成输入，隐藏省略号
        if (msg.sender == 'pc') {
          _pcTyping = false;
          NotificationService().showMessageNotification(
            title: '新消息',
            body: msg.content.length > 100
                ? '${msg.content.substring(0, 100)}...'
                : msg.content,
          );
        }
        notifyListeners();
      }
    });

    // Listen to WebSocket status
    wsService.status.listen((status) {
      _wsStatus = status;
      // WebSocket重连成功时立即拉取漏接的消息
      if (status == WsStatus.connected) {
        _pollNewMessages();
      }
      notifyListeners();
    });

    // Periodic polling as WebSocket fallback (every 15s)
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _pollNewMessages());

    // 启动WebRTC P2P监听
    _initWebRTC();
  }

  void _initWebRTC() {
    _webrtcService = WebRTCService(
      serverUrl: apiService.serverUrl,
      sessionId: sessionId,
      token: apiService.token,
    );
    _webrtcService!.status.listen((status) {
      _p2pStatus = status;
      notifyListeners();
    });
    _webrtcService!.messages.listen((data) {
      final content = data['content'] as String? ?? '';
      if (content.isNotEmpty) {
        final id = 'p2p_${DateTime.now().millisecondsSinceEpoch}';
        if (!_seenIds.contains(id)) {
          _seenIds.add(id);
          _messages.add(PushMessage(
            id: id,
            sessionId: sessionId,
            content: content,
            msgType: 'text',
            sender: data['sender'] as String? ?? 'pc',
            createdAt: DateTime.now().toUtc(),
          ));
          _persistLocal();
          notifyListeners();
        }
      }
    });
    _webrtcService!.startListening();
  }

  Future<void> _loadLocal() async {
    final local = await _localStore.loadMessages();
    if (local.isNotEmpty && _messages.isEmpty) {
      _messages = local;
      _seenIds.clear();
      for (final m in _messages) {
        _seenIds.add(m.id);
      }
      _sortMessages();
      notifyListeners();
    }
  }

  /// 按 createdAt 排序消息列表
  void _sortMessages() {
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  void _persistLocal() {
    _localStore.saveMessages(_messages);
  }

  Future<void> _pollNewMessages() async {
    try {
      final data = await apiService.getMessagesRaw(sessionId, null);
      final list = data['messages'] as List? ?? [];

      bool changed = false;
      for (final m in list) {
        final msg = PushMessage.fromJson(m);
        if (!_seenIds.contains(msg.id)) {
          _seenIds.add(msg.id);
          _messages.add(msg);
          changed = true;
          // 后台时弹系统通知
          if (msg.sender == 'pc') {
            NotificationService().showMessageNotification(
              title: '新消息',
              body: msg.content.length > 100
                  ? '${msg.content.substring(0, 100)}...'
                  : msg.content,
            );
          }
        }
      }
      // typing状态仅由WebSocket的typing/stop_typing消息控制，不从轮询同步
      if (changed) {
        _sortMessages();
        _persistLocal();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> loadHistory() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      // 从服务器拉取新消息，合并到本地（不覆盖）
      final serverMsgs = await apiService.getMessages(sessionId, null);
      bool changed = false;
      for (final m in serverMsgs) {
        if (!_seenIds.contains(m.id)) {
          _seenIds.add(m.id);
          _messages.add(m);
          changed = true;
        }
      }
      if (changed) {
        _sortMessages();
        _persistLocal();
      }
      _error = null;
    } catch (e) {
      // 服务器不可用时不报错，本地消息已加载
      if (_messages.isEmpty) {
        _error = '加载消息失败: $e';
      }
    }
    _loading = false;
    notifyListeners();
  }

  static const _commandLabels = {
    'screenshot': '📸 截图',
    'continue_opt': '▶️ 继续优化',
    'stop_opt': '⏹️ 停止优化',
    'get_status': '📊 获取状态',
  };

  Future<void> sendCommand(String command, {String params = '{}', String? displayText}) async {
    // 用户发消息后重新显示省略号（AI开始工作）
    _pcTyping = true;
    final label = displayText ?? _commandLabels[command] ?? '📲 $command';
    final tempId = 'local_${DateTime.now().millisecondsSinceEpoch}';
    final msg = PushMessage(
      id: tempId,
      sessionId: sessionId,
      content: label,
      msgType: 'text',
      sender: 'mobile',
      createdAt: DateTime.now().toUtc(),
      sendStatus: SendStatus.sending,
    );
    _seenIds.add(tempId);
    _messages.add(msg);
    notifyListeners();

    try {
      final result = await apiService.sendCommand(sessionId, command, params);
      final cmdId = result['command_id'] as String? ?? '';
      if (cmdId.isNotEmpty) {
        final serverId = 'cmd_$cmdId';
        final alreadyExists = _messages.any((m) => m.id == serverId);
        if (alreadyExists) {
          // WS已收到服务器消息，删除本地临时消息
          _messages.removeWhere((m) => m.id == tempId);
          _seenIds.remove(tempId);
        } else {
          // 将本地消息ID替换为服务器ID，这样持久化后重启也能正确去重
          _seenIds.remove(tempId);
          msg.id = serverId;
          _seenIds.add(serverId);
        }
      }
      msg.sendStatus = SendStatus.sent;
      _persistLocal();
      notifyListeners();
    } catch (e) {
      msg.sendStatus = SendStatus.failed;
      _error = '发送指令失败: $e';
      notifyListeners();
    }
  }

  Future<void> retrySend(PushMessage msg) async {
    if (msg.sendStatus != SendStatus.failed) return;
    msg.sendStatus = SendStatus.sending;
    notifyListeners();
    try {
      final result = await apiService.sendCommand(sessionId, 'reply',
          '{"text": ${_jsonEscape(msg.content)}}');
      final cmdId = result['command_id'] as String? ?? '';
      if (cmdId.isNotEmpty) {
        final serverId = 'cmd_$cmdId';
        if (_messages.any((m) => m.id == serverId)) {
          _messages.remove(msg);
          _seenIds.remove(msg.id);
        } else {
          _seenIds.remove(msg.id);
          msg.id = serverId;
          _seenIds.add(serverId);
        }
      }
      msg.sendStatus = SendStatus.sent;
      _persistLocal();
      notifyListeners();
    } catch (e) {
      msg.sendStatus = SendStatus.failed;
      notifyListeners();
    }
  }

  Future<void> sendFile(String fileName, List<int> fileBytes, {String caption = ''}) async {
    // 用户发文件后重新显示省略号
    _pcTyping = true;
    final tempId = 'local_file_${DateTime.now().millisecondsSinceEpoch}';
    final displayText = caption.isNotEmpty
        ? '$caption\n📎 $fileName'
        : '📎 发送中: $fileName';
    final msg = PushMessage(
      id: tempId,
      sessionId: sessionId,
      content: displayText,
      msgType: 'file',
      sender: 'mobile',
      createdAt: DateTime.now().toUtc(),
      sendStatus: SendStatus.sending,
    );
    _seenIds.add(tempId);
    _messages.add(msg);
    notifyListeners();

    try {
      final result = await apiService.uploadFile(
        sessionId, '', fileName, fileBytes,
        caption: caption, sender: 'mobile',
      );
      if (result['success'] == true) {
        final serverId = result['file_id'] as String? ?? '';
        if (serverId.isNotEmpty) {
          final alreadyExists = _messages.any((m) => m.id == serverId);
          if (alreadyExists) {
            _messages.removeWhere((m) => m.id == tempId);
            _seenIds.remove(tempId);
          } else {
            _seenIds.remove(tempId);
            msg.id = serverId;
            _seenIds.add(serverId);
          }
        }
        msg.sendStatus = SendStatus.sent;
        _persistLocal();
        notifyListeners();
      } else {
        msg.sendStatus = SendStatus.failed;
        _error = '文件上传失败: ${result['error'] ?? 'unknown'}';
        notifyListeners();
      }
    } catch (e) {
      msg.sendStatus = SendStatus.failed;
      _error = '文件上传失败: $e';
      notifyListeners();
    }
  }

  Future<void> sendReply(String text) async {
    // 通知本地 IPC（如果有等待中的请求）
    onReplyCallback?.call(text);
    final params = '{"text": ${_jsonEscape(text)}}';
    await sendCommand('reply', params: params, displayText: text);
  }

  /// 添加本地 IPC 推送的消息（不走服务器）
  void addLocalMessage(PushMessage msg) {
    if (!_seenIds.contains(msg.id)) {
      _seenIds.add(msg.id);
      _messages.add(msg);
      _pcTyping = false;
      _persistLocal();
      notifyListeners();
    }
  }

  String _jsonEscape(String s) {
    return '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n')}"';
  }

  /// 当前连接模式标签
  String get connectionMode {
    if (isP2PConnected) return 'P2P直连';
    return wsService.modeLabel;
  }

  void connectWs() {
    wsService.connect();
  }

  void reconnectWs() {
    wsService.reconnectNow();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _webrtcService?.dispose();
    wsService.dispose();
    super.dispose();
  }
}
