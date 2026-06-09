// lib/celestial_clock.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Celestial Clock mode — a mystical harmonograph sigil that tells the time.
///
/// **The concept.** The image is a luminous, slowly-turning talisman whose form
/// *is* the time. A harmonograph curve (the woven trace of coupled pendulums)
/// is the heart of it, drawn as counter-rotating veils for depth. Its
/// parameters are a deterministic function of HH:MM:
///
///   * the **minute** winds the figure's phase — it precesses by a fixed step
///     each minute and turns once per hour;
///   * the **hour** sets the higher harmonics — the filigree inside the lobes
///     reorganises at every hour boundary.
///
/// So 14:37 always draws the same sigil, and scrolling back recovers it.
///
/// **Reading the time as an orrery.** Two glowing bodies orbit a luminous core
/// on two clean concentric circles: a **minute node** on the larger outer orbit,
/// close to the oval frame (with a luminous arc tracing its progress from the
/// top), and an **hour node** on a smaller inner orbit. You read the time from
/// where the two lights sit.
///
/// **The swipe is celestial.** During a swipe a **comet** — a bright head with
/// a tapering tail — rides a circular orbit, driven 1:1 by the gesture; the
/// release spring whips it around. The instant the swipe is released a `_flare`
/// energy spikes: the brushy veils swell, brighten and swirl, a round
/// **shockwave** pulse expands from the core, then everything settles back to a
/// calm idle. The commit is displacement / velocity-projected, so slow
/// mechanical-arm swipes register and flare reliably.
class CelestialClockScreen extends StatefulWidget {
  final DateTime currentTime;
  final MotionController motion;

  /// Called when a swipe settles onto the next/previous minute (+1 / -1).
  final void Function(int direction) onStep;

  const CelestialClockScreen({
    super.key,
    required this.currentTime,
    required this.motion,
    required this.onStep,
  });

  @override
  State<CelestialClockScreen> createState() => _CelestialClockScreenState();
}

// ---------- Tuning -----------------------------------------------------------

// Harmonograph body — deliberately sparse.
const int _kFigurePoints = 1500; // polyline resolution (lower = lighter weave)
const double _kFigureCycles = 11.0; // turns the trace makes (lower = less dense)

// Veils: scale, rotation factor, base opacity, four-fold? — back to front.
const List<List<double>> _kVeils = [
  [1.00, -0.6, 0.13, 1.0], // main sigil (4-fold mandala)
  [0.60, 1.5, 0.10, 0.0], // inner bright (2-fold)
];

// Release reaction — kept in spirit but deliberately gentle.
const double _kFlareTau = 0.9; // s — how slowly a release flare decays
const double _kFlareAlphaGain = 0.65; // veil brightness surge at release
const double _kFlareScaleGain = 0.05; // veil swell at release
const double _kFlareWind = 1.6; // rad of extra phase swirl at release

// Orrery orbits (both round). The minute rides the LARGER outer orbit, close to
// the oval frame; the hour a smaller inner orbit; the comet rides exactly
// between them. (Minute > hour so the conventional reading holds.)
const double _kMinuteOrbit = 0.92; // outer — close to the large oval line
const double _kHourOrbit = 0.58; // inner — a little out from the centre
const double _kCometOrbit = 0.75; // EXACTLY between hour (0.58) and minute (0.92)

// Comet: on release the asteroid simply keeps moving as it was, then fades out.
const double _kCometSpan = 2 * math.pi * 1.15; // a full swipe sweeps ~1.15 turns
const double _kCometFadeDurS = 0.9; // seconds for the post-release fade-out
const double _kCometMinOmega = 1.2; // rad/s — gentle continuation floor
const double _kCometMaxOmega = 8.0; // rad/s — cap so a fast fling isn't a blur

// Idle life (slow, hypnotic)
const double _kIdleWindRate = 0.045; // rad/s phase shimmer at rest
const double _kVeilTurnRate = 0.018; // rad/s base rotation of the veils
const double _kCorePulseS = 5.5; // core breathing period (s)
const double _kRayCount = 36; // sunburst aura rays
const double _kStarCount = 150;

// Instrument chrome
const double _kFrameInset = 0.055;
const double _kChromeAlpha = 0.34;

// Hourly 3D wireframe emblem — four copies in the corners brand the hour.
const double _kCornerShapeR = 0.12; // corner emblem radius (fraction of the round radius)
const double _kCornerGapT = 0.55; // 0 = hug the oval, 1 = the screen corner
const double _kCornerVerticalNudge = 1.2; // top pair up / bottom pair down, as a fraction of the shape's full size (diameter)

// Corner emblems re-orient to a fresh random pose once the release bloom settles.
const double _kReorientDelayS = 2.0; // extra calm wait before a turn begins
const double _kReorientDurS = 4.0; // seconds for one (slow) turn
const double _kReorientMinTurn = 0.35 * math.pi; // smallest per-axis turn
const double _kReorientMaxTurn = 0.90 * math.pi; // largest per-axis turn
const double _kFlareDoneThreshold = 0.08; // flare counts as "finished" below this

// Idle drift: between turns each emblem rotates very slowly in a random direction.
const double _kIdleDriftMin = 0.012; // rad/s (subtle)
const double _kIdleDriftMax = 0.045; // rad/s

