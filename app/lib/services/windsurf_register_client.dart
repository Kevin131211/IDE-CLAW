import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// **客户端直连 windsurf 官方 RegisterUser**
///
/// 为什么不在服务端调？
/// - 我们的 push-server 跑在国内 VPS（push.shoot-game.cn = 阿里云）
/// - register.windsurf.com 是 Cloudflare CDN，国内 VPS 通常超时
/// - 客户端（用户的本地 PC / 手机）通常能正常访问 windsurf.com
///   （能在浏览器登录拿到 token 就证明网络可达）
///
/// 协议（来自 windsurf cascade extension `dist/extension.js` 反编译）：
///   POST https://register.windsurf.com/exa.seat_management_pb.SeatManagementService/RegisterUser
///   Content-Type: application/proto
///   Connect-Protocol-Version: 1
///   body = protobuf binary of RegisterUserRequest{ firebase_id_token = 1 (string) }
///
/// 响应：RegisterUserResponse{ api_key = 1 (string), name = 2 (string), api_server_url = 3 (string) }
class WindsurfRegisterClient {
  static const _endpoint =
      'https://register.windsurf.com/exa.seat_management_pb.SeatManagementService/RegisterUser';

  /// 用 firebase_id_token 调官方 RegisterUser，返回 apiKey 等信息
  ///
  /// 抛 [WindsurfRegisterException] 表示业务错误（含网络错误重新包装）
  static Future<WindsurfRegisterResult> register(
      String firebaseIdToken) async {
    if (firebaseIdToken.trim().isEmpty) {
      throw WindsurfRegisterException('firebase_id_token 不能为空');
    }
    final body = _encodeProtoStringField(1, firebaseIdToken.trim());
    http.Response r;
    try {
      r = await http.post(
        Uri.parse(_endpoint),
        headers: {
          'Content-Type': 'application/proto',
          'Connect-Protocol-Version': '1',
          'Accept': 'application/proto',
          'User-Agent': 'ide-claw/1.0 (windsurf-pool client)',
        },
        body: body,
      ).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw WindsurfRegisterException(
          '网络错误（无法连接 register.windsurf.com）: $e\n'
          '提示：检查你当前网络能否访问 windsurf.com，国内可能需要走梯子');
    }

    if (r.statusCode != 200) {
      // Connect-RPC 错误响应是 JSON: {"code":"...", "message":"..."}
      try {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final code = j['code'] as String? ?? '';
        final msg = j['message'] as String? ?? r.body;
        throw WindsurfRegisterException(
            'RegisterUser 失败 [${r.statusCode} $code]: $msg');
      } on WindsurfRegisterException {
        rethrow;
      } catch (_) {
        throw WindsurfRegisterException(
            'RegisterUser 失败 [${r.statusCode}]: ${r.body.length > 200 ? "${r.body.substring(0, 200)}..." : r.body}');
      }
    }

    // 成功响应是 protobuf binary
    final result = _decodeRegisterUserResponse(r.bodyBytes);
    if (result.apiKey.isEmpty) {
      throw WindsurfRegisterException('响应中 api_key 为空（windsurf 服务端异常）');
    }
    return result;
  }

  /// protobuf wire 编码：单个 string field
  ///
  /// tag = (field_number << 3) | 2 (wire_type=LEN)
  /// 然后 varint length + bytes
  static Uint8List _encodeProtoStringField(int fieldNum, String value) {
    final bytes = utf8.encode(value);
    final builder = BytesBuilder();
    _writeVarint(builder, (fieldNum << 3) | 2);
    _writeVarint(builder, bytes.length);
    builder.add(bytes);
    return builder.toBytes();
  }

  static void _writeVarint(BytesBuilder b, int v) {
    while (v >= 0x80) {
      b.addByte((v & 0x7f) | 0x80);
      v >>>= 7;
    }
    b.addByte(v & 0x7f);
  }

  static (int value, int consumed) _readVarint(Uint8List buf, int offset) {
    var v = 0;
    var shift = 0;
    var i = offset;
    while (i < buf.length) {
      final b = buf[i++];
      v |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) {
        return (v, i - offset);
      }
      shift += 7;
      if (shift >= 64) throw const FormatException('varint 超过 64 位');
    }
    throw const FormatException('varint 截断');
  }

  /// protobuf wire 解码 RegisterUserResponse
  /// field 1 string api_key, field 2 string name, field 3 string api_server_url
  static WindsurfRegisterResult _decodeRegisterUserResponse(Uint8List buf) {
    var apiKey = '';
    var name = '';
    var apiServerUrl = '';
    var i = 0;
    while (i < buf.length) {
      final tagRead = _readVarint(buf, i);
      final tag = tagRead.$1;
      i += tagRead.$2;
      final fieldNum = tag >> 3;
      final wireType = tag & 7;
      if (wireType != 2) {
        // 跳过非 LEN
        if (wireType == 0) {
          final r = _readVarint(buf, i);
          i += r.$2;
        } else if (wireType == 1) {
          i += 8;
        } else if (wireType == 5) {
          i += 4;
        } else {
          throw FormatException('未知 wire_type $wireType');
        }
        continue;
      }
      final lenRead = _readVarint(buf, i);
      final length = lenRead.$1;
      i += lenRead.$2;
      if (i + length > buf.length) {
        throw const FormatException('LEN 字段截断');
      }
      final value = utf8.decode(buf.sublist(i, i + length));
      i += length;
      switch (fieldNum) {
        case 1:
          apiKey = value;
          break;
        case 2:
          name = value;
          break;
        case 3:
          apiServerUrl = value;
          break;
      }
    }
    return WindsurfRegisterResult(
      apiKey: apiKey,
      name: name,
      apiServerUrl: apiServerUrl,
    );
  }
}

class WindsurfRegisterResult {
  final String apiKey;
  final String name;
  final String apiServerUrl;
  const WindsurfRegisterResult({
    required this.apiKey,
    required this.name,
    required this.apiServerUrl,
  });

  Map<String, dynamic> toJson() => {
        'api_key': apiKey,
        'name': name,
        'api_server_url': apiServerUrl,
      };
}

class WindsurfRegisterException implements Exception {
  final String message;
  WindsurfRegisterException(this.message);
  @override
  String toString() => message;
}
