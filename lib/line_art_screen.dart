// lib/line_art_screen.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Line Art mode.
///
/// **The concept.** The composition *is* the time. There are two fixed
/// sequences — 24 thick "hour" line slots and 60 thin "minute" line slots —
/// and the picture at time HH:MM is exactly the first HH thick lines plus the
/// first MM thin lines from those sequences. As the minute advances, exactly
/// one new thin line appears. At every hour boundary all 59 thin lines drop
/// away and one more thick line appears. The viewer can literally count
/// thick lines for the hour and thin lines for the minute.
///
/// The slot positions, angles, lengths, thicknesses, and opacities are seeded
/// from constants, so 14:37 today shows the exact same picture as 14:37
/// tomorrow. Scroll back and the previous minute's image is recovered
/// exactly.
///
/// Slots are distributed by a Halton low-discrepancy sequence so they cover
/// the entire screen evenly rather than clustering toward the centre. Most
/// lines stay clearly visible for counting; some near the edges extend off-
/// screen — up to roughly 80 % off — adding scale and drama without
/// undermining countability.
///
/// **Paged interaction.** The swipe IS the transition. The current minute's
/// artwork and the incoming minute's artwork sit one screen apart and slide
/// together with the gesture, using the same spring physics as Time mode.
///
/// **Coherent motion.** A single set of motion parameters — slow rotation
/// and drift — is applied to every visible cell, so during a swipe the
/// adjacent compositions move as one connected scene rather than two
/// competing animations.
class LineArtScreen extends StatefulWidget {
  final DateTime currentTime;
  final MotionController motion;

  /// Called when a swipe settles onto the next/previous minute (+1 / -1).
  final void Function(int direction) onStep;

  const LineArtScreen({
    super.key,
    required this.currentTime,
    required this.motion,
    required this.onStep,
  });

  @override
  State<LineArtScreen> createState() => _LineArtScreenState();
}

// ---------- Shared coherent composition motion -------------------------------
// One subtle set applied to every cell so the scene rotates/drifts as a whole.
const double _kRotPeriodS = 12.0;
const double _kRotAmpRad = 0.00872665; // 0.5° in radians
const double _kRotPhase = 0.7;
const double _kDriftPeriodS = 18.0;
const double _kDriftAmpX = 8.0;
const double _kDriftAmpY = 6.0;
const double _kDriftPhase = 1.2;

/// Halton low-discrepancy sequence sample. With distinct bases per axis it
/// produces well-spread 2-D point sets that cover the canvas evenly without
/// the clumping a random sample would have.
double _halton(int index, int base) {
  double result = 0.0;
  double f = 1.0 / base;
  var i = index;
  while (i > 0) {
    result += (i % base) * f;
    i ~/= base;
    f /= base;
  }
  return result;
}

