import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config/app_config.dart';
import '../models/message.dart';
import '../services/api_service.dart';

/// 连接模式
enum WsMode { direct, cloud }

class WsService {
  final String serverUrl;
  final String sessionId;
  final String token;
  final ApiService? apiService;

  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  Timer? _pongTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;
  bool _isConnected = false;
  bool _waitingPong = false;
  bool _intentionalDisconnect = false;
  WsMode _currentMode = WsMode.cloud;

  /// P2P直连端点列表（从云服务器发现）
  List<String> _directEndpoints = [];

  final _messageController = StreamController<PushMessage>.broadcast();
  final _statusController = StreamController<WsStatus>.broadcast();
  final _windsurfSwitchController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<PushMessage> get messages => _messageController.stream;
  Stream<WsStatus> get status => _statusController.stream;

  /// Windsurf 账号切换事件流（来自服务端 type='windsurf_switch'）
  /// 客户端订阅后可弹通知 / 触发桌面端 patch
  Stream<Map<String, dynamic>> get windsurfSwitch =>
      _windsurfSwitchController.stream;

  WsService({
    required this.serverUrl,
    required this.sessionId,
    required this.token,
    this.apiService,
  });

  String get _cloudWsUrl {
    final base = serverUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    return '$base/ws?token=$token&session_id=$sessionId&role=mobile';
  }

  String _directWsUrl(String endpoint) {
    return '$endpoint?token=$token&session_id=$sessionId&role=mobile';
  }

  bool get isConnected => _isConnected;
  WsMode get currentMode => _currentMode;
  String get modeLabel => _currentMode == WsMode.direct ? '直连' : '云中继';

  void connect() {
    if (_disposed) return;
    _disconnect();
    _statusController.add(WsStatus.connecting);

    // 仅首次或每10次重连时重新发现端点
    if (_directEndpoints.isEmpty || _reconnectAttempts % 10 == 0) {
      _discoverThenConnect();
    } else {
      _connectWithFallback();
    }
  }

  Future<void> _discoverThenConnect() async {
    if (apiService != null) {
      try {
        final epData = await apiService!.getEndpoint(sessionId);
        if (epData['available'] == true) {
          final endpoints = (epData['endpoints'] as List?)?.cast<String>() ?? [];
          if (endpoints.isNotEmpty) {
            _directEndpoints = endpoints;
          }
        }
      } catch (_) {}
    }
    _connectWithFallback();
  }

  void _connectWithFallback() {
    // 优先直连，失败回退云
    if (_directEndpoints.isNotEmpty) {
      _connectTo(_directWsUrl(_directEndpoints.first), WsMode.direct);
    } else {
      _connectTo(_cloudWsUrl, WsMode.cloud);
    }
  }

  void _connectTo(String url, WsMode mode) {
    if (_disposed) return;
    _disconnect();
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel!.stream.listen(
        _onMessage,
        onError: (e) {
          // 直连失败时自动回退云中继
          if (mode == WsMode.direct && !_disposed) {
            _connectTo(_cloudWsUrl, WsMode.cloud);
          } else {
            _onError(e);
          }
        },
        onDone: () {
          _onDone();
        },
      );
      _currentMode = mode;
      _reconnectAttempts = 0;
      _isConnected = true;
      _intentionalDisconnect = false;
      _statusController.add(WsStatus.connected);
      _startHeartbeat();
    } catch (e) {
      // 直连异常时回退云
      if (mode == WsMode.direct && !_disposed) {
        _connectTo(_cloudWsUrl, WsMode.cloud);
      } else {
        _isConnected = false;
        _statusController.add(WsStatus.error);
        _scheduleReconnect();
      }
    }
  }

  /// Call when app resumes from background
  void reconnectNow() {
    if (_disposed) return;
    _reconnectAttempts = 0;
    connect();
  }

  void _disconnect() {
    _stopHeartbeat();
    _isConnected = false;
    _intentionalDisconnect = true;
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
  }

  void _onMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String);
      final type = json['type'] as String?;
      if (type == 'message') {
        final msgData = json['data'] as Map<String, dynamic>?;
        if (msgData != null) {
          final msg = PushMessage.fromJson(msgData);
          _messageController.add(msg);
          // Auto ACK
          _sendAck(msg.id);
        }
      } else if (type == 'connected') {
        // 直连欢迎消息
      } else if (type == 'pong') {
        _waitingPong = false;
        _pongTimer?.cancel();
      }
    } catch (e) {
      // ignore parse errors
    }
  }

  void _onError(dynamic error) {
    _isConnected = false;
    _statusController.add(WsStatus.error);
    _scheduleReconnect();
  }

  void _onDone() {
    if (_intentionalDisconnect) {
      _intentionalDisconnect = false;
      return;
    }
    _isConnected = false;
    _statusController.add(WsStatus.disconnected);
    _stopHeartbeat();
    _scheduleReconnect();
  }

  void _sendAck(String messageId) {
    _send({'type': 'ack', 'message_id': messageId});
  }

  void _send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(
      AppConfig.heartbeatInterval,
      (_) {
        _send({'type': 'ping'});
        _waitingPong = true;
        _pongTimer?.cancel();
        _pongTimer = Timer(AppConfig.pongTimeout, () {
          if (_waitingPong && !_disposed) {
            // Pong timeout = silent disconnect
            _isConnected = false;
            _statusController.add(WsStatus.disconnected);
            _disconnect();
            _scheduleReconnect();
          }
        });
      },
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pongTimer?.cancel();
    _pongTimer = null;
    _waitingPong = false;
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectAttempts++;
    // Cap delay at 15s, never give up
    final delaySec = (_reconnectAttempts * AppConfig.reconnectDelay.inSeconds).clamp(1, 15);
    final delay = Duration(seconds: delaySec);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, connect);
  }

  void dispose() {
    _disposed = true;
    _stopHeartbeat();
    _reconnectTimer?.cancel();
    _pongTimer?.cancel();
    _channel?.sink.close();
    _messageController.close();
    _statusController.close();
    _windsurfSwitchController.close();
  }
}

enum WsStatus { connecting, connected, disconnected, error, failed }
