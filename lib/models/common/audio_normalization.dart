import 'dart:math' as math;

import 'package:PiliPlus/models/video/play/url.dart' show Volume;

class LoudnessActiveSummary {
  const LoudnessActiveSummary({
    required this.enabled,
    required this.modeTitle,
    required this.isBewlyMode,
    this.measuredLufs,
    this.baseGainDb,
    required this.targetLufs,
    required this.strength,
    required this.mpvAfFilter,
  });

  final bool enabled;
  final String modeTitle;
  final bool isBewlyMode;
  final double? measuredLufs;
  final double? baseGainDb;
  final int targetLufs;
  final int strength;
  final String mpvAfFilter;

  String get shortStatusText {
    if (!enabled) return '已关闭';
    if (!isBewlyMode) return modeTitle;
    if (measuredLufs != null && baseGainDb != null) {
      final sign = baseGainDb! >= 0 ? '+' : '';
      return '原始 ${measuredLufs!.toStringAsFixed(1)} LUFS · 预增益 $sign${baseGainDb!.toStringAsFixed(1)} dB';
    }
    return '实时局部动态均衡生效中（目标 $targetLufs LUFS）';
  }
}

enum AudioNormalization {
  disable('禁用'),
  bewly('智能音量平衡'),
  // ref https://github.com/KRTirtho/spotube/commit/da10ab2e291d4ba4d3082b9a6ae535639fb8f1b7
  dynaudnorm('动态平滑 dynaudnorm', 'dynaudnorm=g=5:f=250:r=0.9:p=0.5'),
  loudnorm('标准响度 loudnorm', 'loudnorm=I=-16:LRA=11:TP=-1.5'),
  custom('自定义参数'),
  ;

  final String title;
  final String param;
  const AudioNormalization(this.title, [this.param = '']);

  static const String disableCode = '0';
  static const String bewlyCode = 'bewly';
  static const String dynaudnormCode = '1';
  static const String loudnormCode = '2';
  static const String customCode = '3';

  static const int minTargetLufs = -24;
  static const int maxTargetLufs = -14;
  static const int defaultTargetLufs = -18;

  static const int minStrength = 40;
  static const int maxStrength = 100;
  static const int defaultStrength = 75;

  /// -1.0 dBFS 采样峰值上限 (10^(-1/20) ≈ 0.89125)
  static const double _peakLimitLinear = 0.89125;

  /// -50 LUFS 静音与底噪冻结门限对应的双声道单路 RMS 阈值
  static const double _silenceGateRms = 0.0024;

  static bool isEnabledConfig(String config) =>
      config.isNotEmpty && config != disableCode;

  static String getTitleFromConfig(String config) => switch (config) {
    disableCode => disable.title,
    bewlyCode => bewly.title,
    dynaudnormCode => dynaudnorm.title,
    loudnormCode => loudnorm.title,
    customCode => custom.title,
    _ => config,
  };

  static String getSettingSummary({
    required String config,
    required int targetLufs,
    required int strength,
    String fallback = disableCode,
  }) {
    if (!isEnabledConfig(config)) {
      return '当前:「已禁用」';
    }
    if (config == bewlyCode) {
      return '当前:「${bewly.title}」· 目标 $targetLufs LUFS · 强度 $strength%';
    }
    final modeTitle = getTitleFromConfig(config);
    if ((config == loudnormCode || loudnormRegExp.hasMatch(config)) &&
        fallback != disableCode) {
      return '当前:「$modeTitle」，无参数时:「${getTitleFromConfig(fallback)}」';
    }
    return '当前:「$modeTitle」';
  }

  static String getParamFromConfig(String config) => switch (config) {
    disableCode => disable.param,
    bewlyCode => bewlyCode,
    dynaudnormCode => dynaudnorm.param,
    loudnormCode => loudnorm.param,
    _ => config,
  };

  static final loudnormRegExp = RegExp('loudnorm=([^,]+)');

  static bool hasValidMeasuredLoudness(Volume? volume) {
    if (volume == null || !volume.isNotEmpty) return false;
    final measured = volume.measuredI.toDouble();
    return measured.isFinite && measured < -0.5 && measured > -70.0;
  }

  /// 计算跨视频基准对齐预增益（单位 dB）。无有效服务端响度数据时返回 null。
  static double? computeBaseGainDb({
    required int targetLufs,
    required int strength,
    Volume? volume,
  }) {
    if (!hasValidMeasuredLoudness(volume)) return null;
    final clampedTarget = targetLufs.clamp(minTargetLufs, maxTargetLufs);
    final clampedStrength = strength.clamp(minStrength, maxStrength);
    final norm =
        (clampedStrength - minStrength) / (maxStrength - minStrength);
    // 跨视频整体基准偏移按 75%~100% 权重先行拉齐，限制在 [-18 dB, +9 dB] 安全范围
    final alignWeight = 0.75 + 0.25 * norm;
    final delta = (clampedTarget - volume!.measuredI.toDouble()) * alignWeight;
    return delta.clamp(-18.0, 9.0);
  }

