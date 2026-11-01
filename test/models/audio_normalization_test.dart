import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/video/play/url.dart' show Volume;
import 'package:flutter_test/flutter_test.dart';

Volume _makeVolume({
  num measuredI = -14.0,
  num measuredLra = 8.0,
  num measuredTp = -1.2,
  num measuredThreshold = -24.5,
}) {
  return Volume(
    measuredI: measuredI,
    measuredLra: measuredLra,
    measuredTp: measuredTp,
    measuredThreshold: measuredThreshold,
    targetOffset: 0,
    targetI: -16,
    targetTp: -1,
  );
}

void main() {
  group('AudioNormalization (BewlyCat Volume Balance)', () {
    test('禁用模式返回空字符串以便清空 mpv af 属性', () {
      expect(
        AudioNormalization.buildMpvAfFilter(
          config: AudioNormalization.disableCode,
          volume: _makeVolume(),
        ),
        isEmpty,
      );
      expect(AudioNormalization.isEnabledConfig('0'), isFalse);
      expect(AudioNormalization.isEnabledConfig('bewly'), isTrue);
    });

    test('过响视频生成负向预增益 + dynaudnorm + alimiter 三级滤镜链', () {
      final volume = _makeVolume(measuredI: -11.0);
      final af = AudioNormalization.buildMpvAfFilter(
        config: AudioNormalization.bewlyCode,
        targetLufs: -18,
        strength: 75,
        volume: volume,
      );

      expect(af, startsWith('lavfi=[volume=-'));
      expect(af, contains('dB,dynaudnorm=f=200:g=7:p=0.89125:'));
      expect(af, contains(':n=1:b=1:t=0.0024,'));
      expect(
        af,
        endsWith('alimiter=limit=0.89125:attack=5:release=80:level=0:latency=1]'),
      );

      final baseGain = AudioNormalization.computeBaseGainDb(
        targetLufs: -18,
        strength: 75,
        volume: volume,
      );
      expect(baseGain, isNotNull);
      expect(baseGain!, lessThan(-5.0));
    });

    test('过轻视频生成正向预增益并严格钳制在 [-18 dB, +9 dB] 安全区间', () {
      final quietVolume = _makeVolume(measuredI: -32.0);
      final baseGain = AudioNormalization.computeBaseGainDb(
        targetLufs: -18,
        strength: 100,
        volume: quietVolume,
      );
      expect(baseGain, 9.0);

      final extremeLoudVolume = _makeVolume(measuredI: -1.0);
      final negativeGain = AudioNormalization.computeBaseGainDb(
        targetLufs: -24,
        strength: 100,
        volume: extremeLoudVolume,
      );
      expect(negativeGain, -18.0);
    });

    test('无服务端响度数据（缓存视频/直播/空 Volume）时跳过预增益并放宽局部动态提亮范围', () {
      final afNoVolume = AudioNormalization.buildMpvAfFilter(
        config: AudioNormalization.bewlyCode,
        targetLufs: -18,
        strength: 75,
      );
      expect(afNoVolume, startsWith('lavfi=[dynaudnorm=f=200:'));
      expect(afNoVolume.contains('volume='), isFalse);
      expect(
        afNoVolume,
        endsWith('alimiter=limit=0.89125:attack=5:release=80:level=0:latency=1]'),
      );

      final emptyVolume = Volume.fromJson(const {});
      expect(AudioNormalization.hasValidMeasuredLoudness(emptyVolume), isFalse);
    });

    test('所有强度档位 (40%~100%) 生成的 dynaudnorm 高斯窗口帧数 g 恒为合法奇数', () {
      final gRegex = RegExp(r'dynaudnorm=f=200:g=(\d+):');
      for (int s = 40; s <= 100; s++) {
        final graph = AudioNormalization.buildBewlyFilterGraph(
          targetLufs: -18,
          strength: s,
        );
        final match = gRegex.firstMatch(graph);
        expect(match, isNotNull, reason: 'strength=$s missing g parameter');
        final g = int.parse(match!.group(1)!);
        expect(g.isOdd, isTrue, reason: 'strength=$s produced even g=$g');
        expect(g, inInclusiveRange(5, 11));
      }
    });

    test('兼容原有 dynaudnorm / loudnorm / 自定义滤镜配置（零回归）', () {
      expect(
        AudioNormalization.buildMpvAfFilter(
          config: AudioNormalization.dynaudnormCode,
        ),
        'lavfi=[${AudioNormalization.dynaudnorm.param}]',
      );

      final loudnormWithVol = AudioNormalization.buildMpvAfFilter(
        config: AudioNormalization.loudnormCode,
        volume: _makeVolume(measuredI: -14.2),
      );
      expect(loudnormWithVol, startsWith('lavfi=[loudnorm=LRA='));
      expect(loudnormWithVol, contains('measured_I=-14.2'));

      final loudnormFallbackToBewly = AudioNormalization.buildMpvAfFilter(
        config: AudioNormalization.loudnormCode,
        volume: null,
        fallbackConfig: AudioNormalization.bewlyCode,
      );
      expect(loudnormFallbackToBewly, startsWith('lavfi=[dynaudnorm='));

      final loudnormFallbackDisabled = AudioNormalization.buildMpvAfFilter(
        config: AudioNormalization.loudnormCode,
        volume: null,
        fallbackConfig: AudioNormalization.disableCode,
      );
      expect(loudnormFallbackDisabled, isEmpty);

      final customFilter = AudioNormalization.buildMpvAfFilter(
        config: 'acompressor=threshold=-18dB:ratio=3',
      );
      expect(customFilter, 'lavfi=[acompressor=threshold=-18dB:ratio=3]');
    });

    test('状态摘要与设置页副标题输出符合预期', () {
      final activeSummary = AudioNormalization.describeActiveState(
        config: AudioNormalization.bewlyCode,
        targetLufs: -18,
        strength: 75,
        volume: _makeVolume(measuredI: -13.5),
      );
      expect(activeSummary.enabled, isTrue);
      expect(activeSummary.isBewlyMode, isTrue);
      expect(activeSummary.shortStatusText, contains('原始 -13.5 LUFS'));
      expect(activeSummary.shortStatusText, contains('预增益 -'));

      expect(
        AudioNormalization.getSettingSummary(
          config: AudioNormalization.bewlyCode,
          targetLufs: -18,
          strength: 75,
        ),
        '当前:「智能音量平衡」· 目标 -18 LUFS · 强度 75%',
      );
    });
  });
}