class _CelestialClockScreenState extends State<CelestialClockScreen>
    with TickerProviderStateMixin {
  // --- Frame driver ----------------------------------------------------------
  late final Ticker _ticker;
  double _elapsedS = 0.0;
  double _prevElapsedS = 0.0;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  // --- Release flare (spikes when a swipe lifts, decays) ---------------------
  double _flare = 0.0;

  // --- Hourly emblem (cached 3D solid, rebuilt only when the hour changes) ---
  int _solidIndex = -1;
  _Solid? _solid;

  // Each corner emblem holds an orientation. Between turns it drifts very
  // slowly in its own random direction; once the release bloom has settled it
  // eases over [_kReorientDurS] toward a fresh random pose, then picks a new
  // idle drift. See [_Emblem] for the per-corner state.
  final math.Random _rng = math.Random();
  late final List<_Emblem> _emblems;
  bool _reorienting = false;
  bool _reorientPending = false;
  double _reorientStartS = 0.0;
  double _calmSinceS = -1.0; // when post-release calm began (-1 = not calm yet)

  // --- Comet: after release it keeps moving at its release velocity, fading --
  bool _cometFlying = false;
  double _cometAngle = 0.0; // current head angle (absolute) during the fade
  double _cometVel = 0.0; // angular velocity carried over from the swipe (rad/s)
  double _cometActivity = 0.0; // brightness carried over from the swipe
  double _cometFadeStartS = 0.0;

  // --- Paged scroll progress (logical px along the primary axis) ------------
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
  double _dim = 1.0;

  @override
  void initState() {
    super.initState();
    // Each corner emblem starts at a random pose and a random subtle drift.
    _emblems = List.generate(4, (_) {
      return _Emblem(
        ay: _rng.nextDouble() * 2 * math.pi,
        ax: _rng.nextDouble() * 2 * math.pi,
        roll: _rng.nextDouble() * 2 * math.pi,
      )
        ..velAy = _randDriftVel()
        ..velAx = _randDriftVel()
        ..velRoll = _randDriftVel();
    });
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
    }
  }

  @override
  void didUpdateWidget(CelestialClockScreen old) {
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
    final s = elapsed.inMicroseconds / 1e6;
    final dt = (s - _prevElapsedS).clamp(0.0, 0.05);
    _prevElapsedS = s;
    _elapsedS = s;

    // Decay the release flare back toward calm.
    if (_flare > 0.0005) {
      _flare *= math.exp(-dt / _kFlareTau);
    } else {
      _flare = 0.0;
    }

    // Once the release bloom (flare + settle spring) has finished AND a further
    // [_kReorientDelayS] of calm has elapsed, turn each corner emblem to a fresh
    // random pose over [_kReorientDurS].
    final calm = !widget.motion.isDragging &&
        !_settle.isAnimating &&
        _flare < _kFlareDoneThreshold;
    if (!calm) {
      _calmSinceS = -1.0; // activity resumed — restart the delay
    } else if (_reorientPending) {
      if (_calmSinceS < 0) _calmSinceS = _elapsedS; // mark when calm began
      if (_elapsedS - _calmSinceS >= _kReorientDelayS) {
        _reorientPending = false;
        _calmSinceS = -1.0;
        _beginReorient();
      }
    }
    _updateEmblems(dt);

    // Comet: keep moving at the release velocity until the fade-out completes.
    if (_cometFlying) {
      _cometAngle += _cometVel * dt;
      if ((_elapsedS - _cometFadeStartS) >= _kCometFadeDurS) {
        _cometFlying = false;
      }
    }

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
      _cometFlying = false; // a fresh swipe takes the comet back over
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

  void _release(double forwardVelocity) {    final pos = _p.value;
    final projected = pos + forwardVelocity * 0.25; // 0.25 s velocity lookahead
    int dir;
    if (projected >= _dim * 0.15) {
      dir = 1;
    } else if (projected <= -_dim * 0.15) {
      dir = -1;
    } else {
      dir = 0;
    }

    // Flare: a full burst on a committed step (any speed — good for the slow
    // arm), a partial burst for a near-miss that snaps back.
    if (dir != 0) {
      _flare = 1.0;
    } else {
      final partial = (pos.abs() / _dim).clamp(0.0, 0.6);
      if (partial > _flare) _flare = partial.toDouble();
    }

    // Comet: instead of vanishing on release, let it carry on at the velocity
    // it had and simply fade out — no loop-closing, no flash.
    final double fracR = (pos / _dim).clamp(-1.0, 1.0).toDouble();
    if (fracR.abs() >= 0.02) {
      final cometStart =
          -math.pi / 2 + (widget.currentTime.minute / 60.0) * 2 * math.pi;
      _cometAngle = cometStart + fracR * _kCometSpan; // current head at release
      // Angular velocity at release = (primary-axis velocity / dim) × span.
      final omega = (forwardVelocity / _dim) * _kCometSpan;
      final sign = omega != 0 ? omega.sign : (fracR >= 0 ? 1.0 : -1.0);
      _cometVel =
          sign * omega.abs().clamp(_kCometMinOmega, _kCometMaxOmega).toDouble();
      _cometActivity = (fracR.abs() * 1.5).clamp(0.0, 1.0).toDouble();
      _cometFadeStartS = _elapsedS;
      _cometFlying = true;
    } else {
      _cometFlying = false;
    }

    final target = dir * _dim;
    _pendingDir = dir;
    // Schedule a corner re-orientation; it fires once the bloom has settled.
    _reorientPending = true;

    final spring = SpringDescription(mass: 1.0, stiffness: 220.0, damping: 30.0);
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

  /// Advances every emblem one frame. While turning, each eases from->to with
  /// a decelerating curve; otherwise it drifts slowly in its idle direction.
  void _updateEmblems(double dt) {
    if (_reorienting) {
      final p =
          ((_elapsedS - _reorientStartS) / _kReorientDurS).clamp(0.0, 1.0);
      // Ease-in-out (cosine S-curve): the turn accelerates smoothly from rest,
      // peaks mid-way, then decelerates back to rest — both ramps present.
      final e = 0.5 - 0.5 * math.cos(p * math.pi);
      for (final m in _emblems) {
        m.ay = m.fromAy + (m.toAy - m.fromAy) * e;
        m.ax = m.fromAx + (m.toAx - m.fromAx) * e;
        m.roll = m.fromRoll + (m.toRoll - m.fromRoll) * e;
      }
      if (p >= 1.0) {
        _reorienting = false;
        // Land exactly on target and choose a fresh idle drift direction.
        for (final m in _emblems) {
          m.ay = m.toAy;
          m.ax = m.toAx;
          m.roll = m.toRoll;
          m.velAy = _randDriftVel();
          m.velAx = _randDriftVel();
          m.velRoll = _randDriftVel();
        }
      }
    } else {
      // Idle: a slow, subtle rotation in each emblem's own random direction.
      for (final m in _emblems) {
        m.ay += m.velAy * dt;
        m.ax += m.velAx * dt;
        m.roll += m.velRoll * dt;
      }
    }
  }

  /// Turn all four emblems toward fresh random poses, starting from wherever
  /// they currently sit (so an interrupted drift/turn never jumps).
  void _beginReorient() {
    for (final m in _emblems) {
      m.fromAy = m.ay;
      m.fromAx = m.ax;
      m.fromRoll = m.roll;
      m.toAy = m.ay + _randTurn();
      m.toAx = m.ax + _randTurn();
      m.toRoll = m.roll + _randTurn() * 0.7; // a touch less roll
    }
    _reorientStartS = _elapsedS;
    _reorienting = true;
  }

  /// A signed random turn within the configured range (radians).
  double _randTurn() {
    final mag = _kReorientMinTurn +
        _rng.nextDouble() * (_kReorientMaxTurn - _kReorientMinTurn);
    return (_rng.nextBool() ? 1.0 : -1.0) * mag;
  }

  /// A signed random idle angular velocity (rad/s) within the subtle range.
  double _randDriftVel() {
    final mag =
        _kIdleDriftMin + _rng.nextDouble() * (_kIdleDriftMax - _kIdleDriftMin);
    return (_rng.nextBool() ? 1.0 : -1.0) * mag;
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _SigilPainter(
          state: this,
          repaint: Listenable.merge([_p, _frame]),
        ),
      ),
    );
  }
}

