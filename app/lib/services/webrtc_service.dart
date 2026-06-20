import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

/// WebRTC P2P 直连服务
/// 参考ZeroTier原理：STUN发现公网地址 → ICE打洞穿透NAT → DataChannel直连
class WebRTCService {
  final String serverUrl;
  final String sessionId;
  final String token;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  bool _disposed = false;
  Timer? _pollTimer;

  // TURN/STUN 凭证缓存（避免每次重连都打一次 /api/webrtc/turn-credentials）
  List<Map<String, dynamic>>? _cachedIceServers;
  int _cachedIceServersExpiryMs = 0;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<P2PStatus>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<P2PStatus> get status => _statusController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  WebRTCService({
    required this.serverUrl,
    required this.sessionId,
    required this.token,
  });

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  /// 开始监听PC端的WebRTC offer
  void startListening() {
    if (_disposed) return;
    _statusController.add(P2PStatus.waiting);
    // 每2秒轮询信令
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollSignals());
  }

  Future<void> _pollSignals() async {
    if (_disposed || _isConnected) return;
    try {
      final uri = Uri.parse('$serverUrl/api/webrtc/signals').replace(
        queryParameters: {'session_id': sessionId, 'role': 'mobile'},
      );
      final r = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 5));
      final data = jsonDecode(r.body);
      final signals = data['signals'] as List? ?? [];

      for (final sig in signals) {
        final type = sig['type'] as String? ?? '';
        var payload = sig['payload'];
        if (payload is String) {
          payload = jsonDecode(payload);
        }

        if (type == 'offer') {
          await _handleOffer(payload as Map<String, dynamic>);
        } else if (type == 'candidate') {
          await _addIceCandidate(payload as Map<String, dynamic>);
        }
      }
    } catch (_) {}
  }

  Future<void> _handleOffer(Map<String, dynamic> offerData) async {
    if (_disposed) return;
    _statusController.add(P2PStatus.connecting);
    _pollTimer?.cancel(); // 收到offer后停止轮询

    // ICE 配置：优先从服务端拉取 TURN 凭证（含 STUN+TURN+TURNS 完整列表），失败回退到公共 STUN
    final iceServers = await _loadIceServers();
    final config = <String, dynamic>{
      'iceServers': iceServers,
      // 使用 'all' 让 ICE 在 STUN 直连失败时自动 fallback 到 TURN relay
      'iceTransportPolicy': 'all',
      'sdpSemantics': 'unified-plan',
    };

    _pc = await createPeerConnection(config);

    // ICE状态监听
    _pc!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _isConnected = true;
        _statusController.add(P2PStatus.connected);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _isConnected = false;
        _statusController.add(P2PStatus.failed);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _isConnected = false;
        _statusController.add(P2PStatus.disconnected);
        // 重新开始监听
        startListening();
      }
    };

    // ICE candidate回调
    _pc!.onIceCandidate = (candidate) {
      _postSignal('candidate', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    // DataChannel回调
    _pc!.onDataChannel = (channel) {
      _dc = channel;
      _setupDataChannel(channel);
    };

    // 设置远端offer
    final offer = RTCSessionDescription(
      offerData['sdp'] as String,
      offerData['type'] as String,
    );
    await _pc!.setRemoteDescription(offer);

    // 创建answer
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    // 等待ICE gathering完成
    await Future.delayed(const Duration(seconds: 2));

    // 发送answer
    final localDesc = await _pc!.getLocalDescription();
    if (localDesc != null) {
      await _postSignal('answer', {
        'type': 'answer',
        'sdp': localDesc.sdp,
      });
    }
  }

  void _setupDataChannel(RTCDataChannel dc) {
    dc.onMessage = (msg) {
      try {
        final data = jsonDecode(msg.text);
        _messageController.add(data);
      } catch (_) {
        _messageController.add({'text': msg.text});
      }
    };

    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _isConnected = true;
        _statusController.add(P2PStatus.connected);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _isConnected = false;
        _statusController.add(P2PStatus.disconnected);
        startListening();
      }
    };
  }

  Future<void> _addIceCandidate(Map<String, dynamic> data) async {
    if (_pc == null) return;
    try {
      final candidate = RTCIceCandidate(
        data['candidate'] as String? ?? '',
        data['sdpMid'] as String? ?? '',
        data['sdpMLineIndex'] as int? ?? 0,
      );
      await _pc!.addCandidate(candidate);
    } catch (_) {}
  }

  /// 发送消息（通过P2P DataChannel）
  Future<bool> send(Map<String, dynamic> data) async {
    if (!_isConnected || _dc == null) return false;
    try {
      _dc!.send(RTCDataChannelMessage(jsonEncode(data)));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 发送文本消息
  Future<bool> sendText(String text) async {
    return send({
      'type': 'message',
      'content': text,
      'sender': 'mobile',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 拉取 ICE 服务器列表（STUN+TURN+TURNS）
  ///
  /// 服务端 /api/webrtc/turn-credentials 返回 HMAC 短期凭证，TTL 默认 1 小时。
  /// 这里缓存到过期前 5 分钟，缓存命中直接返回。
  /// 如果服务端没启用 TURN（enabled=false）或请求失败，回退到公共 STUN。
  Future<List<Map<String, dynamic>>> _loadIceServers() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_cachedIceServers != null && now < _cachedIceServersExpiryMs) {
      return _cachedIceServers!;
    }

    // fallback STUN：把国内可达的服务器排在前面（中国大陆 google STUN 经常不通）
    final fallback = <Map<String, dynamic>>[
      {'urls': 'stun:stun.miwifi.com:3478'},          // 小米
      {'urls': 'stun:stun.qq.com:3478'},              // 腾讯
      {'urls': 'stun:stun.cloudflare.com:3478'},      // Cloudflare（部分线路通）
      {'urls': 'stun:stun.l.google.com:19302'},       // 兜底
    ];

    try {
      final uri = Uri.parse('$serverUrl/api/webrtc/turn-credentials');
      final r = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) {
        debugPrint('[WebRTC] turn-credentials status=${r.statusCode}, fallback to public STUN');
        return fallback;
      }
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      if (body['enabled'] != true) {
        return fallback;
      }
      final urls = (body['urls'] as List? ?? const []).cast<String>();
      if (urls.isEmpty) return fallback;

      final ttl = (body['ttl_seconds'] as num?)?.toInt() ?? 3600;
      // 缓存有效期 = ttl - 5 分钟（避免凭证刚过期就用）
      _cachedIceServersExpiryMs = now + (ttl - 300) * 1000;

      final username = body['username'] as String?;
      final credential = body['credential'] as String?;

      // 把 stun: 和 turn:/turns: 拆开 — STUN 不需要凭证
      final stunUrls = urls.where((u) => u.startsWith('stun:')).toList();
      final turnUrls = urls.where((u) => u.startsWith('turn:') || u.startsWith('turns:')).toList();

      final servers = <Map<String, dynamic>>[];
      if (stunUrls.isNotEmpty) {
        servers.add({'urls': stunUrls});
      }
      if (turnUrls.isNotEmpty && username != null && credential != null) {
        servers.add({
          'urls': turnUrls,
          'username': username,
          'credential': credential,
        });
      }

      _cachedIceServers = servers.isEmpty ? fallback : servers;
      debugPrint('[WebRTC] ICE servers loaded: ${urls.length} URLs (TURN ${turnUrls.isNotEmpty ? "enabled" : "disabled"})');
      return _cachedIceServers!;
    } catch (e) {
      debugPrint('[WebRTC] turn-credentials fetch error: $e, fallback to public STUN');
      return fallback;
    }
  }

  Future<void> _postSignal(String type, Map<String, dynamic> payload) async {
    try {
      final url = Uri.parse('$serverUrl/api/webrtc/signal');
      await http.post(url,
        headers: _headers,
        body: jsonEncode({
          'type': type,
          'from': 'mobile',
          'session_id': sessionId,
          'payload': jsonEncode(payload),
        }),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _dc?.close();
    _pc?.close();
    _messageController.close();
    _statusController.close();
  }
}

enum P2PStatus { waiting, connecting, connected, disconnected, failed }
