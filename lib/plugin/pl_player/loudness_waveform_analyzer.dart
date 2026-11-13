import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/loudness_waveform.dart';
import 'package:PiliPlus/models/video/play/url.dart' show Volume;
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;

/// 仅在二级「音量均衡」界面点开后才启动的按需波形采样器。
///
/// 设计原则：
/// 1. 未点开二级页时零后台执行、零 CPU/带宽消耗；
/// 2. 使用独立无声 `ao=pcm` 离屏窗口快速采样当前位置附近 ~10 秒片段，不干扰正在播放的
///    `Player`、不重建 `af` 滤镜图、不触及 `AVAudioSession`；
/// 3. 面板关闭即通过 [isCancelled] 立即中断并清理临时 PCM 文件；
/// 4. 直播流、网络异常或平台裁剪掉 `ao=pcm` 时无缝降级至基于真实响度元数据的动态预览。
abstract final class LoudnessWaveformAnalyzer {
  static final LinkedHashMap<String, WaveformAnalysisResult> _cache =
      LinkedHashMap<String, WaveformAnalysisResult>();
  static const int _maxCacheEntries = 6;
  static int _tokenCounter = 0;

  static Future<WaveformAnalysisResult> analyzeOnDemand({
    required String? audioUrl,
    required String? videoUrl,
    required bool isFileSource,
    required bool isLive,
    required Duration position,
    required Duration duration,
    Volume? volume,
    required bool Function() isCancelled,
  }) async {
    final targetSource =
        (audioUrl != null && audioUrl.isNotEmpty) ? audioUrl : videoUrl;

    if (isLive || targetSource == null || targetSource.isEmpty) {
      return LoudnessWaveformDsp.buildMetadataFallback(
        volume: volume,
        center: position,
        totalDuration: duration,
        isLive: isLive,
      );
    }

    final window = _resolveWindow(position: position, totalDuration: duration);
    final cacheKey = '$targetSource#${window.$1.inSeconds ~/ 4}';
    final cached = _cache.remove(cacheKey);
    if (cached != null) {
      _cache[cacheKey] = cached;
      return cached;
    }

    final extracted = await _extractWithHeadlessMpv(
      sourceUrl: targetSource,
      isFileSource: isFileSource,
      windowStart: window.$1,
      windowEnd: window.$2,
      isCancelled: isCancelled,
    );

    if (isCancelled()) {
      return LoudnessWaveformDsp.buildMetadataFallback(
        volume: volume,
        center: position,
        totalDuration: duration,
        isLive: isLive,
      );
    }

    if (extracted != null) {
      _putCache(cacheKey, extracted);
      return extracted;
    }

    return LoudnessWaveformDsp.buildMetadataFallback(
      volume: volume,
      center: position,
      totalDuration: duration,
      isLive: isLive,
    );
  }

  static (Duration, Duration) _resolveWindow({
    required Duration position,
    required Duration totalDuration,
  }) {
    const windowLength = Duration(seconds: 12);
    const lead = Duration(seconds: 4);

    var start = position > lead ? position - lead : Duration.zero;
    var end = start + windowLength;
    if (totalDuration > Duration.zero && end > totalDuration) {
      end = totalDuration;
      start = end > windowLength ? end - windowLength : Duration.zero;
    }
    return (start, end);
  }

  static void _putCache(String key, WaveformAnalysisResult value) {
    if (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = value;
  }

  static Future<WaveformAnalysisResult?> _extractWithHeadlessMpv({
    required String sourceUrl,
    required bool isFileSource,
    required Duration windowStart,
    required Duration windowEnd,
    required bool Function() isCancelled,
  }) async {
    final baseTmp = _resolveTempDir();
    final id = ++_tokenCounter;
    final pcmPath = path.join(baseTmp, 'pilinara_wf_$id.pcm');
    final pcmFile = File(pcmPath);

    Player? analyzer;
    StreamSubscription<bool>? completedSub;
    StreamSubscription<String>? errorSub;

    try {
      if (pcmFile.existsSync()) {
        await pcmFile.delete();
      }

      analyzer = await Player.create(
        configuration: PlayerConfiguration(
          vo: 'null',
          osc: false,
          options: {
            'vid': 'no',
            'ao': 'pcm',
            'ao-pcm-file': pcmPath,
            'ao-pcm-waveheader': 'no',
            'ao-pcm-append': 'no',
            'audio-format': 's16',
            'audio-channels': 'mono',
            'audio-samplerate': '8000',
            'speed': '100',
            'hwdec': 'no',
            'cache': isFileSource ? 'no' : 'yes',
            'demuxer-readahead-secs': '12',
          },
        ),
      );

      if (isCancelled()) return null;

      if (!isFileSource) {
        analyzer.setMediaHeader(
          userAgent: BrowserUa.pc,
          referer: HttpString.baseUrl,
        );
      }

      final done = Completer<void>();
      completedSub = analyzer.stream.completed.listen((completed) {
        if (completed && !done.isCompleted) done.complete();
      });
      errorSub = analyzer.stream.error.listen((_) {
        if (!done.isCompleted) done.complete();
      });

      await analyzer.open(
        Media(
          sourceUrl,
          start: windowStart,
          end: windowEnd,
        ),
        play: true,
      );

      // 8000 Hz * 2 bytes/sample = 16000 bytes/sec；12s ≈ 192KB。
      const targetBytes = 16000 * 8;
      final deadline = DateTime.now().add(const Duration(milliseconds: 3500));

      while (!done.isCompleted && !isCancelled()) {
        if (pcmFile.existsSync() && pcmFile.lengthSync() >= targetBytes) {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          break;
        }
        await Future.any([
          done.future,
          Future<void>.delayed(const Duration(milliseconds: 100)),
        ]);
      }

      await analyzer.stop();
      if (isCancelled() || !pcmFile.existsSync()) return null;

      final bytes = await pcmFile.readAsBytes();
      // 至少需采样到 0.75s（12000 字节）以上有效 PCM 才认定成功
      if (bytes.lengthInBytes < 12000 || isCancelled()) return null;

      final buckets = await compute(
        LoudnessWaveformDsp.bucketsFromInt16Pcm,
        bytes,
      );
      if (buckets.isEmpty || isCancelled()) return null;

      final hasSignal = buckets.any((b) => b.peak > 1e-4);
      if (!hasSignal) return null;

      return WaveformAnalysisResult(
        rawBuckets: buckets,
        windowStart: windowStart,
        windowEnd: windowEnd,
        isRealAudio: true,
      );
    } catch (_) {
      return null;
    } finally {
      unawaited(completedSub?.cancel());
      unawaited(errorSub?.cancel());
      try {
        await analyzer?.dispose();
      } catch (_) {}
      try {
        if (pcmFile.existsSync()) {
          pcmFile.deleteSync();
        }
      } catch (_) {}
    }
  }

  static String _resolveTempDir() {
    try {
      return tmpDirPath;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }
}
