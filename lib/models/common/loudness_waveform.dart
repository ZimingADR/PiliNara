import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/video/play/url.dart' show Volume;

/// 单个时间切片的线性振幅特征（`0.0 ~ 1.0`）
class WaveformBucket {
  const WaveformBucket({
    required this.rms,
    required this.peak,
  });

  final double rms;
  final double peak;
}

/// 从真实音频 PCM 或响度元数据提取的原始片段波形
class WaveformAnalysisResult {
  const WaveformAnalysisResult({
    required this.rawBuckets,
    required this.windowStart,
    required this.windowEnd,
    required this.isRealAudio,
  });

  final List<WaveformBucket> rawBuckets;
  final Duration windowStart;
  final Duration windowEnd;
  final bool isRealAudio;
}

/// 原始波形与音量均衡处理后波形的实时对比结果
class WaveformComparison {
  const WaveformComparison({
    required this.rawBuckets,
    required this.processedBuckets,
    required this.windowStart,
    required this.windowEnd,
    required this.isRealAudio,
    required this.rawAvgDb,
    required this.processedAvgDb,
    required this.rawPeakDb,
    required this.processedPeakDb,
    required this.dynamicSpreadReductionDb,
  });

  final List<WaveformBucket> rawBuckets;
  final List<WaveformBucket> processedBuckets;
  final Duration windowStart;
  final Duration windowEnd;
  final bool isRealAudio;
  final double rawAvgDb;
  final double processedAvgDb;
  final double rawPeakDb;
  final double processedPeakDb;
  final double dynamicSpreadReductionDb;
}

abstract final class LoudnessWaveformDsp {
  static const double displayFloorDb = -48.0;
  static const int defaultBucketCount = 64;

  static double linearToDb(double linear, {double floorDb = -60.0}) {
    if (!linear.isFinite || linear <= 0) return floorDb;
    final db = 20.0 * math.log(linear) / math.ln10;
    return db.clamp(floorDb, 0.0);
  }

  /// 将线性振幅映射到 `[0.0, 1.0]` 显示高度（`-48 dBFS` ~ `0 dBFS` 对数听感刻度）
  static double linearToNormalizedHeight(
    double linear, {
    double floorDb = displayFloorDb,
  }) {
    final db = linearToDb(linear, floorDb: floorDb);
    return dbToNormalizedHeight(db, floorDb: floorDb);
  }

  /// 将 dBFS / LUFS 分贝值映射到 `[0.0, 1.0]` 显示高度
  static double dbToNormalizedHeight(
    double db, {
    double floorDb = displayFloorDb,
  }) {
    if (!db.isFinite || floorDb >= 0) return 0.0;
    return ((db - floorDb) / (0.0 - floorDb)).clamp(0.0, 1.0);
  }

  /// 从单声道 16-bit 小端序 PCM 字节流直接降采样为 [targetCount] 个 RMS/Peak 桶
  static List<WaveformBucket> bucketsFromInt16Pcm(
    Uint8List pcmBytes, {
    int targetCount = defaultBucketCount,
  }) {
    final totalSamples = pcmBytes.lengthInBytes ~/ 2;
    if (totalSamples <= 0 || targetCount <= 0) return const [];

    final data = ByteData.sublistView(pcmBytes);
    final result = <WaveformBucket>[];
    final samplesPerBucket = totalSamples / targetCount;

    for (var b = 0; b < targetCount; b++) {
      final startIdx = (b * samplesPerBucket).floor();
      var endIdx = ((b + 1) * samplesPerBucket).floor();
      if (endIdx <= startIdx) endIdx = math.min(totalSamples, startIdx + 1);
      if (startIdx >= totalSamples) {
        result.add(const WaveformBucket(rms: 0, peak: 0));
        continue;
      }

      var sumSq = 0.0;
      var maxAbs = 0.0;
      final count = endIdx - startIdx;
      for (var i = startIdx; i < endIdx; i++) {
        final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
        final absVal = sample.abs();
        sumSq += sample * sample;
        if (absVal > maxAbs) maxAbs = absVal;
      }
      final rms = math.sqrt(sumSq / count).clamp(0.0, 1.0);
      final peak = maxAbs.clamp(0.0, 1.0);
      result.add(WaveformBucket(rms: rms, peak: peak));
    }

    return result;
  }

