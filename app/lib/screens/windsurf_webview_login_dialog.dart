// Windsurf 嵌入式登录对话框 - 在 App 内打开 webview 登录, 自动拦截 access_token
//
// 流程:
//   1. 用户输入 email + password (可选, 仅 login_hint)
//   2. 点 "开始登录" → 弹出全屏 webview, 加载 windsurf 官方 OAuth URL
//   3. 用户在 webview 内登录
//   4. windsurf 重定向到 redirect_uri=show-auth-token, 页面 URL 带 ?access_token=xxx
//   5. 监听 onUpdateVisitedHistory / shouldOverrideUrlLoading 拦截到 access_token
//   6. 自动关 webview, 返回 token 给调用方
//
// 完全无需用户复制粘贴 / 跨应用切换. 退路: 旧 _AddAccountDialog (外部浏览器+手动复制).
//
// 跨平台: flutter_inappwebview ^6.x 支持 Android/iOS/macOS, Windows 桌面端
//        在 6.x 上是实验性的, 用户首次会下载 WebView2 Runtime (~120MB).
import 'dart:convert';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 启动嵌入式 webview 登录对话框。
/// 返回 `{email, password, firebase_id_token}` 或 null (用户取消).
///
/// 调用方与原 `_AddAccountDialog` 返回格式兼容, 上层逻辑无需改动。
Future<Map<String, dynamic>?> showWindsurfWebViewLogin({
  required BuildContext context,
  String? prefilledEmail,
}) async {
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WindsurfWebViewLoginDialog(prefilledEmail: prefilledEmail),
  );
}

/// 检查当前平台是否支持嵌入式 webview。
/// Web / Linux 桌面 不支持; Windows 桌面 6.x beta; 其他平台 OK.
bool isWindsurfWebViewSupported() {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return true;
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return false;
  }
}

class _WindsurfWebViewLoginDialog extends StatefulWidget {
  const _WindsurfWebViewLoginDialog({this.prefilledEmail});
  final String? prefilledEmail;

  @override
  State<_WindsurfWebViewLoginDialog> createState() =>
      _WindsurfWebViewLoginDialogState();
}

