import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// 服务端 /api/version 返回的数据
class RemoteVersion {
  final String latestVersion;
  final int latestBuild;
  final String apkUrl;
  final int apkSize;
  final String? apkSha256;
  final String? releaseDate;
  final String? changelog;
  final int? minSupportedBuild;

  RemoteVersion({
    required this.latestVersion,
    required this.latestBuild,
    required this.apkUrl,
    required this.apkSize,
    this.apkSha256,
    this.releaseDate,
    this.changelog,
    this.minSupportedBuild,
  });

  factory RemoteVersion.fromJson(Map<String, dynamic> j) => RemoteVersion(
        latestVersion: (j['latest_version'] as String?) ?? '',
        latestBuild: (j['latest_build'] as num?)?.toInt() ?? 0,
        apkUrl: (j['apk_url'] as String?) ?? '',
        apkSize: (j['apk_size'] as num?)?.toInt() ?? 0,
        apkSha256: j['apk_sha256'] as String?,
        releaseDate: j['release_date'] as String?,
        changelog: j['changelog'] as String?,
        minSupportedBuild: (j['min_supported_build'] as num?)?.toInt(),
      );
}

/// 当前下载阶段
enum UpdateStage {
  idle,
  checking,
  upToDate,
  available, // 发现新版本，未下载
  downloading,
  ready, // APK 已下载，等待用户点击安装
  installing,
  error,
}

class UpdateProgress {
  final UpdateStage stage;
  final double progress; // 0.0~1.0，仅 downloading 阶段有意义
  final RemoteVersion? remote;
  final String? localApkPath;
  final String? errorMessage;

  const UpdateProgress({
    required this.stage,
    this.progress = 0,
    this.remote,
    this.localApkPath,
    this.errorMessage,
  });
}

/// 自动更新服务
///
/// - 每 24 小时自动调用一次 /api/version
/// - 如果发现新版本（remote.latestBuild > 当前 build），自动后台下载 APK
/// - 下载完成后通过 [progressStream] 通知 UI，UI 弹窗让用户点击「立即安装」
/// - 用户确认后调用 [installDownloaded] 触发系统 PackageInstaller
class UpdateService {
  static final UpdateService _instance = UpdateService._internal();
  factory UpdateService() => _instance;
  UpdateService._internal();

  static const String _prefLastCheckMs = 'update_last_check_ms';
  static const String _prefLastSeenBuild = 'update_last_seen_build';
  static const Duration checkInterval = Duration(hours: 24);
  static const String _apkSubdir = 'updates';
  static const String _apkFileName = 'ide-claw-latest.apk';

  // 桌面端（Windows）使用的发布包名和解压目录名
  static const String _desktopZipFileName = 'ide-claw-windows.zip';
  static const String _desktopExtractedDirName = 'extracted';

  final _controller = StreamController<UpdateProgress>.broadcast();
  Stream<UpdateProgress> get progressStream => _controller.stream;

  Timer? _periodicTimer;
  bool _busy = false;
  UpdateProgress _last = const UpdateProgress(stage: UpdateStage.idle);
  UpdateProgress get lastProgress => _last;

  void _emit(UpdateProgress p) {
    _last = p;
    _controller.add(p);
  }

  /// App 启动时调用：每次冷启动强制检查一次（不受 24h 节流约束），并启动定时器。
  ///
  /// 每次启动都拉一下 /api/version 是为了避免「装上时恰好是最新 → 标记 last_check
  /// → 之后 24h 内即使发布了新版本也不会重新检查」的尴尬。
  /// 没新版本时只是一次轻量 GET，对体验和流量都可接受。
  Future<void> startBackgroundChecks() async {
    // 仅 Android (APK) 和 Windows (ZIP) 支持自动更新，其他平台（iOS/Mac/Linux）暂不启用
    if (!Platform.isAndroid && !Platform.isWindows) return;

    // 启动时强制跑一次（不走 24h 节流），保证每次开 app 都能拿到最新版本
    unawaited(_runCheckOnce(force: true, autoDownload: true));

    // 之后每 6 小时跑一次（走 24h 节流），用于 app 长期驻留前台时拉新版本
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(const Duration(hours: 6), (_) {
      unawaited(_checkAndDownloadIfDue());
    });
  }

  void dispose() {
    _periodicTimer?.cancel();
    _controller.close();
  }