class _LineArtScreenState extends State<LineArtScreen>
    with TickerProviderStateMixin {
  // --- Time integration ------------------------------------------------------
  late final Ticker _ticker;
  double _elapsedS = 0.0;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  // --- Paged scroll progress -------------------------------------------------
  /// Forward scroll progress in logical px. 0 = current minute centred;
  /// grows as the arm swipes "forward" (up in portrait, right in landscape).
  final ValueNotifier<double> _p = ValueNotifier<double>(0.0);
  late final AnimationController _settle;
  int? _pendingDir;
  bool _selfStep = false;

  // --- Gesture tracking ------------------------------------------------------
  int _lastTick = -1;
  bool _wasDragging = false;

  // --- Layout ----------------------------------------------------------------
  Size _size = Size.zero;
  bool _isLandscape = true;
  double _dim = 1.0; // primary-axis screen dimension
  double _shortestSide = 1.0;

  // --- The two consistent sequences ------------------------------------------
  /// 24 thick line slots; the first `hour` are rendered.
  List<_LineSpec> _hourSequence = const [];
  /// 60 thin line slots; the first `minute` are rendered.
  List<_LineSpec> _minuteSequence = const [];

  @override
  void initState() {
    super.initState();
    _settle = AnimationController.unbounded(vsync: this)
      ..addListener(() => _p.value = _settle.value);
    _ticker = createTicker(_onTick)..start();
    widget.motion.addListener(_onMotion);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.of(context).size;
    final landscape = size.width > size.height;
    if (size != _size || landscape != _isLandscape) {
      _size = size;
      _isLandscape = landscape;
      _dim = landscape ? size.width : size.height;
      _shortestSide = math.min(size.width, size.height);
      _buildSequences();
    }
  }

  @override
  void didUpdateWidget(LineArtScreen old) {
    super.didUpdateWidget(old);
    if (old.motion != widget.motion) {
      old.motion.removeListener(_onMotion);
      widget.motion.addListener(_onMotion);
    }
    if (old.currentTime != widget.currentTime) {
      if (_selfStep) {
        _selfStep = false;
      } else {
        if (_settle.isAnimating) _settle.stop();
        _pendingDir = null;
        _p.value = 0.0;
      }
    }
  }

  @override
  void dispose() {
    widget.motion.removeListener(_onMotion);
    _ticker.dispose();
    _settle.dispose();
    _p.dispose();
    _frame.dispose();
    super.dispose();
  }

  // --- Continuous time integration ------------------------------------------

  void _onTick(Duration elapsed) {
    _elapsedS = elapsed.inMicroseconds / 1e6;
    _frame.value += 1;
  }

  // --- Gesture -> physics (mirrors Time mode) -------------------------------

  double _forward(Offset v) {
    var f = _isLandscape ? v.dx : -v.dy;
    if (kInvertScrollDirection) f = -f;
    return f;
  }

  void _onMotion() {
    final m = widget.motion;
    if (m.isDragging && !_wasDragging) {
      _wasDragging = true;
      if (_settle.isAnimating) {
        _settle.stop();
        _pendingDir = null;
      }
    } else if (m.isDragging && m.updateTick != _lastTick) {
      _lastTick = m.updateTick;
      _p.value += _forward(m.liveDelta);
    } else if (!m.isDragging && _wasDragging) {
      _wasDragging = false;
      _release(_forward(m.velocity));
    }
  }

  void _release(double forwardVelocity) {
    final pos = _p.value;
    final projected = pos + forwardVelocity * 0.25;
    int dir;
    if (projected >= _dim * 0.15) {
      dir = 1;
    } else if (projected <= -_dim * 0.15) {
      dir = -1;
    } else {
      dir = 0;
    }
    final target = dir * _dim;
    _pendingDir = dir;

    final spring =
        SpringDescription(mass: 1.0, stiffness: 220.0, damping: 30.0);
    final sim = SpringSimulation(spring, pos, target, forwardVelocity);

    _settle.animateWith(sim).then((_) {
      final d = _pendingDir;
      _pendingDir = null;
      if (d == null) return;
      if (d != 0) {
        _selfStep = true;
        widget.onStep(d);
      }
      _p.value = 0.0;
    }).catchError((_) {
      _pendingDir = null;
    });
  }

  // --- Sequence building -----------------------------------------------------

  void _buildSequences() {
    if (_size == Size.zero) {
      _hourSequence = const [];
      _minuteSequence = const [];
      return;
    }
    _hourSequence = _buildSequence(thick: true, count: 24);
    _minuteSequence = _buildSequence(thick: false, count: 60);
  }

  /// Build one of the two fixed sequences. Uses a Halton-spread point set for
  /// positions (covers the whole canvas without clumping) and a fixed random
  /// seed for the per-line properties so the same minute always looks the
  /// same.
  List<_LineSpec> _buildSequence({required bool thick, required int count}) {
    // Fixed seeds: identical compositions every run, day-to-day.
    final r = math.Random(thick ? 0xA17CE5 : 0xB117CE);
    final w = _size.width;
    final h = _size.height;
    final shortest = _shortestSide;
    final screenCenter = Offset(w / 2, h / 2);

    // Distinct Halton bases per axis and per sequence so the thick and thin
    // slot sets don't land on top of each other.
    final baseY = thick ? 3 : 5;

    // Slightly stronger jitter for thick (so a few thick lines can reach the
    // edge dramatically) while keeping most well within the screen.
    final jitterMag = thick ? 80.0 : 60.0;

    final lines = <_LineSpec>[];
    for (var i = 0; i < count; i++) {
      // Halton-spread base position across the full canvas.
      final hx = _halton(i + 1, 2);
      final hy = _halton(i + 1, baseY);
      final basePos = Offset(hx * w, hy * h);

      // Jitter to break the Halton regularity. Edge slots can push slightly
      // off-canvas, where long lines naturally produce dramatic 60–80 % off-
      // screen extensions.
      final jx = (r.nextDouble() - 0.5) * jitterMag * 2;
      final jy = (r.nextDouble() - 0.5) * jitterMag * 2;
      final posScreen = basePos + Offset(jx, jy);
      // Composition-local coords: origin at cell centre, so the same data
      // works for any cell (k = -2..+2) in the paged film-strip.
      final pos = posScreen - screenCenter;

      // Angle: orthogonal-biased (architectural feel, no circular cluster).
      final p = r.nextDouble();
      double angle;
      if (p < 0.45) {
        angle = (r.nextDouble() - 0.5) * 0.10; // ~horizontal
      } else if (p < 0.85) {
        angle = math.pi / 2 + (r.nextDouble() - 0.5) * 0.10; // ~vertical
      } else {
        angle = (r.nextBool() ? 1 : -1) * math.pi / 4 +
            (r.nextDouble() - 0.5) * 0.10; // ±45° diagonal
      }

      // Length distribution: wide, mix of short / medium / long. Thick lines
      // stay shorter on average (so each is countable); thin lines have a
      // longer tail that produces dramatic streaks reaching off the screen.
      final lenP = r.nextDouble();
      double length;
      if (thick) {
        if (lenP < 0.50) {
          length = shortest * (0.05 + r.nextDouble() * 0.05); // short
        } else if (lenP < 0.85) {
          length = shortest * (0.10 + r.nextDouble() * 0.10); // medium
        } else {
          length = shortest * (0.22 + r.nextDouble() * 0.18); // long
        }
      } else {
        if (lenP < 0.45) {
          length = shortest * (0.02 + r.nextDouble() * 0.05); // short
        } else if (lenP < 0.75) {
          length = shortest * (0.07 + r.nextDouble() * 0.10); // medium
        } else {
          length = shortest * (0.18 + r.nextDouble() * 0.30); // long
        }
      }
      length = math.max(10.0, length);

      // Thickness and opacity. Thick lines are deliberately bold so the hour
      // count reads at a glance.
      final thickness = thick ? 12 + r.nextDouble() * 10 : 1.0;
      final opacity = thick
          ? 0.90 + r.nextDouble() * 0.10
          : 0.55 + r.nextDouble() * 0.35;

      lines.add(_LineSpec(
        pos: pos,
        angle: angle,
        length: length,
        thickness: thickness,
        opacity: opacity,
      ));
    }

    return lines;
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _LineArtPainter(
          state: this,
          repaint: Listenable.merge([_p, _frame]),
        ),
      ),
    );
  }
}

