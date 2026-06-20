class AppConfig {
  // 默认值仅用于本地开发占位；正式发布请通过用户登录/扫码或环境变量注入真实值，不要把生产 token 硬编码进客户端。
  static const String defaultServerUrl = 'https://your-domain.example.com';
  static const String defaultSessionId = 'YOUR-SESSION-ID';
  static const String defaultToken = 'YOUR-SESSION-ID:YOUR-JWT-SECRET';
  static const Duration heartbeatInterval = Duration(seconds: 20);
  static const Duration reconnectDelay = Duration(seconds: 2);
  static const int maxReconnectAttempts = 999;
  static const Duration pongTimeout = Duration(seconds: 10);
  static const Duration pollFallbackInterval = Duration(seconds: 30);
}
