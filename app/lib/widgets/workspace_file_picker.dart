import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';

/// 工作区文件搜索弹窗。
/// 用法：
///   final picked = await showModalBottomSheet<String>(
///     context: context,
///     isScrollControlled: true,
///     builder: (_) => WorkspaceFilePicker(
///       apiService: api,
///       sessionId: sessionId,
///       initialQuery: 'main',
///     ),
///   );
/// 返回选中文件的相对路径（如 'lib/main.dart'），或 null 表示取消。
class WorkspaceFilePicker extends StatefulWidget {
  final ApiService apiService;
  final String sessionId;
  final String initialQuery;

  const WorkspaceFilePicker({
    super.key,
    required this.apiService,
    required this.sessionId,
    this.initialQuery = '',
  });

  @override
  State<WorkspaceFilePicker> createState() => _WorkspaceFilePickerState();
}

class _WorkspaceFilePickerState extends State<WorkspaceFilePicker> {
  late final TextEditingController _searchController;
  List<Map<String, dynamic>> _files = [];
  bool _loading = false;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery);
    _searchController.addListener(_onSearchChanged);
    _search(widget.initialQuery);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _search(_searchController.text.trim());
    });
  }

  Future<void> _search(String q) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await widget.apiService.getWorkspaceFiles(widget.sessionId, q);
      if (!mounted) return;
      setState(() {
        _files = files;
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

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final isDesktop = mq.size.width >= 800;
    final maxHeight = isDesktop ? 500.0 : mq.size.height * 0.7;

    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // header
            Row(
              children: [
                const Icon(Icons.folder_open, size: 20),
                const SizedBox(width: 8),
                const Text(
                  '引用工作区文件',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '取消',
                ),
              ],
            ),
            // search box
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '输入文件名搜索...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            // results
            Flexible(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _files.isEmpty) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(32),
        child: CircularProgressIndicator(),
      ));
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Colors.red[300], size: 32),
            const SizedBox(height: 8),
            Text('加载失败: $_error',
                style: TextStyle(color: Colors.red[300]),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => _search(_searchController.text.trim()),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 32, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isEmpty
                  ? '该会话没有上报工作区文件\n（请让 AI 通过 dialog.py 推送一次消息）'
                  : '未找到匹配「${_searchController.text}」的文件',
              style: TextStyle(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _files.length,
      itemBuilder: (_, i) {
        final f = _files[i];
        final path = f['path'] as String? ?? '';
        final size = (f['size'] as num?)?.toInt() ?? 0;
        final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
        return ListTile(
          dense: true,
          leading: Icon(_iconFor(ext), size: 20, color: _colorFor(ext)),
          title: Text(path,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_humanSize(size),
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          onTap: () => Navigator.of(context).pop(path),
        );
      },
    );
  }

  IconData _iconFor(String ext) {
    switch (ext) {
      case 'dart': return Icons.flutter_dash;
      case 'py': return Icons.code;
      case 'go': return Icons.code;
      case 'js': case 'ts': case 'jsx': case 'tsx': return Icons.javascript;
      case 'md': return Icons.description;
      case 'json': case 'yaml': case 'yml': case 'toml': return Icons.settings;
      case 'png': case 'jpg': case 'jpeg': case 'gif': case 'webp': case 'svg':
        return Icons.image;
      case 'html': case 'htm': return Icons.html;
      case 'css': return Icons.css;
      case 'sh': case 'bat': case 'ps1': return Icons.terminal;
      default: return Icons.insert_drive_file_outlined;
    }
  }

  Color _colorFor(String ext) {
    switch (ext) {
      case 'dart': return Colors.blue;
      case 'py': return Colors.amber;
      case 'go': return Colors.cyan;
      case 'js': case 'jsx': return Colors.yellow[700]!;
      case 'ts': case 'tsx': return Colors.blue[700]!;
      case 'md': return Colors.grey[700]!;
      case 'json': case 'yaml': case 'yml': case 'toml': return Colors.deepOrange;
      case 'png': case 'jpg': case 'jpeg': case 'gif': case 'webp': case 'svg':
        return Colors.green;
      default: return Colors.grey[600]!;
    }
  }
}