class _LineSpec {
  /// Position in composition-local coords (origin = cell centre).
  final Offset pos;
  final double angle;
  final double length;
  final double thickness;
  final double opacity;
  const _LineSpec({
    required this.pos,
    required this.angle,
    required this.length,
    required this.thickness,
    required this.opacity,
  });
}

class _LineArtPainter extends CustomPainter {
  final _LineArtScreenState state;
  final Listenable repaint;

  _LineArtPainter({required this.state, required this.repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final p = state._p.value;
    final dim = state._dim;
    final isLandscape = state._isLandscape;
    final elapsed = state._elapsedS;
    final currentTime = state.widget.currentTime;
    final w = size.width;
    final h = size.height;

    // Pure black base.
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square; // rectangular ends per spec

    // Render five cells: current ± 2. Adjacent cells are one screen apart;
    // the swipe is the transition between two complete compositions.
    for (var k = -2; k <= 2; k++) {
      final cellOff = isLandscape
          ? Offset(p - k * dim, 0)
          : Offset(0, k * dim - p);
      final along = isLandscape ? cellOff.dx : cellOff.dy;
      if (along.abs() > dim * 1.1) continue; // cull fully off-screen cells

      final cellTime = currentTime.add(Duration(minutes: k));
      _paintCell(canvas, paint, cellOff, w, h, elapsed,
          cellTime.hour, cellTime.minute);
    }
  }

  void _paintCell(Canvas canvas, Paint paint, Offset cellOff, double w,
      double h, double elapsed, int hour, int minute) {
    canvas.save();
    canvas.translate(cellOff.dx + w / 2, cellOff.dy + h / 2);

    // Shared coherent composition motion: a slow drift and a small rotation.
    final rot = math.sin(2 * math.pi * elapsed / _kRotPeriodS + _kRotPhase) *
        _kRotAmpRad;
    final driftPhase = 2 * math.pi * elapsed / _kDriftPeriodS + _kDriftPhase;
    canvas.translate(
      math.sin(driftPhase) * _kDriftAmpX,
      math.cos(driftPhase) * _kDriftAmpY,
    );
    canvas.rotate(rot);

    // Thin lines first (background), thick lines on top — so the hour count
    // is never visually obscured by minute strokes.
    final minSeq = state._minuteSequence;
    final mCount = math.min(minute, minSeq.length);
    for (var i = 0; i < mCount; i++) {
      _drawLine(canvas, paint, minSeq[i]);
    }

    final hrSeq = state._hourSequence;
    final hCount = math.min(hour, hrSeq.length);
    for (var i = 0; i < hCount; i++) {
      _drawLine(canvas, paint, hrSeq[i]);
    }

    canvas.restore();
  }

  void _drawLine(Canvas canvas, Paint paint, _LineSpec l) {
    paint.strokeWidth = l.thickness;
    paint.color = Colors.white.withOpacity(l.opacity.clamp(0.0, 1.0));
    final half = l.length / 2;
    final dx = math.cos(l.angle) * half;
    final dy = math.sin(l.angle) * half;
    canvas.drawLine(
      Offset(l.pos.dx + dx, l.pos.dy + dy),
      Offset(l.pos.dx - dx, l.pos.dy - dy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _LineArtPainter old) => true;
}