import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../services/windsurf_register_client.dart';
import 'windsurf_webview_login_dialog.dart';

/// Windsurf 账号池管理界面（星火换号集成）
///
/// 功能（与星火无痕换号 v8.3.8 对齐）：
///   - 列出所有账号 + 显示 daily/weekly 剩余额度百分比
///   - 添加账号（email + password，后端自动调代理登录拿 token）
///   - 删除账号
///   - 单个/全部刷新额度
///   - 手动切换激活账号 + 自动找下一个可用
///   - 显示当前激活账号 + 自动切换阈值
class WindsurfAccountsScreen extends StatefulWidget {
  final ApiService apiService;
  final String? targetSessionId; // 切换命令广播给哪个 session（默认 ide-claw-001）

  const WindsurfAccountsScreen({
    super.key,
    required this.apiService,
    this.targetSessionId,
  });

  @override
  State<WindsurfAccountsScreen> createState() => _WindsurfAccountsScreenState();
}

class _WindsurfAccountsScreenState extends State<WindsurfAccountsScreen> {
  List<Map<String, dynamic>> _accounts = [];
  String? _activeEmail;
  double _threshold = 5.0;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPool();
  }

  Future<void> _loadPool({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.apiService.listWindsurfPool();
      if (!mounted) return;
      setState(() {
        _accounts = (data['accounts'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        _activeEmail = data['active_email'] as String?;
        _threshold = (data['default_thresh'] as num?)?.toDouble() ?? 5.0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 让用户选择登录方式 (App 内嵌 webview / 外部浏览器复制 token).
  /// 平台不支持 webview 时直接走外部浏览器, 不弹选择对话框.
  Future<Map<String, dynamic>?> _pickLoginMethod({
    required String? prefilledEmail,
  }) async {
    if (!isWindsurfWebViewSupported()) {
      return showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _AddAccountDialog(prefilledEmail: prefilledEmail),
      );
    }
    final method = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择登录方式'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'webview'),
            child: ListTile(
              leading: const Icon(Icons.web, color: Colors.green),
              title: const Text('App 内嵌登录 (推荐)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('直接在 IDE Claw 内打开 webview, '
                  '无需切换浏览器, 自动拦截 token'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'browser'),
            child: const ListTile(
              leading: Icon(Icons.open_in_browser, color: Colors.grey),
              title: Text('外部浏览器 (旧流程)'),
              subtitle: Text('打开系统浏览器登录后手动复制 token. '
                  '仅作 webview 失败时的 fallback'),
            ),
          ),
        ],
      ),
    );
    if (method == null) return null;
    if (!mounted) return null;
    if (method == 'webview') {
      return showWindsurfWebViewLogin(
        context: context,
        prefilledEmail: prefilledEmail,
      );
    }
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _AddAccountDialog(prefilledEmail: prefilledEmail),
    );
  }

  Future<void> _addAccount() async {
    final result = await _pickLoginMethod(prefilledEmail: null);
    if (result == null || !mounted) return;
    final scaffold = ScaffoldMessenger.of(context);
    final email = result['email'] as String;
    final password = result['password'] as String? ?? '';
    final firebaseIdToken = result['firebase_id_token'] as String? ?? '';

    if (firebaseIdToken.isEmpty) {
      scaffold.showSnackBar(const SnackBar(
        content: Text('access_token 不能为空'),
        backgroundColor: Colors.red,
      ));
      return;
    }
    scaffold.showSnackBar(const SnackBar(
      content: Text('① 本地直连 register.windsurf.com 注册...'),
      duration: Duration(seconds: 30),
    ));
    try {
      // 步骤 1: 客户端本地调 windsurf 官方 RegisterUser
      // （为什么不在服务端？国内 VPS 到 register.windsurf.com 超时）
      final reg = await WindsurfRegisterClient.register(firebaseIdToken);
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      scaffold.showSnackBar(const SnackBar(
        content: Text('② 上报 apiKey 给服务端入库...'),
        duration: Duration(seconds: 15),
      ));
      // 步骤 2: 把 apiKey 上传服务端入库
      final r = await widget.apiService.saveWindsurfRegisterResult(
        email: email,
        apiKey: reg.apiKey,
        name: reg.name,
        apiServerUrl: reg.apiServerUrl,
        password: password,
      );
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      scaffold.showSnackBar(SnackBar(
        content: Text('已添加 ${r['email']} (name=${reg.name})'),
        backgroundColor: Colors.green,
      ));
      _loadPool(silent: true);
    } catch (e) {
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      await _showRegisterFailureDialog(email, e.toString());
    }
  }

  Future<void> _reauthOAuth(String email) async {
    final result = await _pickLoginMethod(prefilledEmail: email);
    if (result == null || !mounted) return;
    final scaffold = ScaffoldMessenger.of(context);
    final firebaseIdToken = result['firebase_id_token'] as String? ?? '';
    if (firebaseIdToken.isEmpty) return;
    scaffold.showSnackBar(const SnackBar(
      content: Text('① 本地直连 register.windsurf.com 重新注册...'),
      duration: Duration(seconds: 30),
    ));
    try {
      final reg = await WindsurfRegisterClient.register(firebaseIdToken);
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      scaffold.showSnackBar(const SnackBar(
        content: Text('② 上报新 apiKey 给服务端...'),
        duration: Duration(seconds: 15),
      ));
      final r = await widget.apiService.saveWindsurfRegisterResult(
        email: email,
        apiKey: reg.apiKey,
        name: reg.name,
        apiServerUrl: reg.apiServerUrl,
        password: result['password'] as String? ?? '',
      );
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      scaffold.showSnackBar(SnackBar(
        content: Text('已更新 ${r['email']} 的 apiKey'),
        backgroundColor: Colors.green,
      ));
      _loadPool(silent: true);
    } catch (e) {
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      await _showRegisterFailureDialog(email, e.toString());
    }
  }

  Future<void> _showRegisterFailureDialog(String email, String error) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('windsurf 注册失败'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('账号: $email'),
                const SizedBox(height: 8),
                Text('错误: $error',
                    style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber[50],
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.amber[300]!),
                  ),
                  child: const Text(
                    '常见原因：\n'
                    '1. access_token 已过期 (windsurf 浏览器 token 短时效) → 重新打开登录页拿新 token\n'
                    '2. access_token 拷贝时漏了字符 / 多了空格\n'
                    '3. 服务端到 register.windsurf.com 网络受限\n\n'
                    '建议：\n'
                    '- 浏览器登录后页面会显示 "Authentication Token"，整段复制（不要用截图 OCR）\n'
                    '- 拷贝粘贴后 1 分钟内提交（token 短时效）\n'
                    '- 如果用网页 token URL 直接打开，注意当前浏览器是否登录正确账号',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }


  Future<void> _refreshAll() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final scaffold = ScaffoldMessenger.of(context);
    scaffold.showSnackBar(const SnackBar(
      content: Text('正在刷新所有账号额度...'),
      duration: Duration(seconds: 60),
    ));
    try {
      final r = await widget.apiService.refreshAllWindsurfQuotas();
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      final ok = r['ok'] ?? 0;
      final fail = r['fail'] ?? 0;
      scaffold.showSnackBar(SnackBar(
        content: Text('刷新完成：成功 $ok / 失败 $fail'),
        backgroundColor: fail > 0 ? Colors.orange : Colors.green,
      ));
      _loadPool(silent: true);
    } catch (e) {
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      scaffold.showSnackBar(SnackBar(
        content: Text('刷新失败: $e'),
        backgroundColor: Colors.red,
      ));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refreshOne(String email) async {
    final scaffold = ScaffoldMessenger.of(context);
    scaffold.showSnackBar(SnackBar(
      content: Text('刷新 $email...'),
      duration: const Duration(seconds: 20),
    ));
    try {
      await widget.apiService.refreshWindsurfQuota(email);
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      scaffold.showSnackBar(const SnackBar(
        content: Text('已刷新'),
        backgroundColor: Colors.green,
      ));
      _loadPool(silent: true);
    } catch (e) {
      if (!mounted) return;
      scaffold.hideCurrentSnackBar();
      scaffold.showSnackBar(SnackBar(
        content: Text('刷新失败: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _switchTo(String email) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换账号'),
        content: Text(
            '把激活账号切换到 $email？\n服务器会广播 windsurf_switch 命令给桌面端，由桌面端去修补本地 Windsurf 并重启。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('切换')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.apiService.switchWindsurfAccount(
        email: email,
        reason: 'manual',
        targetSessionId: widget.targetSessionId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已切到 $email'),
        backgroundColor: Colors.green,
      ));
      _loadPool(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('切换失败: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _switchNext() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自动切到下一个'),
        content: const Text('服务器会找一个 daily/weekly 余量都 ≥ 阈值的账号并切过去。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('切换')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final r = await widget.apiService.switchWindsurfAccount(
        reason: 'manual_next',
        targetSessionId: widget.targetSessionId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已切到 ${r['email']}'),
        backgroundColor: Colors.green,
      ));
      _loadPool(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('切换失败: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _deleteAccount(String email) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账号'),
        content: Text('确认从账号池删除 $email？\n该账号的本地缓存 token 也会被清除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.apiService.deleteWindsurfAccount(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已删除 $email'),
      ));
      _loadPool(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('删除失败: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Windsurf 账号池'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: '自动切到下一个',
            onPressed: _accounts.isEmpty ? null : _switchNext,
          ),
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.cloud_sync),
            tooltip: '刷新所有额度',
            onPressed: _refreshing || _accounts.isEmpty ? null : _refreshAll,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加账号',
            onPressed: _addAccount,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Colors.red[300])),
            const SizedBox(height: 16),
            ElevatedButton(
                onPressed: _loadPool, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_accounts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_circle_outlined,
                  size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              const Text('账号池为空',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('点击右上角 ＋ 添加 Windsurf 账号',
                  style: TextStyle(color: Colors.grey[600])),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('添加账号'),
                onPressed: _addAccount,
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadPool(silent: true),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
        itemCount: _accounts.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) return _buildHeader();
          return _buildAccountCard(_accounts[i - 1]);
        },
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.grey[500]),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '当前激活: ${_activeEmail ?? "(未设置)"}    ·    自动切换阈值: ${_threshold.toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(Map<String, dynamic> a) {
    final email = a['email'] as String? ?? '';
    final isActive = a['is_active'] == true || _activeEmail == email;
    final isExpired = a['is_expired'] == true;
    final dailyP = (a['daily_remaining_percent'] as num?)?.toDouble();
    final weeklyP = (a['weekly_remaining_percent'] as num?)?.toDouble();
    final dailyResetUnix = (a['daily_reset_at_unix'] as num?)?.toInt() ?? 0;
    final weeklyResetUnix = (a['weekly_reset_at_unix'] as num?)?.toInt() ?? 0;
    final planName = a['plan_name'] as String? ?? '';
    final quotaUpdatedAt = a['quota_updated_at'] as String? ?? '';
    final loginCount = a['login_count'] ?? 0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isActive ? Colors.green : Colors.transparent,
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头：email + 激活徽章 + 菜单
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(email,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  fontFamily: 'monospace'),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (isActive) const SizedBox(width: 6),
                        if (isActive)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('激活',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600)),
                          ),
                        if (isExpired) const SizedBox(width: 6),
                        if (isExpired)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('过期',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600)),
                          ),
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (planName.isNotEmpty) planName,
                          if (loginCount > 0) '登录 $loginCount 次',
                          if (quotaUpdatedAt.isNotEmpty)
                            '更新: ${_humanTime(quotaUpdatedAt)}'
                        ].join(' · '),
                        style:
                            TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (v) async {
                    switch (v) {
                      case 'switch':
                        await _switchTo(email);
                        break;
                      case 'refresh':
                        await _refreshOne(email);
                        break;
                      case 'reauth_oauth':
                        await _reauthOAuth(email);
                        break;
                      case 'delete':
                        await _deleteAccount(email);
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    if (!isActive)
                      const PopupMenuItem(
                        value: 'switch',
                        child: Row(children: [
                          Icon(Icons.swap_horiz, size: 18),
                          SizedBox(width: 8),
                          Text('切换到此账号'),
                        ]),
                      ),
                    const PopupMenuItem(
                      value: 'refresh',
                      child: Row(children: [
                        Icon(Icons.refresh, size: 18),
                        SizedBox(width: 8),
                        Text('刷新额度'),
                      ]),
                    ),
                    const PopupMenuItem(
                      value: 'reauth_oauth',
                      child: Row(children: [
                        Icon(Icons.refresh, size: 18, color: Colors.blue),
                        SizedBox(width: 8),
                        Text('重新登录 (OAuth)',
                            style: TextStyle(color: Colors.blue)),
                      ]),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(children: [
                        Icon(Icons.delete_outline,
                            size: 18, color: Colors.red),
                        SizedBox(width: 8),
                        Text('删除', style: TextStyle(color: Colors.red)),
                      ]),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildQuotaBar('日额度', dailyP, dailyResetUnix),
            const SizedBox(height: 6),
            _buildQuotaBar('周额度', weeklyP, weeklyResetUnix),
          ],
        ),
      ),
    );
  }

  Widget _buildQuotaBar(String label, double? percent, int resetUnix) {
    final hasData = percent != null;
    final pct = (percent ?? 0).clamp(0.0, 100.0);
    Color barColor;
    if (!hasData) {
      barColor = Colors.grey[400]!;
    } else if (pct < _threshold) {
      barColor = Colors.red;
    } else if (pct < 20) {
      barColor = Colors.orange;
    } else if (pct < 50) {
      barColor = Colors.amber;
    } else {
      barColor = Colors.green;
    }

    String resetStr = '';
    if (resetUnix > 0) {
      final reset = DateTime.fromMillisecondsSinceEpoch(resetUnix * 1000);
      final diff = reset.difference(DateTime.now());
      if (diff.inSeconds > 0) {
        if (diff.inDays > 0) {
          resetStr = '${diff.inDays}d 后重置';
        } else if (diff.inHours > 0) {
          resetStr = '${diff.inHours}h 后重置';
        } else {
          resetStr = '${diff.inMinutes}m 后重置';
        }
      }
    }

    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label,
              style: TextStyle(fontSize: 11, color: Colors.grey[700])),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: hasData ? pct / 100.0 : null,
              minHeight: 8,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 80,
          child: Text(
            hasData ? '${pct.toStringAsFixed(1)}%' : '未拉取',
            style: TextStyle(
              fontSize: 12,
              color: hasData ? barColor : Colors.grey,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.right,
          ),
        ),
        if (resetStr.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(resetStr,
                style: TextStyle(fontSize: 10, color: Colors.grey[500])),
          ),
      ],
    );
  }

  String _humanTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return '刚刚';
      if (diff.inHours < 1) return '${diff.inMinutes}m 前';
      if (diff.inDays < 1) return '${diff.inHours}h 前';
      return '${diff.inDays}d 前';
    } catch (_) {
      return iso;
    }
  }
}