  /// 当无法使用 `ao=pcm` 采样（如直播流或精简版 libmpv）时，
  /// 基于当前视频真实响度元数据生成确定性的动态包络作为降级可视化预览。
  static WaveformAnalysisResult buildMetadataFallback({
    Volume? volume,
    Duration center = Duration.zero,
    Duration totalDuration = Duration.zero,
    bool isLive = false,
    int count = defaultBucketCount,
  }) {
    const windowHalf = Duration(seconds: 6);
    var start = center - windowHalf;
    if (start < Duration.zero) start = Duration.zero;
    var end = start + const Duration(seconds: 12);
    if (totalDuration > Duration.zero && end > totalDuration) {
      end = totalDuration;
      start = end - const Duration(seconds: 12);
      if (start < Duration.zero) start = Duration.zero;
    }

    final hasVol = AudioNormalization.hasValidMeasuredLoudness(volume);
    final baseDb = hasVol ? volume!.measuredI.toDouble() : -21.0;
    final lra = (hasVol && volume!.measuredLra.toDouble() > 0.5)
        ? volume.measuredLra.toDouble().clamp(2.0, 18.0)
        : (isLive ? 9.5 : 10.5);
    final measuredTp = (hasVol &&
            volume!.measuredTp.toDouble().isFinite &&
            volume.measuredTp.toDouble() < 0.0 &&
            volume.measuredTp.toDouble() > -30.0)
        ? volume.measuredTp.toDouble()
        : (baseDb + lra * 0.85).clamp(-12.0, -0.3);

    final baseLinear = math.pow(10.0, baseDb / 20.0).toDouble();
    final spreadFactor = (lra / 10.0).clamp(0.35, 1.8);
    final tpLinear = math.pow(10.0, measuredTp / 20.0).toDouble();

    final buckets = List<WaveformBucket>.generate(count, (i) {
      final t = i / count;
      // 模拟真实语句节奏：低声段落 + 句间短停顿 + 正常对白 + 突发高音尖峰
      final phrase = 0.5 + 0.5 * math.sin(t * math.pi * 4.2 - 0.6);
      final micro = 0.72 + 0.28 * math.sin(t * math.pi * 19.0 + 0.4);
      final pauseGate = (i >= 14 && i <= 17) || (i >= 41 && i <= 43);
      final burst = (i >= 48 && i <= 51);
      final whisper = (i >= 20 && i <= 31);

      double dbOffset;
      if (pauseGate) {
        dbOffset = -26.0;
      } else if (whisper) {
        dbOffset = -6.5 * spreadFactor + 2.0 * micro;
      } else if (burst) {
        dbOffset = 5.8 * spreadFactor * (i == 49 ? 1.15 : 0.95);
      } else {
        dbOffset = (phrase - 0.45) * 4.5 * spreadFactor + (micro - 0.85) * 2.5;
      }

      final rms = (baseLinear * math.pow(10.0, dbOffset / 20.0))
          .toDouble()
          .clamp(0.001, 0.95);
      final crest = burst ? 2.4 : (pauseGate ? 1.4 : 2.0);
      final peak = (rms * crest).clamp(rms, math.max(rms, tpLinear)).toDouble();
      return WaveformBucket(rms: rms, peak: peak.clamp(0.0, 1.0));
    });

    return WaveformAnalysisResult(
      rawBuckets: buckets,
      windowStart: start,
      windowEnd: end,
      isRealAudio: false,
    );
  }