/// Harmonograph parameters for a real-valued minute-of-day. Deterministic in
/// time; [drift] is a slow render-time shimmer (plus a transient release swirl)
/// that does not change the reading.
class _FigureParams {
  final double f1, f2, f3, f4, f5, f6;
  final double p1, p2, p3, p4, p5, p6;
  const _FigureParams(this.f1, this.f2, this.f3, this.f4, this.f5, this.f6,
      this.p1, this.p2, this.p3, this.p4, this.p5, this.p6);

  factory _FigureParams.fromMinutes(double mm, double drift) {
    final hr = mm / 60.0; // 0..24
    const f1 = 1.0, f2 = 2.0; // vertical figure-eight -> two lobes
    final f3 = 3.0 + hr * 0.5; // secondary harmonics grow across the day
    final f4 = 5.0 + hr * 0.5 + 0.137; // irrational-ish -> never closes (fills)
    final f5 = 7.0 + hr; // tertiary filigree, reorganises per hour
    final f6 = 9.0 + hr + 0.071;
    final pw = hr * 2 * math.pi; // winding: 2 pi per hour
    return _FigureParams(
      f1, f2, f3, f4, f5, f6, //
      drift, // p1
      pw + drift * 0.7, // p2
      pw * 0.5 + 1.1 + drift * 0.5, // p3
      pw * 0.5 + 0.3 + drift * 0.5, // p4
      pw * 0.33 + 0.9 + drift * 0.3, // p5
      pw * 0.33 + 2.1 + drift * 0.3, // p6
    );
  }
}

class _SigilPainter extends CustomPainter {
  final _CelestialClockScreenState state;
  final Listenable repaint;

