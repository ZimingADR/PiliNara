import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/loudness_waveform.dart';
import 'package:PiliPlus/models/video/play/url.dart' show Volume;
import 'package:PiliPlus/plugin/pl_player/loudness_waveform_analyzer.dart';
import 'package:flutter/material.dart';

/// 音量均衡二级面板专用的「原始 vs 处理后」波形对比卡片。
///
/// 仅在面板打开（组件挂载）时才触发采样计算；退出面板时自动取消并释放资源。
class LoudnessWaveformCard extends StatefulWidget {
  const LoudnessWaveformCard({
    super.key,
    required this.enabled,
    required this.config,
    required this.targetLufs,
    required this.strength,
    required this.fallbackConfig,
    required this.isLive,
    this.volume,
    this.audioUrl,
    this.videoUrl,
    this.isFileSource = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.positionStream,
    this.compact = true,
  });

  final bool enabled;
  final String config;
  final int targetLufs;
  final int strength;
  final String fallbackConfig;
  final bool isLive;
  final Volume? volume;
  final String? audioUrl;
  final String? videoUrl;
  final bool isFileSource;
  final Duration position;
  final Duration duration;
  final Stream<Duration>? positionStream;
  final bool compact;

  @override
  State<LoudnessWaveformCard> createState() => _LoudnessWaveformCardState();
}

class _LoudnessWaveformCardState extends State<LoudnessWaveformCard> {
  WaveformAnalysisResult? _rawResult;
  bool _loading = true;
  bool _disposed = false;
  int _generation = 0;
  late Duration _livePosition = widget.position;
  StreamSubscription<Duration>? _positionSub;

  @override
  void initState() {
    super.initState();
    _listenPosition();
    _startAnalysis();
  }