  /// 对原始波形桶施加与当前音频滤镜链一致的 DSP 变换，即时生成处理后波形用于预览对比。
  static WaveformComparison simulate({
    required WaveformAnalysisResult raw,
    required String config,
    required int targetLufs,
    required int strength,
    Volume? volume,
    String fallbackConfig = AudioNormalization.disableCode,
    bool isLive = false,
  }) {
    final rawBuckets = raw.rawBuckets;
    if (rawBuckets.isEmpty) {
      return WaveformComparison(
        rawBuckets: const [],
        processedBuckets: const [],
        windowStart: raw.windowStart,
        windowEnd: raw.windowEnd,
        isRealAudio: raw.isRealAudio,
        rawAvgDb: displayFloorDb,
        processedAvgDb: displayFloorDb,
        rawPeakDb: displayFloorDb,
        processedPeakDb: displayFloorDb,
        dynamicSpreadReductionDb: 0,
      );
    }

    final enabled = AudioNormalization.isEnabledConfig(config) &&
        config != AudioNormalization.customCode;

    final List<WaveformBucket> processed;
    if (!enabled) {
      processed = rawBuckets;
    } else if (config == AudioNormalization.bewlyCode ||
        (config == AudioNormalization.loudnormCode &&
            !AudioNormalization.hasValidMeasuredLoudness(volume) &&
            fallbackConfig == AudioNormalization.bewlyCode)) {
      processed = _simulateBewly(
        rawBuckets,
        targetLufs: targetLufs,
        strength: strength,
        volume: volume,
        isLive: isLive,
      );
    } else if (config == AudioNormalization.loudnormCode) {
      processed = _simulateLoudnorm(
        rawBuckets,
        targetLufs: targetLufs,
        volume: volume,
        fallbackConfig: fallbackConfig,
        strength: strength,
        isLive: isLive,
      );
    } else if (config == AudioNormalization.dynaudnormCode ||
        (config == AudioNormalization.loudnormCode &&
            fallbackConfig == AudioNormalization.dynaudnormCode)) {
      processed = _simulateDynaudnorm(
        rawBuckets,
        targetRms: 0.25,
        maxGain: 3.5,
        peakTarget: 0.5,
        radius: 3,
        silenceGate: 0.003,
        compressFactor: 0.0,
      );
    } else {
      processed = rawBuckets;
    }

    final rawStats = _computeStats(rawBuckets);
    final procStats = _computeStats(processed);

    return WaveformComparison(
      rawBuckets: rawBuckets,
      processedBuckets: processed,
      windowStart: raw.windowStart,
      windowEnd: raw.windowEnd,
      isRealAudio: raw.isRealAudio,
      rawAvgDb: rawStats.avgDb,
      processedAvgDb: procStats.avgDb,
      rawPeakDb: rawStats.peakDb,
      processedPeakDb: procStats.peakDb,
      dynamicSpreadReductionDb:
          math.max(0.0, rawStats.spreadDb - procStats.spreadDb),
    );
  }

  static List<WaveformBucket> _simulateBewly(
    List<WaveformBucket> rawBuckets, {
    required int targetLufs,
    required int strength,
    Volume? volume,
    required bool isLive,
  }) {
    final params = AudioNormalization.resolveBewlyParameters(
      targetLufs: targetLufs,
      strength: strength,
      volume: volume,
      isLive: isLive,
    );

    final preGainLinear = params.baseGainDb != null
        ? math.pow(10.0, params.baseGainDb! / 20.0).toDouble()
        : 1.0;

    // Stage 1: 跨视频预增益与 0 dBFS 保护
    final stage1 = rawBuckets.map((b) {
      final rms = (b.rms * preGainLinear).clamp(0.0, 1.0);
      final peak = (b.peak * preGainLinear).clamp(0.0, 1.0);
      return WaveformBucket(rms: rms, peak: peak);
    }).toList();

    final clampedStrength = strength.clamp(
      AudioNormalization.minStrength,
      AudioNormalization.maxStrength,
    );
    final applyDynamic = clampedStrength > 0 || params.baseGainDb == null;

    // Stage 2: LRA 自适应平滑 + 噪声门限冻结
    final stage2 = applyDynamic
        ? _simulateDynaudnorm(
            stage1,
            targetRms: params.targetRms,
            maxGain: params.maxGainLinear,
            peakTarget: AudioNormalization.peakLimitLinear,
            radius: (params.gaussFrames ~/ 2).clamp(2, 6),
            silenceGate: params.silenceGate,
            compressFactor: params.compressFactor,
          )
        : stage1;

    // Stage 3: -1.0 dBFS 软/前瞻限制器
    const limit = AudioNormalization.peakLimitLinear;
    return stage2.map((b) {
      if (b.peak <= limit) return b;
      final ratio = limit / b.peak;
      return WaveformBucket(
        rms: math.min(limit, b.rms * math.pow(ratio, 0.7).toDouble()),
        peak: limit,
      );
    }).toList();
  }