  _SigilPainter({required this.state, required this.repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final cx = w / 2, cy = h / 2;
    final elapsed = state._elapsedS;
    final flare = state._flare;

    // Void.
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    // Displayed time = base minute + drag progress (0..1 per minute).
    final base = state.widget.currentTime.hour * 60 +
        state.widget.currentTime.minute.toDouble();
    final frac = (state._p.value / state._dim).clamp(-1.0, 1.0);
    final mm = base + frac;
    final hourF = (mm / 60.0) % 24.0;
    final minute = mm % 60.0;

    final rx = (w / 2) * (1 - _kFrameInset * 2) * 0.96;
    final ry = (h / 2) * (1 - _kFrameInset * 2) * 0.96;
    final rMin = math.min(rx, ry); // base radius for the round orbits
    final turn = elapsed * _kVeilTurnRate; // slow continuous mandala rotation

    // The comet belongs to the *scroll* only. While the release spring settles,
    // the gesture is no longer dragging, so the comet switches off and can't
    // linger as a blob.
    final dragging = state.widget.motion.isDragging;

    // The comet now launches from the current minute angle (where the minute
    // light sits), not from 12 o'clock.
    final cometStart =
        -math.pi / 2 + (state.widget.currentTime.minute / 60.0) * 2 * math.pi;

    // --- Hourly emblem: pick the solid for this hour, and its visibility ------
    // It fades out through minute 59 and back in over minute 0, so the shape
    // swap at the hour boundary happens while invisible (no pop).
    final hour24 = (mm / 60.0).floor() % 24;
    final solidIdx = _shapeIndexForHour(hour24);
    if (solidIdx != state._solidIndex || state._solid == null) {
      state._solidIndex = solidIdx;
      state._solid = _buildSolid(solidIdx);
    }
    double emblemVis;
    if (minute < 1.0) {
      emblemVis = minute; // fade in over the first minute of the hour
    } else if (minute >= 59.0) {
      emblemVis = 60.0 - minute; // fade out over the last minute
    } else {
      emblemVis = 1.0;
    }
    emblemVis = emblemVis.clamp(0.0, 1.0);

    _paintStarfield(canvas, w, h, elapsed);
    _paintVignette(canvas, cx, cy, w, h);
    _paintAura(canvas, cx, cy, rx, ry, elapsed);
    _paintFrame(canvas, cx, cy, rx, ry, elapsed);
    _paintGlyphRing(canvas, cx, cy, rx, ry, elapsed);
    _paintVeils(canvas, cx, cy, rx, ry, mm, elapsed, turn, flare);
    _paintEye(canvas, cx, cy, rx, ry, elapsed, turn);
    _paintRays(canvas, cx, cy, rx, ry, elapsed);
    _paintComet(canvas, cx, cy, rMin, frac, dragging, cometStart); // continues + fades
    _paintShockwave(canvas, cx, cy, rMin, flare); // round release pulse
    _paintCore(canvas, cx, cy, rx, ry, elapsed, flare);
    _paintOrrery(canvas, cx, cy, rMin, hourF, minute, elapsed);
    // Four hourly emblems nestled in the diagonal gaps between the oval and the
    // screen corners; each re-aims to a new random pose after a release settles.
    _paintCornerEmblems(
        canvas, cx, cy, w, h, rx, ry, rMin, state._solid!, emblemVis);
  }

  // --- Layered harmonograph veils (the soul) — react to release --------------

  void _paintVeils(Canvas canvas, double cx, double cy, double rx, double ry,
      double mm, double elapsed, double turn, double flare) {
    // A transient phase swirl on release, on top of the slow idle shimmer.
    final drift = elapsed * _kIdleWindRate + flare * _kFlareWind;
    final fp = _FigureParams.fromMinutes(mm, drift);

    // Build the base curve once (centred, in screen units via ax/ay).
    final ax = rx * 0.74, ay = ry * 0.92;
    final hx = ax * 0.34, hy = ay * 0.34; // secondary
    final gx = ax * 0.16, gy = ay * 0.16; // tertiary
    final path = Path();
    final sMax = _kFigureCycles * 2 * math.pi;
    for (var i = 0; i <= _kFigurePoints; i++) {
      final s = i / _kFigurePoints * sMax;
      final x = ax * math.cos(fp.f1 * s + fp.p1) +
          hx * math.cos(fp.f3 * s + fp.p3) +
          gx * math.cos(fp.f5 * s + fp.p5);
      final y = ay * math.sin(fp.f2 * s + fp.p2) +
          hy * math.sin(fp.f4 * s + fp.p4) +
          gy * math.sin(fp.f6 * s + fp.p6);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    for (final v in _kVeils) {
      final scale = v[0] * (1 + flare * _kFlareScaleGain); // swell on release
      final rotMul = v[1];
      final alpha = (v[2] * (1 + flare * _kFlareAlphaGain)).clamp(0.0, 1.0);
      final fourFold = v[3] > 0.5;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (1.0 + flare * 0.3) / scale // slightly heavier on release
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        ..blendMode = BlendMode.plus
        ..color = Colors.white.withValues(alpha: alpha);

      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(turn * rotMul);
      canvas.scale(scale);
      _drawMirrored(canvas, path, paint, fourFold);
      canvas.restore();
    }
  }

  /// Draws [path] plus its mirrors for clean symmetry. Vertical mirror always
  /// (the two lobes); the main veil also mirrors horizontally for a 4-fold
  /// mandala.
  void _drawMirrored(Canvas canvas, Path path, Paint paint, bool fourFold) {
    canvas.drawPath(path, paint);
    canvas.save();
    canvas.scale(1, -1);
    canvas.drawPath(path, paint);
    canvas.restore();
    if (fourFold) {
      canvas.save();
      canvas.scale(-1, 1);
      canvas.drawPath(path, paint);
      canvas.restore();
      canvas.save();
      canvas.scale(-1, -1);
      canvas.drawPath(path, paint);
      canvas.restore();
    }
  }

  // --- Celestial comet (present ONLY while actively scrolling) ---------------

  void _paintComet(Canvas canvas, double cx, double cy, double rMin, double frac,
      bool dragging, double startAngle) {
    final orbitR = rMin * _kCometOrbit; // circular orbit, between the two rings
    final headR = rMin * 0.020;

    // Resolve the comet's current state:
    //  • during a swipe it tracks the gesture live;
    //  • after release it keeps moving at the velocity it had and fades out.
    double? headAngle;
    var dir = 1.0;
    var activity = 0.0;

    if (dragging) {
      activity = (frac.abs() * 1.5).clamp(0.0, 1.0).toDouble();
      if (activity >= 0.02) {
        dir = frac >= 0 ? 1.0 : -1.0;
        headAngle = startAngle + frac * _kCometSpan;
      }
    } else if (state._cometFlying) {
      dir = state._cometVel >= 0 ? 1.0 : -1.0;
      headAngle = state._cometAngle;
      // Simple linear fade — no effect, just dimming out.
      final p = ((state._elapsedS - state._cometFadeStartS) / _kCometFadeDurS)
          .clamp(0.0, 1.0);
      activity = state._cometActivity * (1.0 - p);
    }

    if (headAngle == null || activity <= 0.0) return;

    // Tail: trailing glow dots behind the head along the orbit.
    const n = 18;
    const step = 0.06; // radians between tail samples
    final tailPaint = Paint()..blendMode = BlendMode.plus;
    for (var i = n - 1; i >= 1; i--) {
      final tt = i / n;
      final ang = headAngle - dir * step * i;
      final c = Offset(cx + orbitR * math.cos(ang), cy + orbitR * math.sin(ang));
      final a = activity * (1 - tt) * (1 - tt) * 0.5;
      final r = headR * (0.4 + (1 - tt) * 1.1);
      tailPaint.shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: a),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: r * 3));
      canvas.drawCircle(c, r * 3, tailPaint);
    }