  /// 构建 BewlyCat 风格三级 FFmpeg 音频滤镜图（不含外层 `lavfi=[...]`）：
  /// 1) 跨视频基准响度预增益 (`volume`，可选)
  /// 2) 视频内局部动态平滑与 -50 LUFS 底噪保护 (`dynaudnorm`)
  /// 3) 5ms 前瞻 -1.0 dBFS 峰值防爆音限制器 (`alimiter`，带 PTS 延迟自动补偿)
  static String buildBewlyFilterGraph({
    required int targetLufs,
    required int strength,
    Volume? volume,
  }) {
    final clampedTarget = targetLufs.clamp(minTargetLufs, maxTargetLufs);
    final clampedStrength = strength.clamp(minStrength, maxStrength);
    final norm =
        (clampedStrength - minStrength) / (maxStrength - minStrength);

    final baseGainDb = computeBaseGainDb(
      targetLufs: clampedTarget,
      strength: clampedStrength,
      volume: volume,
    );

    // 双声道 BS.1770 响度与每声道 RMS 映射：L_LUFS ≈ 2.319 + 20 * log10(rms)
    final targetRms = math
        .pow(10.0, (clampedTarget - 2.319) / 20.0)
        .toDouble()
        .clamp(0.02, 0.35);

    // 高斯平滑窗口帧数（必须为奇数，3~301）：强度越高窗口越紧凑（40%->11帧≈2.2s，75%->7帧≈1.4s，100%->5帧≈1.0s）
    int gaussFrames = (11 - norm * 6).round();
    if (gaussFrames.isEven) {
      gaussFrames -= 1;
    }
    gaussFrames = gaussFrames.clamp(5, 11);

    // 最大局部提亮增益：有服务端预增益时 +4.0 ~ +9.0 dB (1.58x ~ 2.82x)；
    // 无服务端预增益时需兼顾跨视频提亮，放宽至 +6.0 ~ +12.0 dB (2.00x ~ 3.98x)
    final maxBoostDb = baseGainDb != null
        ? (4.0 + 5.0 * norm)
        : (6.0 + 6.0 * norm);
    final maxGainLinear = math.pow(10.0, maxBoostDb / 20.0).toDouble();

    final stages = <String>[
      if (baseGainDb != null && baseGainDb.abs() >= 0.05)
        'volume=${baseGainDb.toStringAsFixed(2)}dB',
      'dynaudnorm='
          'f=200:'
          'g=$gaussFrames:'
          'p=${_peakLimitLinear.toStringAsFixed(5)}:'
          'm=${maxGainLinear.toStringAsFixed(2)}:'
          'r=${targetRms.toStringAsFixed(4)}:'
          'n=1:'
          'b=1:'
          't=${_silenceGateRms.toStringAsFixed(4)}',
      'alimiter='
          'limit=${_peakLimitLinear.toStringAsFixed(5)}:'
          'attack=5:'
          'release=80:'
          'level=0:'
          'latency=1',
    ];

    return stages.join(',');
  }

  static String parse(
    Volume? volume,
    String param, {
    String fallbackConfig = disableCode,
    int targetLufs = defaultTargetLufs,
    int strength = defaultStrength,
  }) {
    if (volume != null && volume.isNotEmpty) {
      return param.replaceFirstMapped(
        loudnormRegExp,
        (i) =>
            'loudnorm=${volume.format(
              Map.fromEntries(
                i.group(1)!.split(':').map((item) {
                  final parts = item.split('=');
                  return MapEntry(parts[0].toLowerCase(), num.parse(parts[1]));
                }),
              ),
            )}',
      );
    } else {
      final replacement = fallbackConfig == bewlyCode
          ? buildBewlyFilterGraph(
              targetLufs: targetLufs,
              strength: strength,
            )
          : getParamFromConfig(fallbackConfig);
      return param.replaceFirst(loudnormRegExp, replacement);
    }
  }

  /// 构建直接下发给 mpv `setProperty('af', ...)` 的滤镜字符串。
  /// 禁用或无有效滤镜时返回空字符串 `''`（用于清空 mpv 当前音频滤镜）。
  static String buildMpvAfFilter({
    required String config,
    int targetLufs = defaultTargetLufs,
    int strength = defaultStrength,
    Volume? volume,
    String fallbackConfig = disableCode,
  }) {
    final trimmed = config.trim();
    if (!isEnabledConfig(trimmed) || trimmed == customCode) {
      return '';
    }
    if (trimmed == bewlyCode) {
      final graph = buildBewlyFilterGraph(
        targetLufs: targetLufs,
        strength: strength,
        volume: volume,
      );
      return 'lavfi=[$graph]';
    }
    final rawParam = getParamFromConfig(trimmed);
    final parsed = parse(
      volume,
      rawParam,
      fallbackConfig: fallbackConfig,
      targetLufs: targetLufs,
      strength: strength,
    ).trim();
    if (parsed.isEmpty) {
      return '';
    }
    if (parsed.startsWith('lavfi=')) {
      return parsed;
    }
    return 'lavfi=[$parsed]';
  }

  static LoudnessActiveSummary describeActiveState({
    required String config,
    required int targetLufs,
    required int strength,
    Volume? volume,
    String fallbackConfig = disableCode,
  }) {
    final enabled = isEnabledConfig(config);
    final isBewly = config == bewlyCode;
    final filter = buildMpvAfFilter(
      config: config,
      targetLufs: targetLufs,
      strength: strength,
      volume: volume,
      fallbackConfig: fallbackConfig,
    );
    return LoudnessActiveSummary(
      enabled: enabled && filter.isNotEmpty,
      modeTitle: getTitleFromConfig(config),
      isBewlyMode: isBewly,
      measuredLufs: hasValidMeasuredLoudness(volume)
          ? volume!.measuredI.toDouble()
          : null,
      baseGainDb: isBewly
          ? computeBaseGainDb(
              targetLufs: targetLufs,
              strength: strength,
              volume: volume,
            )
          : null,
      targetLufs: targetLufs.clamp(minTargetLufs, maxTargetLufs),
      strength: strength.clamp(minStrength, maxStrength),
      mpvAfFilter: filter,
    );
  }
}