  static List<WaveformBucket> _simulateLoudnorm(
    List<WaveformBucket> rawBuckets, {
    required int targetLufs,
    Volume? volume,
    required String fallbackConfig,
    required int strength,
    required bool isLive,
  }) {
    if (!AudioNormalization.hasValidMeasuredLoudness(volume)) {
      if (fallbackConfig == AudioNormalization.disableCode) return rawBuckets;
      return _simulateBewly(
        rawBuckets,
        targetLufs: targetLufs,
        strength: strength,
        volume: volume,
        isLive: isLive,
      );
    }
    final gainDb = (-16.0 - volume!.measuredI.toDouble()).clamp(-18.0, 12.0);
    final gain = math.pow(10.0, gainDb / 20.0).toDouble();
    final tpLimit = math.pow(10.0, -1.5 / 20.0).toDouble();
    return rawBuckets.map((b) {
      final peak = math.min(tpLimit, b.peak * gain);
      final rms = math.min(peak, b.rms * gain);
      return WaveformBucket(rms: rms, peak: peak);
    }).toList();
  }

  static List<WaveformBucket> _simulateDynaudnorm(
    List<WaveformBucket> input, {
    required double targetRms,
    required double maxGain,
    required double peakTarget,
    required int radius,
    required double silenceGate,
    required double compressFactor,
  }) {
    final n = input.length;
    if (n == 0) return const [];

    // 计算每帧理想增益（含静音门限冻结与软膝峰值约束）
    final rawGains = List<double>.filled(n, 1.0);
    for (var i = 0; i < n; i++) {
      final b = input[i];
      if (b.peak <= silenceGate || b.rms <= 1e-6) {
        rawGains[i] = 1.0;
        continue;
      }
      var effectivePeak = b.peak;
      if (compressFactor > 0.0 && b.peak > 0.0) {
        // 近似 dynaudnorm 软压缩阈值收敛
        effectivePeak =
            b.peak / (1.0 + compressFactor * 0.12 * math.max(0.0, b.peak - 0.35));
      }
      final rmsGain = targetRms / math.max(b.rms, 1e-5);
      final peakCap = peakTarget / math.max(effectivePeak, 1e-5);
      rawGains[i] = math.min(rmsGain, peakCap).clamp(0.25, maxGain);
    }

    // 高斯核加权平滑（避免音节间突变与抽吸）
    final sigma = math.max(1.0, radius / 1.4);
    final out = <WaveformBucket>[];
    for (var i = 0; i < n; i++) {
      if (input[i].peak <= silenceGate) {
        out.add(input[i]);
        continue;
      }
      var weightedGain = 0.0;
      var weightSum = 0.0;
      for (var k = -radius; k <= radius; k++) {
        final idx = (i + k).clamp(0, n - 1);
        final w = math.exp(-(k * k) / (2.0 * sigma * sigma));
        weightedGain += rawGains[idx] * w;
        weightSum += w;
      }
      final gain = (weightedGain / weightSum).clamp(0.25, maxGain);
      out.add(
        WaveformBucket(
          rms: (input[i].rms * gain).clamp(0.0, 1.0),
          peak: (input[i].peak * gain).clamp(0.0, 1.0),
        ),
      );
    }
    return out;
  }

  static ({double avgDb, double peakDb, double spreadDb}) _computeStats(
    List<WaveformBucket> buckets,
  ) {
    final activeRmsDb = <double>[];
    var maxPeak = 0.0;
    for (final b in buckets) {
      if (b.peak > maxPeak) maxPeak = b.peak;
      if (b.rms > 0.005) {
        activeRmsDb.add(linearToDb(b.rms, floorDb: displayFloorDb));
      }
    }
    if (activeRmsDb.isEmpty) {
      return (
        avgDb: displayFloorDb,
        peakDb: linearToDb(maxPeak, floorDb: displayFloorDb),
        spreadDb: 0.0,
      );
    }
    activeRmsDb.sort();
    final sum = activeRmsDb.fold<double>(0.0, (a, b) => a + b);
    final avg = sum / activeRmsDb.length;
    final p10 = activeRmsDb[(activeRmsDb.length * 0.15).floor()];
    final p90 = activeRmsDb[
        math.min(activeRmsDb.length - 1, (activeRmsDb.length * 0.85).floor())];
    return (
      avgDb: avg,
      peakDb: linearToDb(maxPeak, floorDb: displayFloorDb),
      spreadDb: math.max(0.0, p90 - p10),
    );
  }
}