  Future<bool> _isCheckDue() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_prefLastCheckMs) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    return (now - last) >= checkInterval.inMilliseconds;
  }

  Future<void> _markChecked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefLastCheckMs, DateTime.now().millisecondsSinceEpoch);
  }

  /// 强制立即检查（无视 24h 节流）。返回是否发现新版本。
  Future<bool> checkNow({bool autoDownload = true}) async {
    return _runCheckOnce(force: true, autoDownload: autoDownload);
  }

  Future<void> _checkAndDownloadIfDue() async {
    if (!await _isCheckDue()) return;
    await _runCheckOnce(force: false, autoDownload: true);
  }

  Future<bool> _runCheckOnce({required bool force, required bool autoDownload}) async {
    if (_busy) return false;
    _busy = true;
    try {
      _emit(const UpdateProgress(stage: UpdateStage.checking));

      final remote = await _fetchRemoteVersion().timeout(const Duration(seconds: 15));
      await _markChecked();

      final pkg = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(pkg.buildNumber) ?? 0;
      debugPrint('[UpdateService] current=${pkg.version}+${pkg.buildNumber} '
          'remote=${remote.latestVersion}+${remote.latestBuild}');

      if (remote.latestBuild <= currentBuild) {
        _emit(UpdateProgress(stage: UpdateStage.upToDate, remote: remote));
        return false;
      }

      // 已经下载过同版本？直接进入 ready
      final cachedApk = await _existingApkFor(remote);
      if (cachedApk != null) {
        _emit(UpdateProgress(
          stage: UpdateStage.ready,
          remote: remote,
          localApkPath: cachedApk,
        ));
        return true;
      }

      _emit(UpdateProgress(stage: UpdateStage.available, remote: remote));
      if (autoDownload) {
        final path = await _downloadApk(remote);
        if (path != null) {
          _emit(UpdateProgress(
            stage: UpdateStage.ready,
            remote: remote,
            localApkPath: path,
          ));
        }
      }
      return true;
    } catch (e, stack) {
      debugPrint('[UpdateService] error: $e\n$stack');
      _emit(UpdateProgress(
        stage: UpdateStage.error,
        errorMessage: e.toString(),
      ));
      return false;
    } finally {
      _busy = false;
    }
  }

  Future<RemoteVersion> _fetchRemoteVersion() async {
    final url = Uri.parse('${AppConfig.defaultServerUrl}/api/version');
    final resp = await http.get(url);
    if (resp.statusCode != 200) {
      throw HttpException('GET /api/version status=${resp.statusCode}');
    }
    final body = utf8.decode(resp.bodyBytes);
    final j = json.decode(body) as Map<String, dynamic>;
    return RemoteVersion.fromJson(j);
  }

  Future<Directory> _apkDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_apkSubdir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 检查指定版本的资产是否已经在本地缓存
  ///
  /// - Android：返回已下载的 APK 路径（按 build 号 + 大小校验）
  /// - Windows：返回已解压的目录路径（校验 ide_claw.exe 是否存在 + build 号匹配）
  Future<String?> _existingApkFor(RemoteVersion remote) async {
    final dir = await _apkDir();
    final prefs = await SharedPreferences.getInstance();
    final lastSeen = prefs.getInt(_prefLastSeenBuild) ?? 0;
    if (lastSeen != remote.latestBuild) return null;

    if (Platform.isWindows) {
      final extractedDir = Directory('${dir.path}/$_desktopExtractedDirName');
      if (!await extractedDir.exists()) return null;
      final exe = File('${extractedDir.path}/ide_claw.exe');
      if (!await exe.exists()) return null;
      return extractedDir.path;
    }

    // Android
    final f = File('${dir.path}/$_apkFileName');
    if (!await f.exists()) return null;
    final size = await f.length();
    if (remote.apkSize > 0 && size != remote.apkSize) return null;
    return f.path;
  }

  /// 下载资产到本地。
  ///
  /// - Android：下载 APK，返回 APK 文件路径
  /// - Windows：下载 zip 并解压，返回解压后的目录路径（installDownloaded 会用这个
  ///   目录作为 xcopy 源，替换当前安装目录）
  Future<String?> _downloadApk(RemoteVersion remote) async {
    final dir = await _apkDir();
    final isWin = Platform.isWindows;
    final fileName = isWin ? _desktopZipFileName : _apkFileName;
    final tmpFile = File('${dir.path}/$fileName.part');
    final finalFile = File('${dir.path}/$fileName');
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }

    _emit(UpdateProgress(stage: UpdateStage.downloading, progress: 0, remote: remote));

    // Windows 下 /api/version 里没有 zip_url，用同服务器的固定路径
    final assetUrl = isWin
        ? '${AppConfig.defaultServerUrl}/dl/$_desktopZipFileName'
        : remote.apkUrl;

    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(assetUrl));
      final streamed = await client.send(req).timeout(const Duration(seconds: 30));
      if (streamed.statusCode != 200) {
        throw HttpException('Download failed: HTTP ${streamed.statusCode}');
      }
      // 桌面 zip 没有权威 size（/api/version 只报 apk_size），用 content-length 兜底
      final total = streamed.contentLength ?? (isWin ? 0 : remote.apkSize);
      final sink = tmpFile.openWrite();
      int received = 0;
      int lastEmitMs = 0;

      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastEmitMs > 250) {
            lastEmitMs = now;
            _emit(UpdateProgress(
              stage: UpdateStage.downloading,
              progress: received / total,
              remote: remote,
            ));
          }
        }
      }
      await sink.flush();
      await sink.close();

      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await tmpFile.rename(finalFile.path);

      // 记下版本号，下次启动直接进入 ready
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefLastSeenBuild, remote.latestBuild);

      if (isWin) {
        // 立刻解压，UI 拿到的是解压后的目录路径
        final extractedDir = await _extractZip(finalFile, dir);
        return extractedDir.path;
      }
      return finalFile.path;
    } finally {
      client.close();
    }
  }

  /// 把桌面端 zip 解压到 updates/extracted/ 目录。
  /// 如果目录已存在会先清空，避免残留旧文件。
  Future<Directory> _extractZip(File zipFile, Directory parentDir) async {
    final extractedDir = Directory('${parentDir.path}/$_desktopExtractedDirName');
    if (await extractedDir.exists()) {
      await extractedDir.delete(recursive: true);
    }
    await extractedDir.create(recursive: true);

    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive) {
      final outPath = '${extractedDir.path}/${entry.name}';
      if (entry.isFile) {
        final f = File(outPath);
        await f.create(recursive: true);
        await f.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    return extractedDir;
  }

  /// 用户点击「立即安装」时调用。
  ///
  /// - Android：触发系统 PackageInstaller (OpenFilex)
  /// - Windows：写一个 helper bat 到 %TEMP%，启动 bat 后退出当前 EXE。
  ///   bat 会等 ide_claw.exe 完全退出 → xcopy 替换 → 启动新版。
  Future<bool> installDownloaded() async {
    final last = _last;
    final assetPath = last.localApkPath;
    if (assetPath == null) return false;
    _emit(UpdateProgress(
      stage: UpdateStage.installing,
      remote: last.remote,
      localApkPath: assetPath,
    ));

    if (Platform.isWindows) {
      return _installOnWindows(assetPath);
    }

    final result = await OpenFilex.open(assetPath, type: 'application/vnd.android.package-archive');
    return result.type == ResultType.done;
  }

  /// Windows 自更新：生成 helper bat → 启动 cmd /c bat → exit(0)
  ///
  /// helper bat 的工作流：
  ///   1. 轮询等 ide_claw.exe 完全退出（避免 xcopy 时文件被占用）
  ///   2. 多等 2 秒让文件句柄释放
  ///   3. xcopy 解压目录覆盖到当前安装目录
  ///   4. start "" 启动新版 ide_claw.exe
  ///
  /// 失败兜底：xcopy 失败时 bat 不退出，pause 等用户手动处理。
  Future<bool> _installOnWindows(String extractedDir) async {
    try {
      final exePath = Platform.resolvedExecutable;
      final installDir = File(exePath).parent.path;
      final tempDir = await getTemporaryDirectory();
      final batPath = '${tempDir.path}\\ide-claw-updater.bat';

      // 注意：bat 内容用全 ASCII，避免 cmd 默认 GBK 解析 UTF-8 时乱码。
      // 路径里所有可能含空格的部分都加双引号。
      final bat = '''
@echo off
REM IDE Claw auto-updater (auto-generated; do not edit)

REM 1) Wait until ide_claw.exe fully exits
:waitloop
tasklist /FI "IMAGENAME eq ide_claw.exe" 2>nul | find /I "ide_claw.exe" >nul
if not errorlevel 1 (
    timeout /t 1 /nobreak >nul
    goto waitloop
)

REM 2) Extra delay so file handles release
timeout /t 2 /nobreak >nul

REM 3) Copy new files over current install dir
xcopy /E /Y /I "$extractedDir\\*" "$installDir\\"
if errorlevel 1 (
    echo.
    echo [ERROR] Update copy failed.
    echo Source:  $extractedDir
    echo Target:  $installDir
    echo.
    echo Please copy the source contents into the target folder manually,
    echo or re-download from https://push.shoot-game.cn/
    pause
    exit /b 1
)

REM 4) Launch new version
start "" "$installDir\\ide_claw.exe"
exit /b 0
''';

      await File(batPath).writeAsString(bat);

      // 启动 bat（detached，让父 EXE 退出后 cmd 继续跑）
      await Process.start(
        'cmd.exe',
        ['/c', batPath],
        mode: ProcessStartMode.detached,
      );

      // 给 cmd 一点启动时间，再退出当前 EXE
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e, stack) {
      debugPrint('[UpdateService] Windows install failed: $e\n$stack');
      _emit(UpdateProgress(
        stage: UpdateStage.error,
        errorMessage: 'Windows 自更新失败：$e',
      ));
      return false;
    }
  }
}