    // Head: a slender glowing body (kept modest so it never reads as a blob).
    final head = Offset(
        cx + orbitR * math.cos(headAngle), cy + orbitR * math.sin(headAngle));
    _glowNode(canvas, head, headR * (0.6 + activity * 0.5), activity);
  }

  // --- Round shockwave pulse on release --------------------------------------

  void _paintShockwave(
      Canvas canvas, double cx, double cy, double rMin, double flare) {
    if (flare < 0.02) return;
    final maxR = rMin * 1.05;
    final r = (1 - flare) * maxR; // expands outward as the flare decays
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6 + flare * 1.0
      ..isAntiAlias = true
      ..blendMode = BlendMode.plus
      ..color = Colors.white.withValues(alpha: flare * 0.22);
    canvas.drawCircle(Offset(cx, cy), r, paint);
  }

  // --- Concentric "eye" + vesica around the core -----------------------------

  void _paintEye(Canvas canvas, double cx, double cy, double rx, double ry,
      double elapsed, double turn) {
    final breath = 1.0 + 0.06 * math.sin(2 * math.pi * elapsed / 6.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..isAntiAlias = true
      ..blendMode = BlendMode.plus;

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(turn * 0.5);
    for (var k = 1; k <= 5; k++) {
      final t = k / 5.0;
      final er = rx * 0.30 * t * breath;
      final eh = ry * 0.34 * t * breath;
      paint.color = Colors.white.withValues(alpha: 0.09 + 0.06 * (1 - t));
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: er * 2, height: eh * 2),
        paint,
      );
    }
    // Vesica: two circles offset vertically, their overlap forming a lens.
    final vr = math.min(rx, ry) * 0.22 * breath;
    paint.color = Colors.white.withValues(alpha: 0.12);
    canvas.drawCircle(Offset(0, -vr * 0.5), vr, paint);
    canvas.drawCircle(Offset(0, vr * 0.5), vr, paint);
    canvas.restore();
  }

  // --- Sunburst aura ---------------------------------------------------------

  void _paintRays(
      Canvas canvas, double cx, double cy, double rx, double ry, double elapsed) {
    final spin = elapsed * 0.03;
    final pulse = 0.5 + 0.5 * math.sin(2 * math.pi * elapsed / 7.0);
    final inner = math.min(rx, ry) * 0.20;
    final outer = math.min(rx, ry) * (0.46 + 0.06 * pulse);
    final paint = Paint()
      ..strokeWidth = 1.0
      ..isAntiAlias = true
      ..blendMode = BlendMode.plus
      ..color = Colors.white.withValues(alpha: 0.05);

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(spin);
    final n = _kRayCount.toInt();
    for (var i = 0; i < n; i++) {
      final a = i / n * 2 * math.pi;
      final ca = math.cos(a), sa = math.sin(a);
      canvas.drawLine(
        Offset(ca * inner, sa * inner),
        Offset(ca * outer, sa * outer),
        paint,
      );
    }
    canvas.restore();
  }

  // --- Luminous core (loved — kept; small extra flicker on flare) ------------

  void _paintCore(Canvas canvas, double cx, double cy, double rx, double ry,
      double elapsed, double flare) {
    final pulse = 0.5 + 0.5 * math.sin(2 * math.pi * elapsed / _kCorePulseS);
    final center = Offset(cx, cy);
    final base = math.min(rx, ry);

    // Wide soft halo (brightens slightly with a release flare).
    final halo = Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: (0.30 + flare * 0.12).clamp(0.0, 1.0)),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: base * 0.34));
    canvas.drawCircle(center, base * 0.34, halo);

    // Tight bright glow.
    final glowR = base * (0.13 + 0.03 * pulse);
    final glow = Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.95),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: glowR));
    canvas.drawCircle(center, glowR, glow);

    // Nucleus.
    canvas.drawCircle(center, base * 0.04, Paint()..color = Colors.white);
  }

  // --- Instrument frame: double ellipse, outer dashed ------------------------

  void _paintFrame(Canvas canvas, double cx, double cy, double rx, double ry,
      double elapsed) {
    final rect =
        Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2);
    final solid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..isAntiAlias = true
      ..color = Colors.white.withValues(alpha: _kChromeAlpha);
    canvas.drawOval(rect, solid);

    final outer = Rect.fromCenter(
        center: Offset(cx, cy), width: rx * 2.14, height: ry * 2.10);
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..isAntiAlias = true
      ..color = Colors.white.withValues(alpha: _kChromeAlpha * 0.6);
    const nDashes = 96;
    final phase = elapsed * 0.04;
    final seg = 2 * math.pi / nDashes;
    final dashPath = Path();
    for (var i = 0; i < nDashes; i++) {
      dashPath.addArc(outer, phase + i * seg, seg * 0.5);
    }
    canvas.drawPath(dashPath, dash);
  }

  // --- Arcane ring of abstract glyph-marks -----------------------------------

  void _paintGlyphRing(Canvas canvas, double cx, double cy, double rx, double ry,
      double elapsed) {
    const n = 48;
    final spin = elapsed * 0.02; // slow drift
    final paint = Paint()
      ..strokeWidth = 1.0
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..blendMode = BlendMode.plus
      ..color = Colors.white.withValues(alpha: 0.30);

    final grx = rx * 1.06, gry = ry * 1.04;
    for (var i = 0; i < n; i++) {
      final a = spin + i / n * 2 * math.pi;
      final ca = math.cos(a), sa = math.sin(a);
      final px = cx + grx * ca, py = cy + gry * sa;
      final kind = _hash(i) % 4;
      final big = i % 4 == 0; // accent every 4th mark
      final len = big ? 9.0 : 5.0;
      switch (kind) {
        case 0: // radial tick
          canvas.drawLine(
            Offset(cx + (grx - len) * ca, cy + (gry - len) * sa),
            Offset(px, py),
            paint,
          );
          break;
        case 1: // tiny ring
          canvas.drawCircle(Offset(px, py), big ? 2.6 : 1.8, paint);
          break;
        case 2: // dot
          canvas.drawCircle(
            Offset(px, py),
            big ? 2.0 : 1.2,
            Paint()
              ..blendMode = BlendMode.plus
              ..color = Colors.white.withValues(alpha: 0.4),
          );
          break;
        default: // chevron (two short barbs)
          final perp = a + math.pi / 2;
          final cpx = math.cos(perp), cpy = math.sin(perp);
          canvas.drawLine(
              Offset(px, py),
              Offset(px - len * ca + len * 0.6 * cpx,
                  py - len * sa + len * 0.6 * cpy),
              paint);
          canvas.drawLine(
              Offset(px, py),
              Offset(px - len * ca - len * 0.6 * cpx,
                  py - len * sa - len * 0.6 * cpy),
              paint);
      }
    }
  }

  // --- Orrery: two glowing nodes on concentric ROUND orbits tell the time ----

  void _paintOrrery(Canvas canvas, double cx, double cy, double rMin,
      double hourF, double minute, double elapsed) {
    final twk = 0.85 + 0.15 * math.sin(2 * math.pi * elapsed / 2.5);

    // Two clean concentric circles: minute on the larger outer orbit (near the
    // oval), hour on a smaller inner orbit — they never cross.
    final rMinute = rMin * _kMinuteOrbit;
    final rHour = rMin * _kHourOrbit;

    // Minute progress arc — on the outer circle, sweeping from the top.
    final ma = -math.pi / 2 + minute / 60 * 2 * math.pi;
    final arcRect = Rect.fromCircle(center: Offset(cx, cy), radius: rMinute);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..blendMode = BlendMode.plus
      ..color = Colors.white.withValues(alpha: 0.28);
    final sweep = (minute / 60) * 2 * math.pi;
    canvas.drawArc(arcRect, -math.pi / 2, sweep, false, arc);

    // Faint whispers from the core toward each node (a hint of hands).
    final whisper = Paint()
      ..strokeWidth = 1.0
      ..isAntiAlias = true
      ..blendMode = BlendMode.plus
      ..color = Colors.white.withValues(alpha: 0.10);
    final ha = -math.pi / 2 + (hourF % 12) / 12 * 2 * math.pi;
    final hourNode =
        Offset(cx + rHour * math.cos(ha), cy + rHour * math.sin(ha));
    final minNode =
        Offset(cx + rMinute * math.cos(ma), cy + rMinute * math.sin(ma));
    canvas.drawLine(Offset(cx, cy), hourNode, whisper);
    canvas.drawLine(Offset(cx, cy), minNode, whisper);

    _glowNode(canvas, minNode, 4.2 * twk, 0.95);
    _glowNode(canvas, hourNode, 5.2 * twk, 1.0);
  }

  void _glowNode(Canvas canvas, Offset c, double r, double alpha) {
    final glow = Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: (0.9 * alpha).clamp(0.0, 1.0)),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: r * 3));
    canvas.drawCircle(c, r * 3, glow);
    canvas.drawCircle(c, r * 0.5, Paint()..color = Colors.white);
  }

  // --- Faint twinkling starfield ---------------------------------------------

  void _paintStarfield(Canvas canvas, double w, double h, double elapsed) {
    final n = _kStarCount.toInt();
    final paint = Paint()..blendMode = BlendMode.plus;
    for (var i = 0; i < n; i++) {
      // Deterministic positions from a hash (stable every frame).
      final hx = (_hash(i * 2 + 1) % 10000) / 10000.0;
      final hy = (_hash(i * 2 + 2) % 10000) / 10000.0;
      final px = hx * w, py = hy * h;
      final tw = 0.5 + 0.5 * math.sin(elapsed * (0.6 + (i % 7) * 0.15) + i);
      final a = (0.05 + 0.18 * tw) * (i % 5 == 0 ? 1.4 : 1.0);
      paint.color = Colors.white.withValues(alpha: a.clamp(0.0, 0.5));
      canvas.drawCircle(Offset(px, py), (i % 9 == 0) ? 1.4 : 0.8, paint);
    }
  }

  // --- Vignette: deepen the void toward the edges ----------------------------

  void _paintVignette(Canvas canvas, double cx, double cy, double w, double h) {
    final radius = math.sqrt(cx * cx + cy * cy);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.black.withValues(alpha: 0.0),
          Colors.black.withValues(alpha: 0.55),
        ],
        stops: const [0.6, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: radius));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), paint);
  }

  // --- Soft halo behind the figure -------------------------------------------

  void _paintAura(Canvas canvas, double cx, double cy, double rx, double ry,
      double elapsed) {
    final pulse = 0.5 + 0.5 * math.sin(2 * math.pi * elapsed / 9.0);
    final r = math.max(rx, ry) * (0.85 + 0.05 * pulse);
    final paint = Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.045),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    canvas.drawCircle(Offset(cx, cy), r, paint);
  }

  // --- Four corner sigils ----------------------------------------------------

  // --- Four corner emblems (replace the old circle-and-cross sigils) ---------
  // The current hour's solid is drawn in each diagonal gap between the oval and
  // a screen corner. Each centre sits *exactly* on the centre->corner diagonal
  // (so it adapts to any aspect ratio), and each emblem holds an orientation
  // that re-aims to a new random pose after every release.
  void _paintCornerEmblems(
      Canvas canvas,
      double cx,
      double cy,
      double w,
      double h,
      double rx,
      double ry,
      double rMin,
      _Solid solid,
      double vis) {
    if (vis <= 0.001) return;
    final r = rMin * _kCornerShapeR;
    final center = Offset(cx, cy);
    // On-screen edge margin. Orthographic, so the farthest a vertex can reach
    // from the centre is the solid's circumradius (~1.5× r at most).
    final em = r * 1.5 + math.min(w, h) * 0.012;

    final corners = <Offset>[
      const Offset(0, 0), // top-left
      Offset(w, 0), // top-right
      Offset(0, h), // bottom-left
      Offset(w, h), // bottom-right
    ];

    for (var i = 0; i < 4; i++) {
      final corner = corners[i];
      var dir = corner - center;
      final len = dir.distance;
      if (len < 1e-3) continue;
      dir = dir / len;

      // Distance from centre to the oval boundary along this exact diagonal.
      final nx = dir.dx / rx, ny = dir.dy / ry;
      final sEll = 1.0 / math.sqrt(nx * nx + ny * ny);

      // Furthest on-diagonal distance that still keeps the shape on screen.
      // We clamp the *scalar* distance (never the x/y independently) so the
      // centre stays precisely on the diagonal.
      var sMax = len;
      if (dir.dx.abs() > 1e-6) {
        final lim = dir.dx > 0 ? (w - em - cx) / dir.dx : (em - cx) / dir.dx;
        sMax = math.min(sMax, lim);
      }
      if (dir.dy.abs() > 1e-6) {
        final lim = dir.dy > 0 ? (h - em - cy) / dir.dy : (em - cy) / dir.dy;
        sMax = math.min(sMax, lim);
      }

      final sInner = sEll + r * 1.5; // clear of the oval line
      final sOuter = math.max(sInner, sMax);
      final s = sInner + (sOuter - sInner) * _kCornerGapT;

      // On-diagonal anchor, then a deliberate vertical nudge: the top pair move
      // up and the bottom pair move down by a fixed fraction of the shape's
      // size, so they sit better in the corners. Only y shifts (x stays on the
      // diagonal), and because the offset scales with r it adapts to any screen.
      final baseX = cx + dir.dx * s;
      final baseY = cy + dir.dy * s;
      final nudge = (2 * r) * _kCornerVerticalNudge; // fraction of the diameter
      final nudgedY = (baseY + (corner.dy < cy ? -nudge : nudge))
          .clamp(em, h - em) // never let the nudge clip an edge
          .toDouble();
      final pos = Offset(baseX, nudgedY);

      final m = state._emblems[i]; // current orientation (idle drift or turn)
      _paintShape(canvas, pos, r, solid, m.ay, m.ax, m.roll, vis);
    }
  }

  // --- Hourly 3D wireframe emblem --------------------------------------------
  // A small tumbling wireframe solid, drawn orthographically (so its visual
  // centre is always the anchor point). Front edges read brighter than back
  // edges for a sense of depth.

  void _paintShape(Canvas canvas, Offset center, double scale, _Solid solid,
      double ay, double ax, double roll, double vis) {
    if (vis <= 0.001 || scale <= 0) return;

    final cyy = math.cos(ay), syy = math.sin(ay);
    final cxx = math.cos(ax), sxx = math.sin(ax);
    final cr = math.cos(roll), sr = math.sin(roll); // in-plane roll

    final n = solid.v.length;
    final px = List<double>.filled(n, 0.0);
    final py = List<double>.filled(n, 0.0);
    final pz = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      final p = solid.v[i];
      // Rotate about Y, then X.
      final x1 = p.x * cyy + p.z * syy;
      final z1 = -p.x * syy + p.z * cyy;
      final y1 = p.y;
      final y2 = y1 * cxx - z1 * sxx;
      final z2 = y1 * sxx + z1 * cxx;
      final x2 = x1;
      // In-plane roll (around the view axis) — gives each corner a distinct tilt.
      final xr = x2 * cr - y2 * sr;
      final yr = x2 * sr + y2 * cr;
      // Orthographic projection: x/y map straight through with no depth scaling.
      // Because this is linear and the solids are centred at the origin, the
      // projected centroid always coincides with `center`, so the emblem's
      // visual centre stays exactly on the diagonal at every rotation.
      // (z2 is kept only as a depth cue for per-edge brightness, below.)
      px[i] = center.dx + xr * scale;
      py[i] = center.dy + yr * scale;
      pz[i] = z2;
    }

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..blendMode = BlendMode.plus;

    final e = solid.e;
    for (var k = 0; k < e.length; k += 2) {
      final a = e[k], b = e[k + 1];
      final depth = (pz[a] + pz[b]) * 0.5; // ~[-1,1]
      final d = (depth + 1.3) / 2.6; // 0 (back) .. 1 (front)
      final alpha = (vis * (0.16 + 0.6 * d)).clamp(0.0, 1.0);
      paint.color = Colors.white.withValues(alpha: alpha);
      canvas.drawLine(Offset(px[a], py[a]), Offset(px[b], py[b]), paint);
    }
  }

  /// Small deterministic integer hash for stable pseudo-random layout.
  int _hash(int n) {
    var h = (n * 2654435761) & 0x7FFFFFFF;
    h ^= h >> 13;
    h = (h * 1274126177) & 0x7FFFFFFF;
    h ^= h >> 16;
    return h & 0x7FFFFFFF;
  }

  @override
  bool shouldRepaint(covariant _SigilPainter old) => true;
}