class _WindsurfWebViewLoginDialogState
    extends State<_WindsurfWebViewLoginDialog> {
  // windsurf cascade extension 用的官方 OAuth client_id（从 dist/extension.js 反编译）
  static const _windsurfClientId = '3GUryQ7ldAeKEuD2obYnppsnmj58eP5u';

  final _emailCtl = TextEditingController();
  final _pwdCtl = TextEditingController();
  bool _showPwd = false;
  bool _started = false;
  bool _loading = false;
  String? _stateUuid;
  String? _capturedToken;
  // 自动填表 - 最多触发 3 次 (邮箱页 → 密码页 → 兜底), 防死循环
  int _autoFillCount = 0;
  // 已经自动填过的 URL 路径 (避免同页面反复填)
  final Set<String> _autoFilledPaths = {};
  // 自动填表延迟定时器, 避免 onLoadStop 反复触发
  // (Windows webview 加载多次, 用 last-write-wins 防抖)
  InAppWebViewController? _webController;

  @override
  void initState() {
    super.initState();
    if (widget.prefilledEmail != null) {
      _emailCtl.text = widget.prefilledEmail!;
    }
    _stateUuid = DateTime.now().millisecondsSinceEpoch.toString();
  }

  @override
  void dispose() {
    _emailCtl.dispose();
    _pwdCtl.dispose();
    super.dispose();
  }

  Uri _buildLoginUrl() {
    final email = _emailCtl.text.trim();
    final params = <String, String>{
      'response_type': 'token',
      'client_id': _windsurfClientId,
      'redirect_uri': 'show-auth-token',
      'state': _stateUuid ?? '',
      'prompt': 'login',
      'redirect_parameters_type': 'query',
    };
    if (email.isNotEmpty) {
      params['login_hint'] = email;
    }
    return Uri.https('windsurf.com', '/windsurf/signin', params);
  }

  /// 从 URL 中提取 access_token (支持 query 和 fragment 两种位置)
  String? _extractAccessToken(Uri uri) {
    // 标准 OAuth implicit flow: token 在 fragment (#access_token=xxx)
    if (uri.fragment.isNotEmpty) {
      final fragParams = Uri.splitQueryString(uri.fragment);
      final t = fragParams['access_token'];
      if (t != null && t.isNotEmpty) return t;
    }
    // windsurf 用的是 redirect_parameters_type=query, token 在 query
    final qp = uri.queryParameters;
    final t = qp['access_token'];
    if (t != null && t.isNotEmpty) return t;
    // 也兜底看下 token 字段
    final t2 = qp['token'];
    if (t2 != null && t2.isNotEmpty) return t2;
    return null;
  }

  /// 拦截 URL: 看到 access_token 就关闭 webview 返回 token
  Future<void> _onUrlChanged(Uri? uri) async {
    if (uri == null || _capturedToken != null) return;
    final token = _extractAccessToken(uri);
    if (token == null) return;
    _capturedToken = token;
    if (!mounted) return;
    Navigator.of(context).pop({
      'email': _emailCtl.text.trim(),
      'password': _pwdCtl.text,
      'firebase_id_token': token,
    });
  }

  /// 自动填邮箱/密码 + 点登录按钮 (无需用户手动输入).
  /// 在 windsurf.com 登录页 onLoadStop 时调用. 用 React-aware setter
  /// 触发受控组件 onChange. 同一 URL path 只填一次, 总次数最多 3 次防死循环.
  Future<void> _tryAutoFill(Uri? uri) async {
    if (uri == null || _capturedToken != null) return;
    if (_webController == null) return;
    if (_pwdCtl.text.isEmpty) return; // 没填密码就不自动登录, 让用户手动操作
    if (_autoFillCount >= 3) return;
    // 只在 windsurf 主域 + 子域名 (auth.windsurf.com 之类) 注入, 防止泄漏给第三方 SSO 站
    final host = uri.host.toLowerCase();
    if (!host.endsWith('windsurf.com') && !host.endsWith('codeium.com')) {
      return;
    }
    // 同一 path 只填一次 (windsurf 登录页 SPA 切 step 时 onLoadStop 会反复触发)
    final pathKey = '${uri.host}${uri.path}';
    if (_autoFilledPaths.contains(pathKey)) return;
    // 只在登录相关页面注入, profile / callback 页跳过
    final p = uri.path.toLowerCase();
    if (!(p.contains('signin') || p.contains('login') || p.contains('auth'))) {
      return;
    }
    _autoFilledPaths.add(pathKey);
    _autoFillCount++;
    // 等 React/Vue 渲染完 input (Windsurf 登录页是 SPA, onLoadStop 时 DOM 可能还没 mount)
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted || _webController == null || _capturedToken != null) return;
    final email = jsonEncode(_emailCtl.text.trim());
    final pwd = jsonEncode(_pwdCtl.text);
    final js = '''
(function(email, pwd) {
  // React/Next.js 受控 input: 用原生 setter 后 dispatch input event 才能触发 onChange
  function setReactValue(input, value) {
    var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function findClickButton(matchRegex) {
    var btns = Array.from(document.querySelectorAll('button, [role="button"], input[type="submit"]'));
    return btns.find(function(b) { return matchRegex.test((b.innerText || b.value || '').trim()); });
  }
  // === 优先级 1: 密码输入框可见 → 填密码 + 点 Log in ===
  var pwdInput = document.querySelector('input[type="password"]');
  if (pwdInput && pwdInput.offsetParent !== null) {
    setReactValue(pwdInput, pwd);
    var loginBtn = findClickButton(/^\\s*log\\s*in\\s*\$/i)
                || findClickButton(/^\\s*sign\\s*in\\s*\$/i)
                || findClickButton(/^\\s*continue\\s*\$/i);
    setTimeout(function(){ if (loginBtn) loginBtn.click(); }, 200);
    return 'pwd_filled' + (loginBtn ? '_clicked' : '_no_btn');
  }
  // === 优先级 2: 邮箱输入框可见且为空 → 填邮箱 + 点 Continue ===
  var emailInput = document.querySelector('input[type="email"], input[name="email" i], input[autocomplete="username"], input[id*="email" i]');
  if (emailInput && emailInput.offsetParent !== null && !emailInput.value) {
    setReactValue(emailInput, email);
    var nextBtn = findClickButton(/^\\s*continue\\s*\$/i)
               || findClickButton(/^\\s*next\\s*\$/i)
               || findClickButton(/^\\s*log\\s*in\\s*\$/i);
    setTimeout(function(){ if (nextBtn) nextBtn.click(); }, 200);
    return 'email_filled' + (nextBtn ? '_clicked' : '_no_btn');
  }
  return 'no_input_visible';
})($email, $pwd);
''';
    try {
      final r = await _webController!.evaluateJavascript(source: js);
      // ignore: avoid_print
      debugPrint('[webview_login] autofill[$_autoFillCount] $pathKey -> $r');
    } catch (e) {
      debugPrint('[webview_login] autofill error: $e');
    }
  }

  void _start() {
    final email = _emailCtl.text.trim();
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('请先填邮箱'),
        backgroundColor: Colors.orange,
      ));
      return;
    }
    setState(() {
      _started = true;
      _loading = true;
    });
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  Future<void> _clearCookiesAndRetry() async {
    final cookieManager = CookieManager.instance();
    await cookieManager.deleteAllCookies();
    if (_webController != null) {
      await _webController!.loadUrl(
        urlRequest: URLRequest(url: WebUri.uri(_buildLoginUrl())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      return _buildIntroDialog();
    }
    return _buildWebViewDialog();
  }

  Widget _buildIntroDialog() {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.web, color: Colors.blue, size: 22),
          const SizedBox(width: 8),
          Text(widget.prefilledEmail == null ? '添加 Windsurf 账号' : '重新登录账号'),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '直接在 IDE Claw 内嵌的浏览器中完成登录, 无需打开外部浏览器、无需复制粘贴 token.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailCtl,
              enabled: widget.prefilledEmail == null,
              autofocus: widget.prefilledEmail == null,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: '邮箱 *',
                helperText: '账号标识 + 自动填到 Windsurf 登录页',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pwdCtl,
              obscureText: !_showPwd,
              decoration: InputDecoration(
                labelText: '密码 (强烈推荐填写, 可一键全自动登录)',
                helperText: '填了密码就自动注入 Windsurf 登录页 + 自动点 Log in, 完全无需手动操作; 不填则只自动跳页, 密码部分手动输入',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_showPwd ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPwd = !_showPwd),
                ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: const Text(
                '点击下方按钮后会内嵌打开 windsurf.com 登录页:\n'
                ' • 填了密码 → 全自动 (注入邮箱+密码+点登录, 拿到 token 关闭)\n'
                ' • 不填密码 → 半自动 (邮箱已填, 你只需输密码点 Log in)\n'
                ' • Google / GitHub SSO 不能自动 (需要手动跳第三方授权)\n'
                ' • Windows 桌面端首次需 WebView2 Runtime (Win10/11 自带)',
                style: TextStyle(fontSize: 11, color: Colors.blueGrey),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('取消')),
        ElevatedButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.login),
          label: const Text('开始登录'),
        ),
      ],
    );
  }

  Widget _buildWebViewDialog() {
    final mq = MediaQuery.of(context);
    final isMobile = mq.size.width < 600;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 8 : 40,
        vertical: isMobile ? 8 : 40,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          // 顶部工具栏
          Material(
            color: Theme.of(context).colorScheme.primary,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.lock, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Windsurf 登录 (App 内嵌)',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13),
                    ),
                  ),
                  IconButton(
                    iconSize: 20,
                    color: Colors.white,
                    tooltip: '清 cookie 重新登录',
                    icon: const Icon(Icons.refresh),
                    onPressed: _clearCookiesAndRetry,
                  ),
                  IconButton(
                    iconSize: 20,
                    color: Colors.white,
                    tooltip: '取消',
                    icon: const Icon(Icons.close),
                    onPressed: _cancel,
                  ),
                ],
              ),
            ),
          ),
          // WebView
          Expanded(
            child: Stack(
              children: [
                InAppWebView(
                  initialUrlRequest: URLRequest(
                    url: WebUri.uri(_buildLoginUrl()),
                  ),
                  initialSettings: InAppWebViewSettings(
                    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                        'AppleWebKit/537.36 (KHTML, like Gecko) '
                        'Chrome/130.0.0.0 Safari/537.36',
                    javaScriptEnabled: true,
                    cacheEnabled: true,
                    useShouldOverrideUrlLoading: true,
                  ),
                  onWebViewCreated: (c) => _webController = c,
                  onLoadStop: (c, url) async {
                    setState(() => _loading = false);
                    await _onUrlChanged(url);
                    await _tryAutoFill(url);
                  },
                  onLoadStart: (c, url) => _onUrlChanged(url),
                  onUpdateVisitedHistory: (c, url, _) => _onUrlChanged(url),
                  shouldOverrideUrlLoading: (c, navAction) async {
                    final u = navAction.request.url;
                    if (u != null) {
                      final token = _extractAccessToken(u);
                      if (token != null) {
                        await _onUrlChanged(u);
                        return NavigationActionPolicy.CANCEL;
                      }
                    }
                    return NavigationActionPolicy.ALLOW;
                  },
                ),
                if (_loading)
                  const LinearProgressIndicator(minHeight: 2),
              ],
            ),
          ),
          // 底部状态栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.grey[100],
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: Colors.grey[700]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '正在自动登录... 拿到 token 后会自动关闭. 卡住请点右上角 ⟳ 清 cookie 重试; 失败请检查密码是否正确.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