  @override
  void didUpdateWidget(covariant LoudnessWaveformCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positionStream != widget.positionStream) {
      _positionSub?.cancel();
      _positionSub = null;
      _listenPosition();
    }
    if (oldWidget.audioUrl != widget.audioUrl ||
        oldWidget.videoUrl != widget.videoUrl ||
        oldWidget.isLive != widget.isLive ||
        oldWidget.volume?.measuredI != widget.volume?.measuredI) {
      _livePosition = widget.position;
      _startAnalysis();
    }
  }

  void _listenPosition() {
    _positionSub = widget.positionStream?.listen((pos) {
      if (!mounted) return;
      if ((pos.inMilliseconds - _livePosition.inMilliseconds).abs() >= 250) {
        setState(() => _livePosition = pos);
      }
    });
  }

  void _startAnalysis() {
    final gen = ++_generation;
    setState(() => _loading = true);
    LoudnessWaveformAnalyzer.analyzeOnDemand(
      audioUrl: widget.audioUrl,
      videoUrl: widget.videoUrl,
      isFileSource: widget.isFileSource,
      isLive: widget.isLive,
      position: _livePosition,
      duration: widget.duration,
      volume: widget.volume,
      isCancelled: () => _disposed || gen != _generation,
    ).then((result) {
      if (_disposed || gen != _generation || !mounted) return;
      setState(() {
        _rawResult = result;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _positionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final activeRaw = _rawResult ??
        LoudnessWaveformDsp.buildMetadataFallback(
          volume: widget.volume,
          center: _livePosition,
          totalDuration: widget.duration,
          isLive: widget.isLive,
        );

    final comparison = LoudnessWaveformDsp.simulate(
      raw: activeRaw,
      config: widget.config,
      targetLufs: widget.targetLufs,
      strength: widget.strength,
      volume: widget.volume,
      fallbackConfig: widget.fallbackConfig,
      isLive: widget.isLive,
    );

    final double? playheadProgress = _computePlayheadProgress(
      _livePosition,
      comparison.windowStart,
      comparison.windowEnd,
    );

    final badgeText = _loading
        ? '采样中'
        : (comparison.isRealAudio
            ? '实测音频'
            : (widget.isLive ? '直播响应' : '动态预览'));

    final chartHeight = widget.compact ? 74.0 : 92.0;

    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        10,
        12,
        widget.compact ? 9 : 11,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.45),
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.ssid_chart_rounded,
                size: 15,
                color: widget.enabled ? cs.primary : cs.outline,
              ),
              const SizedBox(width: 6),
              Text(
                '响度波形对比',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: (_loading || !comparison.isRealAudio)
                      ? cs.surfaceContainerHigh
                      : cs.primaryContainer.withValues(alpha: 0.72),
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_loading) ...[
                      SizedBox(
                        width: 9,
                        height: 9,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.4,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      badgeText,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: comparison.isRealAudio && !_loading
                            ? cs.onPrimaryContainer
                            : cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (!widget.isLive &&
                  (widget.audioUrl != null || widget.videoUrl != null))
                InkWell(
                  onTap: _loading ? null : _startAnalysis,
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.refresh_rounded,
                      size: 15,
                      color: cs.outline,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: chartHeight,
            width: double.infinity,
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              child: CustomPaint(
                painter: _LoudnessWaveformPainter(
                  comparison: comparison,
                  enabled: widget.enabled,
                  isBewlyMode: widget.config == AudioNormalization.bewlyCode,
                  targetLufs: widget.targetLufs,
                  playheadProgress: playheadProgress,
                  primaryColor: cs.primary,
                  rawColor: cs.outline,
                  gridColor: cs.outlineVariant,
                  ceilingColor: cs.error,
                  labelColor: cs.outline,
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              _LegendDot(
                color: cs.outline.withValues(alpha: 0.85),
                label: '原始',
                dashed: true,
                textColor: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              _LegendDot(
                color: widget.enabled ? cs.primary : cs.outline,
                label: widget.enabled ? '均衡后' : '均衡已关',
                dashed: false,
                textColor: cs.onSurfaceVariant,
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  _buildMetricsText(comparison, widget.enabled),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: widget.enabled ? cs.primary : cs.outline,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  double? _computePlayheadProgress(
    Duration pos,
    Duration start,
    Duration end,
  ) {
    final spanMs = end.inMilliseconds - start.inMilliseconds;
    if (spanMs <= 0) return null;
    if (pos < start || pos > end) return null;
    return ((pos.inMilliseconds - start.inMilliseconds) / spanMs)
        .clamp(0.0, 1.0);
  }

  String _buildMetricsText(WaveformComparison c, bool enabled) {
    if (!enabled) {
      return '均值 ${c.rawAvgDb.toStringAsFixed(1)} dB · 原声直出';
    }
    final avgText =
        '${c.rawAvgDb.toStringAsFixed(0)} → ${c.processedAvgDb.toStringAsFixed(0)} dB';
    final peakText = '峰值 ${c.processedPeakDb.toStringAsFixed(1)} dB';
    return '$avgText · $peakText';
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
    required this.dashed,
    required this.textColor,
  });

  final Color color;
  final String label;
  final bool dashed;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: dashed ? 10 : 8,
          height: dashed ? 2 : 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(dashed ? 1 : 4),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 10.5, color: textColor),
        ),
      ],
    );
  }
}

class _LoudnessWaveformPainter extends CustomPainter {
  _LoudnessWaveformPainter({
    required this.comparison,
    required this.enabled,
    required this.isBewlyMode,
    required this.targetLufs,
    required this.playheadProgress,
    required this.primaryColor,
    required this.rawColor,
    required this.gridColor,
    required this.ceilingColor,
    required this.labelColor,
  });

  final WaveformComparison comparison;
  final bool enabled;
  final bool isBewlyMode;
  final int targetLufs;
  final double? playheadProgress;
  final Color primaryColor;
  final Color rawColor;
  final Color gridColor;
  final Color ceilingColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    const topPad = 4.0;
    const bottomPad = 2.0;
    final plotHeight = math.max(1.0, size.height - topPad - bottomPad);

    double yForDb(double db) {
      final norm = LoudnessWaveformDsp.dbToNormalizedHeight(db);
      return topPad + plotHeight * (1.0 - norm);
    }

    // 1. 参考标线：-1.0 dBFS 峰值上限 & 目标 LUFS 基准线
    final ceilingY = yForDb(-1.0);
    _drawDashedLine(
      canvas,
      Offset(0, ceilingY),
      Offset(size.width, ceilingY),
      Paint()
        ..color = ceilingColor.withValues(alpha: 0.35)
        ..strokeWidth = 0.8,
      dash: 3,
      gap: 3,
    );

    if (enabled && isBewlyMode) {
      final targetY = yForDb(targetLufs.toDouble());
      _drawDashedLine(
        canvas,
        Offset(0, targetY),
        Offset(size.width, targetY),
        Paint()
          ..color = primaryColor.withValues(alpha: 0.42)
          ..strokeWidth = 0.9,
        dash: 4,
        gap: 3,
      );
    }

    final midY = yForDb(-24.0);
    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      Paint()
        ..color = gridColor.withValues(alpha: 0.3)
        ..strokeWidth = 0.6,
    );

    final raw = comparison.rawBuckets;
    final proc = comparison.processedBuckets;
    if (raw.length < 2) return;

    final stepX = size.width / (raw.length - 1);

    // 2. 原始波形：峰值细竖条 + 平滑包络线（虚线感/轮廓线，便于叠层直观对比）
    final rawPeakPaint = Paint()
      ..color = rawColor.withValues(alpha: 0.22)
      ..strokeWidth = math.max(1.2, stepX * 0.42)
      ..strokeCap = StrokeCap.round;

    final rawRmsPoints = <Offset>[];
    for (var i = 0; i < raw.length; i++) {
      final x = i * stepX;
      final rmsNorm = LoudnessWaveformDsp.linearToNormalizedHeight(raw[i].rms);
      final peakNorm =
          LoudnessWaveformDsp.linearToNormalizedHeight(raw[i].peak);
      final yRms = topPad + plotHeight * (1.0 - rmsNorm);
      final yPeak = topPad + plotHeight * (1.0 - peakNorm);
      rawRmsPoints.add(Offset(x, yRms));
      canvas.drawLine(Offset(x, size.height - bottomPad), Offset(x, yPeak), rawPeakPaint);
    }

    final rawCurve = _buildSmoothPath(rawRmsPoints);
    canvas.drawPath(
      rawCurve,
      Paint()
        ..color = rawColor.withValues(alpha: 0.82)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 3. 处理后波形：PiliNara 高能进度条同款平滑曲线 + 渐变面积填充
    if (enabled && proc.length == raw.length) {
      final procRmsPoints = <Offset>[];
      final procPeakPoints = <Offset>[];
      for (var i = 0; i < proc.length; i++) {
        final x = i * stepX;
        final rmsNorm =
            LoudnessWaveformDsp.linearToNormalizedHeight(proc[i].rms);
        final peakNorm =
            LoudnessWaveformDsp.linearToNormalizedHeight(proc[i].peak);
        procRmsPoints.add(Offset(x, topPad + plotHeight * (1.0 - rmsNorm)));
        procPeakPoints.add(Offset(x, topPad + plotHeight * (1.0 - peakNorm)));
      }

      final procArea = _buildSmoothPath(procRmsPoints)
        ..lineTo(size.width, size.height - bottomPad)
        ..lineTo(0, size.height - bottomPad)
        ..close();

      canvas.drawPath(
        procArea,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              primaryColor.withValues(alpha: 0.34),
              primaryColor.withValues(alpha: 0.04),
            ],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
      );

      final procPeakCurve = _buildSmoothPath(procPeakPoints);
      canvas.drawPath(
        procPeakCurve,
        Paint()
          ..color = primaryColor.withValues(alpha: 0.32)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      final procCurve = _buildSmoothPath(procRmsPoints);
      canvas.drawPath(
        procCurve,
        Paint()
          ..color = primaryColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.85
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // 4. 实时播放游标
    if (playheadProgress != null) {
      final px = playheadProgress! * size.width;
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()
          ..color = primaryColor.withValues(alpha: 0.7)
          ..strokeWidth = 1.1,
      );
    }

    // 5. 微型分贝刻度标注 (-1 dB)
    TextPainter(
      text: TextSpan(
        text: '-1dB',
        style: TextStyle(
          fontSize: 8.5,
          color: labelColor.withValues(alpha: 0.72),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )
      ..layout()
      ..paint(canvas, Offset(2, math.max(0.0, ceilingY - 1)));
  }

  Path _buildSmoothPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      path.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
    }
    return path;
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len <= 0) return;
    final ux = dx / len;
    final uy = dy / len;
    var dist = 0.0;
    while (dist < len) {
      final segEnd = math.min(dist + dash, len);
      canvas.drawLine(
        Offset(start.dx + ux * dist, start.dy + uy * dist),
        Offset(start.dx + ux * segEnd, start.dy + uy * segEnd),
        paint,
      );
      dist += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _LoudnessWaveformPainter oldDelegate) {
    return oldDelegate.comparison != comparison ||
        oldDelegate.enabled != enabled ||
        oldDelegate.isBewlyMode != isBewlyMode ||
        oldDelegate.targetLufs != targetLufs ||
        oldDelegate.playheadProgress != playheadProgress ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.rawColor != rawColor;
  }
}