// ============================================================================
// Hourly emblem geometry — a tiny wireframe 3D toolkit.
// ============================================================================

/// A point in the emblem's local 3D space (roughly unit-scale, centred at 0).
class _P3 {
  final double x, y, z;
  const _P3(this.x, this.y, this.z);
}

/// Per-corner emblem orientation state. `ay/ax/roll` is what's drawn this
/// frame; `from*/to*` are the endpoints of an in-progress turn; `vel*` is the
/// idle drift (rad/s) used between turns.
class _Emblem {
  double ay, ax, roll;
  double fromAy = 0, fromAx = 0, fromRoll = 0;
  double toAy = 0, toAx = 0, toRoll = 0;
  double velAy = 0, velAx = 0, velRoll = 0;
  _Emblem({required this.ay, required this.ax, required this.roll});
}

/// A wireframe solid: vertices plus a flat list of edge index pairs
/// (e[2k], e[2k+1]).
class _Solid {
  final List<_P3> v;
  final List<int> e;
  const _Solid(this.v, this.e);
}

/// Maps a 24-hour value to a shape index 0..12.
///   * 0  (midnight)  -> 0   (sphere)
///   * 1..12          -> 1..12 (noon -> 12, the dodecahedron)
///   * 13..23 (PM)    -> 1..11 (reuse the 12-hour sequence)
int _shapeIndexForHour(int hour24) {
  if (hour24 <= 0) return 0;
  if (hour24 <= 12) return hour24;
  return hour24 - 12;
}

