import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/session.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../config/app_config.dart';
import 'about_screen.dart';
import 'chat_screen.dart';
import 'windsurf_accounts_screen.dart';

class SessionListScreen extends StatefulWidget {
  final ApiService apiService;

  const SessionListScreen({super.key, required this.apiService});

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> with WidgetsBindingObserver {
  List<PushSession> _sessions = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSessions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NotificationService().appInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _loadSessions(silent: true);
    }
  }

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

  void _openChat(PushSession session) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          apiService: widget.apiService,
          sessionId: session.id,
          sessionName: session.title,
        ),
      ),
    );
    // 返回时静默刷新（不显示loading转圈）
    _loadSessions(silent: true);
  }

  void _openDefaultChat() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          apiService: widget.apiService,
          sessionId: AppConfig.defaultSessionId,
          sessionName: 'Default Session',
        ),
      ),
    );
    _loadSessions(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('IDEclaw'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadSessions(),
            tooltip: '刷新',
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '关于',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AboutScreen()),
            ),
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
            Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            const Text('暂无会话', style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 8),
            const Text('点击右下角开始默认会话', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadSessions,
      child: ListView.builder(
        itemCount: _sessions.length,
        itemBuilder: (_, i) => _buildSessionTile(_sessions[i]),
      ),
    );
  }

  Widget _buildSessionTile(PushSession session) {
    String timeStr = '';
    try {
      final timeSource = session.lastMsgTime.isNotEmpty ? session.lastMsgTime : session.lastActive;
      final dt = DateTime.parse(timeSource);
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

    // IDE图标
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
        iconColor = Theme.of(context).colorScheme.primary;
        break;
    }

    // 副标题：机器名·IDE / 工作区 / 最新消息
    final metaLine = session.subtitle;
    final workspaceLine = session.projectName.isNotEmpty
        ? '工作区: ${session.projectName}'
        : '工作区: 未设置';
    final previewLine = session.lastMessage.isNotEmpty ? session.lastMessage : '暂无消息';

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: iconColor.withOpacity(0.15),
            child: Icon(iconData, color: iconColor),
          ),
          if (session.unreadCount > 0)
            Positioned(
              right: 0, top: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(8),
                ),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                child: Text(
                  session.unreadCount > 99 ? '99+' : '${session.unreadCount}',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
      title: Text(session.title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (metaLine.isNotEmpty)
            Text(metaLine, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          Text(workspaceLine,
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          Text(previewLine,
              style: const TextStyle(fontSize: 12),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(timeStr, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          SizedBox(
            height: 28,
            width: 28,
            child: PopupMenuButton<String>(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_vert, size: 18),
              tooltip: '更多',
              onSelected: (v) => _onSessionMenu(session, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Row(
                  children: [Icon(Icons.edit_outlined, size: 18), SizedBox(width: 8), Text('重命名')],
                )),
                PopupMenuItem(value: 'delete', child: Row(
                  children: [Icon(Icons.delete_outline, size: 18, color: Colors.red),
                    SizedBox(width: 8), Text('删除对话', style: TextStyle(color: Colors.red))],
                )),
              ],
            ),
          ),
        ],
      ),
      isThreeLine: true,
      onTap: () => _openChat(session),
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
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入新的对话名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
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
          SnackBar(content: Text('已重命名为「$newName」'), duration: const Duration(seconds: 2)),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除「${session.title}」'), duration: const Duration(seconds: 2)),
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
}
