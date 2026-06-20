import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/session.dart';
import '../models/message.dart';
import '../providers/message_provider.dart';
import '../services/api_service.dart';
import '../services/ws_service.dart';
import '../services/download_service.dart';
import '../services/notification_service.dart';
import '../config/app_config.dart';
import '../services/local_ipc_service.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_filex/open_filex.dart';
import '../services/windsurf_patch_service.dart';
import 'about_screen.dart';
import 'image_preview_screen.dart';
import 'markdown_viewer_screen.dart';
import 'windsurf_accounts_screen.dart';
import '../widgets/workspace_file_picker.dart';
import '../models/workspace_session.dart';

/// 桌面端主界面：左右分栏（会话列表 + 聊天窗口），类似微信电脑版
class DesktopHomeScreen extends StatefulWidget {
  final ApiService apiService;
  final LocalIpcService? localIpcService;

  const DesktopHomeScreen({super.key, required this.apiService, this.localIpcService});

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen>
    with WidgetsBindingObserver {
  List<PushSession> _sessions = [];
  bool _loading = true;
  String? _error;
  String? _selectedSessionId;
  String _selectedSessionName = '';

  // 缓存MessageProvider，避免切换会话时丢失消息
  final Map<String, MessageProvider> _providerCache = {};

  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  late final FocusNode _focusNode;
  final List<_AttachmentItem> _attachments = [];

  // Auto-hang (自动挂机) state
  bool _autoHang = false;
  Timer? _autoHangTimer;

  // Local IPC
  StreamSubscription? _localIpcSub;

  // 系统命令 WS（专门订阅 windsurf_switch 等系统级事件）
  WsService? _systemWs;
  StreamSubscription? _windsurfSwitchSub;
  String? _lastSwitchEmail;
  DateTime? _lastSwitchAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initLocalIpc();
    _initSystemWs();

    _focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        // Enter = send, Shift+Enter = newline
        if (event.logicalKey == LogicalKeyboardKey.enter &&
            !HardwareKeyboard.instance.isShiftPressed) {
          _send();
          return KeyEventResult.handled;
        }

        // Ctrl+V = check clipboard for image
        if (event.logicalKey == LogicalKeyboardKey.keyV &&
            HardwareKeyboard.instance.isControlPressed) {
          debugPrint('[paste] Ctrl+V detected in desktop_home_screen');
          _handleDesktopPaste();
          return KeyEventResult.ignored; // also allow normal text paste
        }

        return KeyEventResult.ignored;
      },
    );


    // 监听 @ 输入：自动弹工作区文件搜索
    _textController.addListener(_onTextChangedForAtMention);
    _loadSessions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _localIpcSub?.cancel();
    _windsurfSwitchSub?.cancel();
    _systemWs?.dispose();
    _scrollController.dispose();
    _textController.dispose();
    _focusNode.dispose();
    _autoHangTimer?.cancel();
    super.dispose();
  }

  /// 启动一个系统级 WS 连接，专门接收 windsurf_switch 等系统命令
  /// 用 AppConfig.defaultSessionId 接收（与 chat 用的 ws 完全分离）
  void _initSystemWs() {
    _systemWs = WsService(
      serverUrl: AppConfig.defaultServerUrl,
      sessionId: AppConfig.defaultSessionId,
      token: AppConfig.defaultToken,
    );
    _systemWs!.connect();
    _windsurfSwitchSub = _systemWs!.windsurfSwitch.listen(_onWindsurfSwitch);
  }

  /// 收到服务端推送的 windsurf_switch 事件后，调用本地 patch 服务执行切号
  Future<void> _onWindsurfSwitch(Map<String, dynamic> data) async {
    final email = data['email'] as String? ?? '';
    final reason = data['reason'] as String? ?? 'unknown';
    if (email.isEmpty) return;

    // 30 秒内同一 email 只触发一次（避免重连/重复广播）
    final now = DateTime.now();
    if (_lastSwitchEmail == email &&
        _lastSwitchAt != null &&
        now.difference(_lastSwitchAt!).inSeconds < 30) {
      return;
    }
    _lastSwitchEmail = email;
    _lastSwitchAt = now;

    // 1. 拉密码（明文）
    String password = '';
    try {
      final creds = await widget.apiService.getWindsurfCredentials(email);
      password = creds['password'] as String? ?? '';
    } catch (e) {
      debugPrint('[WindsurfSwitch] 拉密码失败: $e');
    }

    // 2. 执行 patch
    Map<String, dynamic> result;
    try {
      result = await WindsurfPatchService.performSwitch(
        email: email,
        password: password,
        reason: reason,
      );
    } catch (e) {
      result = {'success': false, 'message': '切换异常: $e'};
    }

    // 3. 弹窗 + SnackBar 通知
    if (!mounted) return;
    final ok = result['success'] == true;
    final msg = result['message'] as String? ?? '';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Windsurf 切号 [$reason]: $email\n$msg'),
      backgroundColor: ok ? Colors.green : Colors.red,
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: '详情',
        textColor: Colors.white,
        onPressed: () => _showSwitchResultDialog(email, reason, result),
      ),
    ));
    // 弹一个桌面通知（NotificationService 会处理）
    NotificationService().showMessageNotification(
      title: 'Windsurf 已切号',
      body: '现在用 $email 登录 (原因: $reason)\n密码已复制到剪贴板',
      id: 9001,
    );
  }

  void _showSwitchResultDialog(
      String email, String reason, Map<String, dynamic> result) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final logs = (result['logs'] as List?)?.cast<String>() ?? [];
        return AlertDialog(
          title: const Text('Windsurf 切号详情'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('账号: $email',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('触发原因: $reason'),
                const SizedBox(height: 8),
                Text('结果: ${result['message'] ?? ""}'),
                const SizedBox(height: 12),
                if (logs.isNotEmpty) ...[
                  const Text('执行日志:',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  Container(
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(maxHeight: 200),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        logs.join('\n'),
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭')),
          ],
        );
      },
    );
  }

  void _initLocalIpc() {
    final ipc = widget.localIpcService;
    if (ipc == null) return;
    _localIpcSub = ipc.messages.listen((data) async {
      final message = data['message'] as String? ?? '';
      if (message.isEmpty) return;

      final sessionId = (data['session_id'] as String? ?? '').trim();
      final workspace = (data['workspace'] as String? ?? '').trim();
      final workspaceName = (data['workspace_name'] as String? ?? '').trim();

      // 多工作区会话：消息携带 session_id 时自动创建/切换到对应对话区；
      // 否则维持旧行为（进当前选中会话）
      MessageProvider? provider;
      if (sessionId.isNotEmpty) {
        provider = await _ensureWorkspaceSession(
          sessionId: sessionId,
          workspace: workspace,
          workspaceName: workspaceName,
        );
      } else {
        provider = _currentProvider;
      }

      if (provider != null) {
        // 去重：检查最近消息中是否已有相同内容（云端WebSocket先到达的情况）
        final recent = provider.messages;
        final isDup = recent.isNotEmpty && recent.reversed.take(5).any(
          (m) => m.sender == 'pc' && m.content == message,
        );
        if (!isDup) {
          final msg = PushMessage(
            id: 'local_ipc_${DateTime.now().millisecondsSinceEpoch}',
            sessionId: provider.sessionId,
            content: message,
            msgType: 'text',
            sender: 'pc',
            createdAt: DateTime.now().toUtc(),
          );
          provider.addLocalMessage(msg);
        }
      }
      // 弹出窗口并聚焦
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        windowManager.show();
        windowManager.focus();
      }
    });
  }

  /// 确保工作区会话存在并切换到它，返回对应的 MessageProvider。
  /// 查找顺序：本地列表 → 服务端刷新 → 本地构造占位会话。
  Future<MessageProvider?> _ensureWorkspaceSession({
    required String sessionId,
    String workspace = '',
    String workspaceName = '',
  }) async {
    PushSession? target;
    for (final s in _sessions) {
      if (s.id == sessionId) {
        target = s;
        break;
      }
    }
    // 不在本地列表 → 从服务端拉一次（dialog.py 推送前已注册会话元数据）
    if (target == null) {
      await _loadSessions(silent: true);
      for (final s in _sessions) {
        if (s.id == sessionId) {
          target = s;
          break;
        }
      }
    }
    // 服务端也没有（离线等极端情况）→ 本地构造占位会话，进消息列表顶部
    if (target == null) {
      final name = workspaceName.isNotEmpty ? workspaceName : sessionId;
      final now = DateTime.now().toUtc().toIso8601String();
      target = PushSession(
        id: sessionId,
        name: name,
        displayName: name,
        projectName: workspace,
        createdAt: now,
        lastActive: now,
      );
      if (mounted) {
        setState(() => _sessions.insert(0, target!));
      }
    }
    if (_selectedSessionId != sessionId) {
      _selectSession(target);
    }
    return _providerCache[sessionId];
  }

  /// 「打开文件夹」：选择项目文件夹 → 以该路径创建/切换工作区对话
  Future<void> _openWorkspaceFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择项目文件夹（以此创建工作区对话）',
    );
    if (dir == null || dir.isEmpty) return;

    final sessionId = WorkspaceSession.idForPath(dir);
    final folder = WorkspaceSession.folderName(dir);
    final normPath = dir.replaceAll('\\', '/');

    // 服务端注册（自动创建会话）；失败不阻断本地切换
    try {
      await widget.apiService.updateSessionMeta(
        sessionId,
        machineName: Platform.localHostname,
        projectName: normPath,
        ideType: 'cursor',
        displayName: folder,
      );
    } catch (e) {
      debugPrint('[workspace] 注册会话失败: $e');
    }

    await _ensureWorkspaceSession(
      sessionId: sessionId,
      workspace: normPath,
      workspaceName: folder,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已打开工作区「$folder」，AI 用 --workspace 携带此目录即可对话')),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NotificationService().appInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _loadSessions(silent: true);
      _currentProvider?.reconnectWs();
    }
  }

  MessageProvider? get _currentProvider =>
      _selectedSessionId != null ? _providerCache[_selectedSessionId] : null;

  Future<void> _loadSessions({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.apiService.getSessions();
      if (mounted) {
        setState(() {
          _sessions = data.map((j) => PushSession.fromJson(j)).toList();
          _loading = false;
          // 自动选择第一个会话
          if (_selectedSessionId == null && _sessions.isNotEmpty) {
            _selectSession(_sessions.first);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (!silent) _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _selectSession(PushSession session) {
    setState(() {
      _selectedSessionId = session.id;
      _selectedSessionName = session.title;
      _textController.clear();
      _attachments.clear();
    });

    // 获取或创建 MessageProvider
    if (!_providerCache.containsKey(session.id)) {
      final wsService = WsService(
        serverUrl: AppConfig.defaultServerUrl,
        sessionId: session.id,
        token: AppConfig.defaultToken,
        apiService: widget.apiService,
      );
      final provider = MessageProvider(
        apiService: widget.apiService,
        wsService: wsService,
        sessionId: session.id,
      );
      // 挂载本地 IPC 回复回调（带会话校验：只回给等待中的那个工作区会话）
      if (widget.localIpcService != null) {
        provider.onReplyCallback = (text) {
          widget.localIpcService!.submitReply(text, sessionId: session.id);
        };
      }
      _providerCache[session.id] = provider;
      provider.loadHistory();
      provider.connectWs();
    } else {
      _providerCache[session.id]!.reconnectWs();
    }

    // 标记已读
    widget.apiService.markSessionRead(session.id).catchError((_) {});
    _focusNode.requestFocus();
  }

  Future<void> _send() async {
    final provider = _currentProvider;
    if (provider == null) return;

    final text = _textController.text.trim();
    final hasText = text.isNotEmpty;
    final hasFiles = _attachments.isNotEmpty;

    if (!hasText && !hasFiles) return;

    if (hasFiles) {
      for (int i = 0; i < _attachments.length; i++) {
        final att = _attachments[i];
        final bytes = await File(att.path).readAsBytes();
        final caption = (i == 0 && hasText) ? text : '';
        await provider.sendFile(att.name, bytes, caption: caption);
      }
    } else {
      await provider.sendReply(text);
    }

    _textController.clear();
    setState(() => _attachments.clear());
    _focusNode.requestFocus();
  }

  Future<void> _handleDesktopPaste() async {
    try {
      debugPrint('[paste] _handleDesktopPaste called');

      // Try reading image from clipboard
      Uint8List? imageBytes;
      try {
        imageBytes = await Pasteboard.image;
        debugPrint('[paste] Pasteboard.image: ${imageBytes?.length ?? 0} bytes');
      } catch (e) {
        debugPrint('[paste] Pasteboard.image error: $e');
      }

      if (imageBytes != null && imageBytes.isNotEmpty) {
        final tempDir = Directory.systemTemp;
        final tempFile = File(
          '${tempDir.path}/pasted_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await tempFile.writeAsBytes(imageBytes);
        debugPrint('[paste] Saved image to: ${tempFile.path}');
        if (mounted) {
          setState(() {
            _attachments.add(_AttachmentItem(
              name: tempFile.uri.pathSegments.last,
              path: tempFile.path,
            ));
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已粘贴图片 (${(imageBytes.length / 1024).toStringAsFixed(0)}KB)'),
              duration: const Duration(seconds: 1),
            ),
          );
        }
        return;
      }

      // Try reading files from clipboard
      List<String> files = [];
      try {
        files = await Pasteboard.files();
        debugPrint('[paste] Pasteboard.files: ${files.length} files');
      } catch (e) {
        debugPrint('[paste] Pasteboard.files error: $e');
      }

      final imgExts = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
      int added = 0;
      for (final filePath in files) {
        final ext = filePath.split('.').last.toLowerCase();
        if (imgExts.contains(ext)) {
          if (mounted) {
            setState(() {
              _attachments.add(_AttachmentItem(
                name: filePath.split(Platform.pathSeparator).last,
                path: filePath,
              ));
            });
            added++;
          }
        }
      }
      if (added > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已粘贴 $added 个图片文件'), duration: const Duration(seconds: 1)),
        );
      }
    } catch (e, stack) {
      debugPrint('Clipboard paste failed: $e\n$stack');
    }
  }

  Future<void> _pickAttachment() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    setState(() {
      for (final f in result.files) {
        if (f.path != null) {
          _attachments.add(_AttachmentItem(name: f.name, path: f.path!));
        }
      }
    });
  }

  void _removeAttachment(int index) {
    setState(() => _attachments.removeAt(index));
  }

  void _startAutoHang() {
    setState(() => _autoHang = true);
    _sendKeepAlive();
    _autoHangTimer = Timer.periodic(const Duration(hours: 2), (_) {
      _sendKeepAlive();
    });
  }

  void _stopAutoHang() {
    _autoHangTimer?.cancel();
    _autoHangTimer = null;
    setState(() => _autoHang = false);
  }

  void _sendKeepAlive() {
    _currentProvider?.sendCommand('reply',
      params: '{"text": "keepalive"}',
      displayText: '🔄 自动挂机心跳',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: [
          // ===== 左侧：会话列表 =====
          SizedBox(
            width: 280,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  right: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.3),
                  ),
                ),
              ),
              child: Column(
                children: [
                  _buildSidebarHeader(theme),
                  Expanded(child: _buildSessionList(theme)),
                ],
              ),
            ),
          ),
          // ===== 右侧：聊天窗口 =====
          Expanded(
            child: _selectedSessionId != null
                ? _buildChatPanel(theme)
                : _buildEmptyChat(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt, color: theme.colorScheme.primary, size: 24),
          const SizedBox(width: 8),
          Text(
            'IDE Claw',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined, size: 20),
            onPressed: _openWorkspaceFolder,
            tooltip: '打开文件夹（创建工作区对话）',
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loadSessions,
            tooltip: '刷新会话列表',
          ),
          IconButton(
            icon: const Icon(Icons.info_outline, size: 20),
            tooltip: '关于',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AboutScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionList(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: Colors.red[300]),
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Colors.red[300], fontSize: 12)),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _loadSessions, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            const Text('暂无会话', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _sessions.length,
      itemBuilder: (_, i) => _buildSessionTile(_sessions[i], theme),
    );
  }

  Widget _buildSessionTile(PushSession session, ThemeData theme) {
    final isSelected = session.id == _selectedSessionId;
    String timeStr = '';
    try {
      final timeSource = session.lastMsgTime.isNotEmpty
          ? session.lastMsgTime
          : session.lastActive;
      final dt = DateTime.parse(timeSource).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) {
        timeStr = '刚刚';
      } else if (diff.inHours < 1) {
        timeStr = '${diff.inMinutes}分钟前';
      } else if (diff.inDays < 1) {
        timeStr = '${diff.inHours}小时前';
      } else {
        timeStr = DateFormat('MM/dd HH:mm').format(dt);
      }
    } catch (_) {
      timeStr = session.lastActive;
    }

    IconData iconData;
    Color iconColor;
    switch (session.iconType) {
      case IconType.windsurf:
        iconData = Icons.sailing;
        iconColor = Colors.teal;
        break;
      case IconType.cursor:
        iconData = Icons.mouse;
        iconColor = Colors.purple;
        break;
      case IconType.vscode:
        iconData = Icons.code;
        iconColor = Colors.blue;
        break;
      case IconType.generic:
        iconData = Icons.computer;
        iconColor = theme.colorScheme.primary;
        break;
    }

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: () => _selectSession(session),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: iconColor.withValues(alpha: 0.15),
                    child: Icon(iconData, color: iconColor, size: 20),
                  ),
                  if (session.unreadCount > 0)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        constraints:
                            const BoxConstraints(minWidth: 16, minHeight: 16),
                        child: Text(
                          session.unreadCount > 99
                              ? '99+'
                              : '${session.unreadCount}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            session.title,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: theme.colorScheme.onSurface,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          timeStr,
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey[500]),
                        ),
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: PopupMenuButton<String>(
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            icon: const Icon(Icons.more_vert, size: 16),
                            tooltip: '更多',
                            onSelected: (v) => _onSessionMenu(session, v),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'rename', child: Row(
                                children: [Icon(Icons.edit_outlined, size: 18),
                                  SizedBox(width: 8), Text('重命名')],
                              )),
                              PopupMenuItem(value: 'delete', child: Row(
                                children: [Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                  SizedBox(width: 8),
                                  Text('删除对话', style: TextStyle(color: Colors.red))],
                              )),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      session.projectName.isNotEmpty
                          ? '工作区: ${session.projectName}'
                          : '工作区: 未设置',
                      style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      session.lastMessage.isNotEmpty
                          ? session.lastMessage
                          : '暂无消息',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey[500]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _filePickerOpen = false;
  int _lastTextLen = 0;

  void _onTextChangedForAtMention() {
    final text = _textController.text;
    final selection = _textController.selection;
    final isInsert = text.length > _lastTextLen;
    _lastTextLen = text.length;

    if (_filePickerOpen) return;
    if (_selectedSessionId == null) return;
    if (!selection.isValid || !selection.isCollapsed || !isInsert) return;

    final cursor = selection.start;
    if (cursor == 0 || cursor > text.length) return;
    if (text[cursor - 1] != '@') return;
    if (cursor >= 2) {
      final prev = text[cursor - 2];
      if (prev != ' ' && prev != '\n' && prev != '\t') return;
    }
    _openFilePicker(cursor);
  }

  Future<void> _openFilePicker(int atPos) async {
    final sid = _selectedSessionId;
    if (sid == null) return;
    _filePickerOpen = true;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 560,
          child: WorkspaceFilePicker(
            apiService: widget.apiService,
            sessionId: sid,
          ),
        ),
      ),
    );
    _filePickerOpen = false;
    if (picked == null || picked.isEmpty) return;
    if (!mounted) return;

    final text = _textController.text;
    final insertion = '@file:$picked ';
    if (atPos < 1 || atPos > text.length || text[atPos - 1] != '@') {
      final cur = _textController.selection.baseOffset.clamp(0, text.length);
      final newText = text.substring(0, cur) + insertion + text.substring(cur);
      _textController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: cur + insertion.length),
      );
      return;
    }
    final newText = text.substring(0, atPos - 1) + insertion + text.substring(atPos);
    _textController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: (atPos - 1) + insertion.length),
    );
  }

  Future<void> _onSessionMenu(PushSession session, String action) async {
    if (action == 'rename') {
      await _renameDialog(session);
    } else if (action == 'delete') {
      await _deleteDialog(session);
    }
  }

  Future<void> _renameDialog(PushSession session) async {
    final controller = TextEditingController(text: session.title);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名对话'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '输入新的对话名称',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    try {
      await widget.apiService.renameSession(session.id, newName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已重命名为「$newName」')),
        );
        _loadSessions(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重命名失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteDialog(PushSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('删除「${session.title}」及其所有聊天记录？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.apiService.deleteSession(session.id);
      if (mounted) {
        // 销毁该会话的 provider（停掉轮询/WS），否则后台轮询会把已删除的会话在服务端复活
        _providerCache.remove(session.id)?.dispose();
        // 如果删的是当前选中的，清空选中
        if (_selectedSessionId == session.id) {
          setState(() {
            _selectedSessionId = null;
            _selectedSessionName = '';
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除「${session.title}」')),
        );
        _loadSessions(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildEmptyChat(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            '选择一个会话开始聊天',
            style: TextStyle(fontSize: 16, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildChatPanel(ThemeData theme) {
    final provider = _currentProvider;
    if (provider == null) return _buildEmptyChat(theme);

    return ChangeNotifierProvider.value(
      value: provider,
      child: Column(
        children: [
          _buildChatHeader(theme),
          Expanded(child: _buildMessageList(theme)),
          if (_autoHang) _buildAutoHangBanner(theme),
          const Divider(height: 1),
          if (_attachments.isNotEmpty) _buildAttachmentPreview(theme),
          _buildInputBar(theme),
        ],
      ),
    );
  }

  Widget _buildChatHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selectedSessionName,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                Consumer<MessageProvider>(
                  builder: (_, p, __) => Text(
                    p.connectionMode,
                    style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.6)),
                  ),
                ),
              ],
            ),
          ),
          Consumer<MessageProvider>(
            builder: (_, p, __) => _buildStatusIndicator(p.wsStatus, theme),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.add, size: 20),
            onSelected: (value) {
              if (value == 'auto_hang') {
                if (_autoHang) {
                  _stopAutoHang();
                } else {
                  _startAutoHang();
                }
              } else if (value == 'refresh') {
                _currentProvider?.loadHistory();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'auto_hang',
                child: Row(
                  children: [
                    Icon(_autoHang ? Icons.stop_circle_outlined : Icons.nights_stay_outlined, size: 20),
                    const SizedBox(width: 8),
                    Text(_autoHang ? '取消挂机' : '自动挂机'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'refresh',
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 20),
                    SizedBox(width: 8),
                    Text('刷新消息'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIndicator(WsStatus status, ThemeData theme) {
    Color color;
    String tooltip;
    switch (status) {
      case WsStatus.connected:
        color = Colors.green;
        tooltip = '已连接';
      case WsStatus.connecting:
        color = Colors.orange;
        tooltip = '连接中...';
      case WsStatus.disconnected:
        color = Colors.grey;
        tooltip = '已断开';
      case WsStatus.error:
        color = Colors.red;
        tooltip = '连接错误';
      case WsStatus.failed:
        color = Colors.red;
        tooltip = '连接失败';
    }
    return Tooltip(
      message: tooltip,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }

  Widget _buildAutoHangBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.amber.withValues(alpha: 0.15),
      child: Row(
        children: [
          const Icon(Icons.nights_stay, size: 18, color: Colors.amber),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('挂机中 · 每2小时自动心跳',
                style: TextStyle(fontSize: 13, color: Colors.amber)),
          ),
          TextButton(
            onPressed: _stopAutoHang,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: Size.zero,
            ),
            child: const Text('取消挂机', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(ThemeData theme) {
    return Consumer<MessageProvider>(
      builder: (_, provider, __) {
        if (provider.loading && provider.messages.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (provider.error != null && provider.messages.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                const SizedBox(height: 8),
                Text(provider.error!,
                    style: TextStyle(color: Colors.red[300])),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => provider.loadHistory(),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        if (provider.messages.isEmpty) {
          return const Center(
            child: Text('暂无消息\n等待推送...',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          );
        }
        final msgs = provider.messages;
        final itemCount = msgs.length + (provider.pcTyping ? 1 : 0);
        return SelectionArea(
          child: ListView.builder(
            reverse: true,
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: itemCount,
            itemBuilder: (_, i) {
              if (provider.pcTyping && i == 0) {
                return _buildTypingIndicator(theme);
              }
              final msgIndex = provider.pcTyping ? i - 1 : i;
              final reverseIndex = msgs.length - 1 - msgIndex;
              return _buildMessageBubble(msgs[reverseIndex], theme);
            },
          ),
        );
      },
    );
  }

  Widget _buildMessageBubble(PushMessage msg, ThemeData theme) {
    final isFromPC = msg.sender == 'pc';
    final timeStr = DateFormat('HH:mm').format(msg.createdAt.toLocal());
    final rawText = msg.caption.isNotEmpty ? msg.caption : msg.content;
    final displayText = rawText.replaceAll(r'\n', '\n');

    return Align(
      alignment: isFromPC ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: const BoxConstraints(maxWidth: 600),
        decoration: BoxDecoration(
          color: isFromPC
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (msg.isStatus)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                  Text('状态更新',
                      style: TextStyle(
                          fontSize: 11, color: theme.colorScheme.primary)),
                ],
              ),
            if (msg.isScreenshot)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.photo_camera,
                      size: 14, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                  Text('截图',
                      style: TextStyle(
                          fontSize: 11, color: theme.colorScheme.primary)),
                ],
              ),
            if (displayText.isNotEmpty && !msg.isFile)
              MarkdownBody(
                data: displayText,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                      fontSize: 14, color: theme.colorScheme.onSurface),
                  code: TextStyle(
                    fontSize: 12,
                    backgroundColor: theme.colorScheme.surfaceContainerLow,
                  ),
                ),
              ),
            if (msg.isFile && _isImageFile(msg.fileName)) ...[
              if (msg.caption.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child:
                      Text(msg.caption.replaceAll(r'\n', '\n'), style: const TextStyle(fontSize: 14)),
                ),
              _buildImageThumbnail(msg),
            ] else if (msg.isFile) ...[
              if (msg.caption.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child:
                      Text(msg.caption.replaceAll(r'\n', '\n'), style: const TextStyle(fontSize: 14)),
                ),
              _buildFileAttachment(msg, theme),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isFromPC) _buildSendStatusIcon(msg, theme),
                Text(
                  timeStr,
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSendStatusIcon(PushMessage msg, ThemeData theme) {
    switch (msg.sendStatus) {
      case SendStatus.sending:
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
          ),
        );
      case SendStatus.sent:
        return const Padding(
          padding: EdgeInsets.only(right: 4),
          child: Icon(Icons.check_circle, size: 12, color: Colors.green),
        );
      case SendStatus.failed:
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: GestureDetector(
            onTap: () => _currentProvider?.retrySend(msg),
            child: const Icon(Icons.error, size: 12, color: Colors.red),
          ),
        );
      case SendStatus.none:
        return const SizedBox.shrink();
    }
  }

  bool _isImageFile(String name) {
    final ext = name.toLowerCase().split('.').last;
    return ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic'].contains(ext);
  }

  bool _isMarkdownFile(String name) {
    final ext = name.toLowerCase().split('.').last;
    return ext == 'md' || ext == 'markdown';
  }

  void _openMarkdownViewer(PushMessage msg, {String? localPath}) {
    final url = localPath == null
        ? widget.apiService.getFileDownloadUrl(msg.fileId, msg.sessionId)
        : null;
    final headers = localPath == null
        ? {'Authorization': 'Bearer ${widget.apiService.token}'}
        : null;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MarkdownViewerScreen(
          title: msg.fileName.isNotEmpty ? msg.fileName : '文档',
          url: url,
          headers: headers,
          localPath: localPath,
        ),
      ),
    );
  }

  Widget _buildImageThumbnail(PushMessage msg) {
    final url =
        widget.apiService.getFileDownloadUrl(msg.fileId, msg.sessionId);
    final heroTag = 'img_${msg.id}';
    final authHeaders = {'Authorization': 'Bearer ${widget.apiService.token}'};
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImagePreviewScreen(
              imageUrl: url,
              heroTag: heroTag,
              headers: authHeaders,
            ),
          ),
        );
      },
      child: Hero(
        tag: heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300, maxHeight: 300),
            child: CachedNetworkImage(
              imageUrl: url,
              httpHeaders: authHeaders,
              fit: BoxFit.cover,
              placeholder: (context, _) => Container(
                width: 200,
                height: 120,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              errorWidget: (context, _, __) => Container(
                width: 200,
                height: 120,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: const Center(
                    child: Icon(Icons.broken_image, size: 32)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileAttachment(PushMessage msg, ThemeData theme) {
    return ListenableBuilder(
      listenable: DownloadService(),
      builder: (context, _) {
        final task = DownloadService().getTask(msg.fileId);
        final state = task?.state ?? DownloadState.idle;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                msg.hasImage ? Icons.image
                    : _isMarkdownFile(msg.fileName) ? Icons.article
                    : Icons.insert_drive_file,
                size: 28,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      msg.fileName.isNotEmpty ? msg.fileName : '附件',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                    _buildDesktopDownloadStatus(state, task, theme),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildDesktopActionButton(state, task, msg, theme),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesktopDownloadStatus(DownloadState state, DownloadTask? task, ThemeData theme) {
    switch (state) {
      case DownloadState.idle:
        return Text('点击下载', style: TextStyle(fontSize: 10, color: theme.colorScheme.primary));
      case DownloadState.downloading:
        return Text(task?.speedText ?? '下载中...', style: TextStyle(fontSize: 10, color: theme.colorScheme.primary));
      case DownloadState.done:
        return Text('点击打开', style: TextStyle(fontSize: 10, color: Colors.green[700]));
      case DownloadState.error:
        return Text('下载失败，点击重试', style: TextStyle(fontSize: 10, color: Colors.red[400]));
    }
  }

  Widget _buildDesktopActionButton(DownloadState state, DownloadTask? task, PushMessage msg, ThemeData theme) {
    Widget icon;
    VoidCallback? onTap;

    switch (state) {
      case DownloadState.idle:
        icon = Icon(Icons.download, size: 22, color: theme.colorScheme.primary);
        onTap = () => _startDownload(msg);
        break;
      case DownloadState.downloading:
        icon = SizedBox(
          width: 22, height: 22,
          child: CircularProgressIndicator(
            value: task?.progress, strokeWidth: 2.5,
            color: theme.colorScheme.primary,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        );
        onTap = null;
        break;
      case DownloadState.done:
        icon = Icon(Icons.open_in_new, size: 20, color: Colors.green[700]);
        onTap = () {
          if (task?.savedPath != null) {
            if (_isMarkdownFile(msg.fileName)) {
              _openMarkdownViewer(msg, localPath: task!.savedPath!);
            } else {
              OpenFilex.open(task!.savedPath!);
            }
          }
        };
        break;
      case DownloadState.error:
        icon = Icon(Icons.refresh, size: 20, color: Colors.red[400]);
        onTap = () => _startDownload(msg);
        break;
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: icon,
      ),
    );
  }

  void _startDownload(PushMessage msg) {
    if (msg.fileId.isEmpty) return;
    final fName = msg.fileName.isNotEmpty ? msg.fileName : '附件';
    final url =
        widget.apiService.getFileDownloadUrl(msg.fileId, msg.sessionId);

    DownloadService().startDownload(
      fileId: msg.fileId,
      fileName: fName,
      sessionId: msg.sessionId,
      sessionName: _selectedSessionName,
      downloadUrl: url,
      autoRename: false,
    );
  }

  Widget _buildTypingIndicator(ThemeData theme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            3,
            (i) => Padding(
              padding: EdgeInsets.only(left: i > 0 ? 4 : 0),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.3, end: 1.0),
                duration: Duration(milliseconds: 600 + i * 200),
                curve: Curves.easeInOut,
                builder: (_, value, child) =>
                    Opacity(opacity: value, child: child),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showImageFullScreen(String filePath) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Colors.white),
            elevation: 0,
          ),
          extendBodyBehindAppBar: true,
          body: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(File(filePath), fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentPreview(ThemeData theme) {
    final imgExts = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.attach_file, size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 4),
              Text('${_attachments.length} 个附件',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.primary)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _attachments.clear()),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                child: const Text('清除', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _attachments.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final att = _attachments[index];
                final ext = att.name.split('.').last.toLowerCase();
                final isImage = imgExts.contains(ext);
                return Stack(
                  children: [
                    GestureDetector(
                      onTap: isImage ? () => _showImageFullScreen(att.path) : null,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: isImage
                            ? Image.file(
                                File(att.path),
                                width: 72,
                                height: 72,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _buildFileIcon(att.name, theme),
                              )
                            : _buildFileIcon(att.name, theme),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: () => _removeAttachment(index),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(2),
                          child: const Icon(Icons.close, size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileIcon(String name, ThemeData theme) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.insert_drive_file, size: 28, color: theme.colorScheme.primary),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              name,
              style: TextStyle(fontSize: 9, color: theme.colorScheme.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _pickAttachment,
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '添加附件',
          ),
          Expanded(
            child: TextField(
              controller: _textController,
              focusNode: _focusNode,
              decoration: InputDecoration(
                hintText: '输入消息... (Enter发送, Shift+Enter换行)',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                isDense: true,
              ),
              textInputAction: TextInputAction.newline,
              onSubmitted: (_) => _send(),
              minLines: 1,
              maxLines: 5,
              contentInsertionConfiguration: ContentInsertionConfiguration(
                allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
                onContentInserted: (KeyboardInsertedContent content) async {
                  if (content.data != null) {
                    final tempDir = Directory.systemTemp;
                    final ext = content.mimeType.split('/').last;
                    final tempFile = File('${tempDir.path}/pasted_${DateTime.now().millisecondsSinceEpoch}.$ext');
                    await tempFile.writeAsBytes(content.data!);
                    setState(() {
                      _attachments.add(_AttachmentItem(name: tempFile.uri.pathSegments.last, path: tempFile.path));
                    });
                  }
                },
              ),
            ),
          ),
          IconButton(
            onPressed: _handleDesktopPaste,
            icon: const Icon(Icons.content_paste),
            tooltip: '粘贴剪贴板图片',
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            onPressed: _send,
            icon: const Icon(Icons.send),
            tooltip: '发送',
          ),
        ],
      ),
    );
  }
}

class _AttachmentItem {
  final String name;
  final String path;
  _AttachmentItem({required this.name, required this.path});
}