/// Builds the wireframe solid for a shape index. The geometry is static, so the
/// caller caches the result and only rebuilds when the hour (index) changes.
_Solid _buildSolid(int index) {
  switch (index) {
    case 1:
      return _cone(20, 8); // 1
    case 2:
      return _cylinder(20, 6); // 2
    case 3:
      return _prism(3); // 3 — triangular prism
    case 4:
      return _tetrahedron(); // 4
    case 5:
      return _pyramid(4); // 5 — square pyramid
    case 6:
      return _cube(); // 6
    case 7:
      return _prism(5); // 7 — pentagonal prism
    case 8:
      return _octahedron(); // 8
    case 9:
      return _pyramid(8); // 9 — octagonal pyramid
    case 10:
      return _bipyramid(5); // 10 — pentagonal bipyramid
    case 11:
      return _pyramid(10); // 11 — decagonal pyramid
    case 12:
      return _dodecahedron(); // 12 (noon)
    case 0:
    default:
      return _sphere(); // 0 (midnight)
  }
}

// --- Parametric n-gon families ----------------------------------------------

_Solid _prism(int n) {
  final v = <_P3>[];
  final e = <int>[];
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    v.add(_P3(math.cos(a), math.sin(a), 1.0)); // top ring     0..n-1
  }
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    v.add(_P3(math.cos(a), math.sin(a), -1.0)); // bottom ring  n..2n-1
  }
  for (var i = 0; i < n; i++) {
    e..add(i)..add((i + 1) % n); // top polygon
    e..add(n + i)..add(n + (i + 1) % n); // bottom polygon
    e..add(i)..add(n + i); // verticals
  }
  return _Solid(v, e);
}

_Solid _pyramid(int n) {
  final v = <_P3>[];
  final e = <int>[];
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    v.add(_P3(math.cos(a), math.sin(a), -0.8)); // base ring  0..n-1
  }
  v.add(const _P3(0, 0, 1.2)); // apex  index n
  for (var i = 0; i < n; i++) {
    e..add(i)..add((i + 1) % n); // base polygon
    e..add(i)..add(n); // slant edges
  }
  return _Solid(v, e);
}

_Solid _bipyramid(int n) {
  final v = <_P3>[];
  final e = <int>[];
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    v.add(_P3(math.cos(a), math.sin(a), 0.0)); // equator ring  0..n-1
  }
  v.add(const _P3(0, 0, 1.3)); // top apex     index n
  v.add(const _P3(0, 0, -1.3)); // bottom apex  index n+1
  for (var i = 0; i < n; i++) {
    e..add(i)..add((i + 1) % n);
    e..add(i)..add(n);
    e..add(i)..add(n + 1);
  }
  return _Solid(v, e);
}