/// 添加 Windsurf 账号对话框（**完整、独立、不依赖任何第三方代理**）
///
/// 流程（抄自 windsurf cascade extension `dist/extension.js` 的 `provideAuthToken`）：
///   1. 客户端构造登录 URL（response_type=token, redirect_uri=show-auth-token）
///   2. url_launcher 打开浏览器
///   3. 用户在浏览器登录后，页面**直接显示** access_token (firebase_id_token)
///   4. 用户复制 token 粘贴到此对话框
///   5. 提交 → 服务端调 register.windsurf.com/RegisterUser 拿真实 apiKey 入库
class _AddAccountDialog extends StatefulWidget {
  const _AddAccountDialog({this.prefilledEmail});
  final String? prefilledEmail;

  @override
  State<_AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<_AddAccountDialog> {
  // windsurf cascade extension 用的官方 OAuth client_id（从 dist/extension.js 反编译）
  static const _windsurfClientId = '3GUryQ7ldAeKEuD2obYnppsnmj58eP5u';

  final _emailCtl = TextEditingController();
  final _pwdCtl = TextEditingController();
  final _tokenCtl = TextEditingController();
  bool _showPwd = false;
  String? _stateUuid;

  @override
  void initState() {
    super.initState();
    if (widget.prefilledEmail != null) {
      _emailCtl.text = widget.prefilledEmail!;
    }
    // 生成一个 state（防 CSRF），实际我们不验证，只为了构造完整 URL
    _stateUuid = DateTime.now().millisecondsSinceEpoch.toString();
  }

  @override
  void dispose() {
    _emailCtl.dispose();
    _pwdCtl.dispose();
    _tokenCtl.dispose();
    super.dispose();
  }

  /// 构造 windsurf 官方登录 URL
  /// 关键参数：
  ///   - response_type=token : 隐式 OAuth 流程
  ///   - redirect_uri=show-auth-token : 特殊魔法值，登录成功后页面直接显示 token
  ///   - prompt=login : 强制重新登录（避免拿到当前已登录账号的 token）
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

  Future<void> _openLoginUrl() async {
    final url = _buildLoginUrl();
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('无法打开浏览器，请手动复制 URL: $url'),
        backgroundColor: Colors.orange,
      ));
    }
  }

  Future<void> _copyLoginUrl() async {
    await Clipboard.setData(ClipboardData(text: _buildLoginUrl().toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('登录 URL 已复制到剪贴板'),
      duration: Duration(seconds: 2),
    ));
  }

  /// 打开 windsurf.com 注销页, 清空浏览器 cookie。
  /// 不注销会导致 OAuth URL 被 cookie session 短路, 直接跳到 /profile 看不到 token
  Future<void> _openLogoutUrl() async {
    final ok = await launchUrl(
      Uri.parse('https://windsurf.com/logout'),
      mode: LaunchMode.externalApplication,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('无法打开浏览器, 请手动访问 https://windsurf.com/logout'),
        backgroundColor: Colors.orange,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.verified_user, color: Colors.green, size: 22),
          const SizedBox(width: 8),
          Text(widget.prefilledEmail == null ? '添加 Windsurf 账号' : '重新登录账号'),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 步骤 1: 邮箱（标识 + login_hint）
              _stepHeader('1', '账号信息'),
              const SizedBox(height: 8),
              TextField(
                controller: _emailCtl,
                keyboardType: TextInputType.emailAddress,
                enabled: widget.prefilledEmail == null,
                autofocus: widget.prefilledEmail == null,
                decoration: const InputDecoration(
                  labelText: '邮箱 *',
                  helperText: '用作账号标识 + 登录页 login_hint',
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
                  labelText: '密码 (可选, 仅备份)',
                  helperText: '不会发给 windsurf, 仅本地保存以便切号时可手动登录',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _showPwd ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showPwd = !_showPwd),
                  ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),

              // 步骤 2: 注销浏览器旧 cookie (关键! 不做会跳到 /profile 看不到 token)
              _stepHeader('2', '注销浏览器中的旧 windsurf.com cookie'),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openLogoutUrl,
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('打开 windsurf.com/logout (强烈推荐)'),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber[50],
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.amber[300]!),
                ),
                child: const Text(
                  '为什么需要这一步？\n'
                  '如果浏览器之前登录过 windsurf.com (有 cookie), 下一步打开登录页时会被 cookie session 短路, '
                  '直接跳转到 /profile, 看不到 token. 注销一次就解决.\n'
                  '替代方案: 用浏览器无痕窗口打开下一步的登录链接.',
                  style: TextStyle(fontSize: 11, color: Colors.brown),
                ),
              ),
              const SizedBox(height: 16),

              // 步骤 3: 打开浏览器登录
              _stepHeader('3', '打开 Windsurf 登录页 (拿 token)'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _openLoginUrl,
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text('打开 windsurf.com 登录页'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _copyLoginUrl,
                    icon: const Icon(Icons.copy),
                    tooltip: '复制 URL',
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: const Text(
                  '登录成功后页面会显示一段 "Authentication Token" 文本框 + 复制按钮。\n'
                  '整段复制粘贴到下面 (不要漏字符 / 加空格)。\n'
                  '注意: token 短时效 (约 1 分钟), 拿到后尽快粘贴提交。\n\n'
                  '没看到 token? → 回到步骤 2 注销, 或用无痕窗口重新打开登录页。',
                  style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                ),
              ),
              const SizedBox(height: 16),

              // 步骤 4: 粘贴 token
              _stepHeader('4', '粘贴 access_token'),
              const SizedBox(height: 8),
              TextField(
                controller: _tokenCtl,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Authentication Token *',
                  hintText:
                      '形如 eyJhbGciOiJIUzI1Ni... (Firebase ID JWT) 或 auth1_xxx',
                  prefixIcon: Icon(Icons.vpn_key, size: 18),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 12),

              // 底部说明
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.green[200]!),
                ),
                child: const Text(
                  '此流程完全独立: 客户端本地直连 windsurf 官方'
                  ' register.windsurf.com/RegisterUser 拿到真实 apiKey 后, 上报给服务端入库。'
                  '不依赖 willxin666 / indevs.in 任何第三方代理。\n'
                  '（注册步骤需要本机能访问 windsurf.com, 国内可能需开梯子）',
                  style: TextStyle(fontSize: 11, color: Colors.green),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _onSubmit,
          child: const Text('注册'),
        ),
      ],
    );
  }

  Widget _stepHeader(String num, String title) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.blue,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(num,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ],
    );
  }

  void _onSubmit() {
    final email = _emailCtl.text.trim();
    if (email.isEmpty) return;
    final token = _tokenCtl.text.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('请先在步骤 2 打开浏览器登录后, 把 token 粘贴到步骤 3 的输入框'),
        backgroundColor: Colors.orange,
      ));
      return;
    }
    Navigator.pop(context, {
      'email': email,
      'password': _pwdCtl.text,
      'firebase_id_token': token,
    });
  }
}