_Solid _cone(int n, int slants) {
  final v = <_P3>[];
  final e = <int>[];
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    v.add(_P3(math.cos(a), math.sin(a), -0.9)); // base circle  0..n-1
  }
  v.add(const _P3(0, 0, 1.1)); // apex  index n
  for (var i = 0; i < n; i++) {
    e..add(i)..add((i + 1) % n); // base circle
  }
  final stepc = math.max(1, n ~/ slants);
  for (var i = 0; i < n; i += stepc) {
    e..add(i)..add(n); // a few slant lines
  }
  return _Solid(v, e);
}

_Solid _cylinder(int n, int verticals) {
  final v = <_P3>[];
  final e = <int>[];
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    v.add(_P3(math.cos(a), math.sin(a), 1.0)); // top circle     0..n-1
  }
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    v.add(_P3(math.cos(a), math.sin(a), -1.0)); // bottom circle  n..2n-1
  }
  for (var i = 0; i < n; i++) {
    e..add(i)..add((i + 1) % n);
    e..add(n + i)..add(n + (i + 1) % n);
  }
  final stepc = math.max(1, n ~/ verticals);
  for (var i = 0; i < n; i += stepc) {
    e..add(i)..add(n + i); // a few verticals
  }
  return _Solid(v, e);
}

// --- Platonic / hardcoded solids --------------------------------------------

_Solid _tetrahedron() {
  const k = 0.85;
  final v = <_P3>[
    _P3(k, k, k),
    _P3(k, -k, -k),
    _P3(-k, k, -k),
    _P3(-k, -k, k),
  ];
  final e = <int>[0, 1, 0, 2, 0, 3, 1, 2, 1, 3, 2, 3];
  return _Solid(v, e);
}

_Solid _cube() {
  const k = 0.8;
  final v = <_P3>[
    _P3(-k, -k, -k), _P3(k, -k, -k), _P3(k, k, -k), _P3(-k, k, -k), // bottom
    _P3(-k, -k, k), _P3(k, -k, k), _P3(k, k, k), _P3(-k, k, k), // top
  ];
  final e = <int>[
    0, 1, 1, 2, 2, 3, 3, 0, // bottom
    4, 5, 5, 6, 6, 7, 7, 4, // top
    0, 4, 1, 5, 2, 6, 3, 7, // verticals
  ];
  return _Solid(v, e);
}

_Solid _octahedron() {
  final v = <_P3>[
    _P3(1, 0, 0), _P3(-1, 0, 0),
    _P3(0, 1, 0), _P3(0, -1, 0),
    _P3(0, 0, 1), _P3(0, 0, -1),
  ];
  final e = <int>[
    0, 2, 0, 3, 0, 4, 0, 5,
    1, 2, 1, 3, 1, 4, 1, 5,
    2, 4, 2, 5, 3, 4, 3, 5,
  ];
  return _Solid(v, e);
}

_Solid _dodecahedron() {
  const p = 1.618033988749895; // golden ratio
  const q = 0.618033988749895; // 1 / phi
  const s = 0.62; // scale so it sits in the same size band as the others
  final v = <_P3>[
    _P3(s, s, s), _P3(s, s, -s),
    _P3(s, -s, s), _P3(s, -s, -s),
    _P3(-s, s, s), _P3(-s, s, -s),
    _P3(-s, -s, s), _P3(-s, -s, -s),
    _P3(0, q * s, p * s), _P3(0, q * s, -p * s),
    _P3(0, -q * s, p * s), _P3(0, -q * s, -p * s),
    _P3(q * s, p * s, 0), _P3(q * s, -p * s, 0),
    _P3(-q * s, p * s, 0), _P3(-q * s, -p * s, 0),
    _P3(p * s, 0, q * s), _P3(p * s, 0, -q * s),
    _P3(-p * s, 0, q * s), _P3(-p * s, 0, -q * s),
  ];
  // Connect every pair at the shortest edge length — robust, and avoids
  // hand-listing all 30 edges.
  return _Solid(v, _edgesByMinDistance(v));
}

_Solid _sphere() {
  const nLat = 5; // bands pole-to-pole
  const nLong = 8; // meridians
  final v = <_P3>[];
  final rings = <List<int>>[];
  for (var la = 0; la <= nLat; la++) {
    final theta = math.pi * la / nLat; // 0..pi
    final z = math.cos(theta), r = math.sin(theta);
    final ring = <int>[];
    for (var lo = 0; lo < nLong; lo++) {
      final phi = 2 * math.pi * lo / nLong;
      ring.add(v.length);
      v.add(_P3(r * math.cos(phi), r * math.sin(phi), z));
    }
    rings.add(ring);
  }
  final e = <int>[];
  // Parallels (skip the degenerate pole rings).
  for (var la = 0; la <= nLat; la++) {
    if (math.sin(math.pi * la / nLat).abs() < 0.01) continue;
    final ring = rings[la];
    for (var lo = 0; lo < nLong; lo++) {
      e..add(ring[lo])..add(ring[(lo + 1) % nLong]);
    }
  }
  // Meridians.
  for (var la = 0; la < nLat; la++) {
    for (var lo = 0; lo < nLong; lo++) {
      e..add(rings[la][lo])..add(rings[la + 1][lo]);
    }
  }
  return _Solid(v, e);
}

/// Connects every vertex pair at (approximately) the shortest edge length.
List<int> _edgesByMinDistance(List<_P3> v) {
  var minD2 = double.infinity;
  for (var i = 0; i < v.length; i++) {
    for (var j = i + 1; j < v.length; j++) {
      final d2 = _dist2(v[i], v[j]);
      if (d2 < minD2) minD2 = d2;
    }
  }
  final thr = minD2 * 1.08;
  final e = <int>[];
  for (var i = 0; i < v.length; i++) {
    for (var j = i + 1; j < v.length; j++) {
      if (_dist2(v[i], v[j]) <= thr) {
        e..add(i)..add(j);
      }
    }
  }
  return e;
}

double _dist2(_P3 a, _P3 b) {
  final dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return dx * dx + dy * dy + dz * dz;
}