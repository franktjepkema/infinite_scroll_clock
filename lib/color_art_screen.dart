// lib/color_art_screen.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Color Art mode — an *infinite scrolling* colour field of soft, breathing
/// gradient circles on pure black. Compositing uses [BlendMode.screen] so
/// overlaps mix as *colour* (red + green = yellow) rather than washing to
/// white — the painterly mixing that gives the mode its beauty.
///
/// **One circle per blob (no stacking).** Each blob is a single radial
/// gradient. Organic life comes not from gluing sub-circles together but from:
///   • slow **radius breathing** — the blob swells and shrinks on its own
///     period (this is what made the original composition feel alive); and
///   • a very subtle **elliptical morph** — the one gradient is drawn through a
///     slowly rotating / squashing canvas transform, so the silhouette drifts
///     between round and gently oval. It stays a single smooth gradient, so
///     the edge is always soft and the colour always pure.
///
/// **Infinite scroll.** A gentle ambient current always drifts the whole field
/// in a slowly-wandering direction, so the canvas is never static. The
/// mechanical arm's swipe *helps you scroll*: during a drag the entire field
/// tracks the arm 1:1, and on release the throw becomes momentum that glides
/// and eases back to the ambient drift. Whichever way the canvas moves, blobs
/// that leave the trailing edge are recycled just outside the *leading* edge
/// with a fresh colour, size and morph — an endless stream of new colour. The
/// raw gesture delta drives the scroll, so this is orientation-adaptive for
/// free (horizontal in landscape, vertical in portrait).
///
/// **Even size distribution.** Each blob owns a fixed size *tier*, evenly
/// spaced from smallest to largest, so the field always holds an even spread
/// of sizes. The largest are ~8× the smallest and act as broad soft colour
/// masses; the smallest are crisp accents. Big blobs are dimmed per-draw so a
/// few screen-filling masses never wash the centre to white.
///
/// **Colour evolution.** Every blob draws a colour from an evolving palette
/// anchored on a hue that warms on forward commits and cools on backward ones
/// (the per-minute scroll commit). A slow autonomous hue drift is layered on
/// at draw time, so the whole field keeps shifting even at rest.
class ColorArtScreen extends StatefulWidget {
  final MotionController motion;
  const ColorArtScreen({super.key, required this.motion});

  @override
  State<ColorArtScreen> createState() => _ColorArtScreenState();
}

// --- Tuning ------------------------------------------------------------------

const int _kBlobCount = 14; // blobs alive in the field at once
const double _kRadiusMinFrac = 0.16; // min blob radius (fraction of shortestSide) — small dots
const double _kRadiusMaxFrac = 3.68; // max blob radius — ~8× the min, for big soft masses
const double _kCoreAlpha = 0.70; // centre opacity (rich, for painterly screen mixing)
const double _kBigDim = 0.45; // how much the largest blobs are dimmed (0..1 of alpha)

const double _kBreathAmp = 0.18; // radius breathing depth (± fraction of base radius)
const double _kMorphAmp = 0.12; // elliptical morph depth (± fraction on each axis)

// Scrolling.
const double _kAmbientSpeed = 12.0; // px/s — lazy baseline current
const double _kAmbientTurn = 0.03; // rad/s — how fast the current's direction wanders
const double _kInertiaTau = 1.3; // s — release-momentum decay
const double _kMaxReleaseSpeed = 2500.0; // px/s — cap on fling momentum

// Per-blob drift.
const double _kOwnVelMin = 4.0; // px/s — faint independent drift
const double _kOwnVelMax = 14.0;

// Colour.
const double _kHueDriftRate = 0.6; // deg/s — autonomous hue shimmer
const double _kCommitWarmStep = 25.0; // deg per commit (forward warms / back cools)

class _ColorArtScreenState extends State<ColorArtScreen>
    with TickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final math.Random _rng = math.Random();

  final _Scene _scene = _Scene();

  double _prevElapsedS = 0.0;
  int _lastCommit = 0;
  int _lastUpdateTick = -1;
  bool _wasDragging = false;
  bool _spawned = false;

  // Scroll state.
  Offset _pendingScroll = Offset.zero; // live 1:1 drag, consumed each tick
  Offset _camVel = Offset.zero; // release momentum (decays to zero)
  Offset _flow = const Offset(1, 0); // smoothed travel direction (for recycling)
  double _ambientAngle = 0.0;

  // Palette anchor (hue, degrees) — warms/cools with scroll commits.
  late double _paletteAnchor;

  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _paletteAnchor = _rng.nextDouble() * 360.0;
    _ambientAngle = _rng.nextDouble() * 2 * math.pi;
    _lastCommit = widget.motion.committedScrolls;
    widget.motion.addListener(_onMotion);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newSize = MediaQuery.of(context).size;
    if (newSize != _size) {
      _size = newSize;
      if (!_spawned && _size.width > 0 && _size.height > 0) {
        _spawnInitial();
        _spawned = true;
      }
    }
  }

  @override
  void didUpdateWidget(ColorArtScreen old) {
    super.didUpdateWidget(old);
    if (old.motion != widget.motion) {
      old.motion.removeListener(_onMotion);
      widget.motion.addListener(_onMotion);
      _lastCommit = widget.motion.committedScrolls;
    }
  }

  @override
  void dispose() {
    widget.motion.removeListener(_onMotion);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  // --- Per-blob parameter helpers --------------------------------------------

  /// Radius for an evenly-spaced size tier (0 = smallest, 1 = largest), with a
  /// little jitter. Fixed per-blob tiers keep the count of blobs evenly spread
  /// across the whole small→large range at all times.
  double _radiusForTier(double tier) {
    final span = _kRadiusMaxFrac - _kRadiusMinFrac;
    final stepFrac = span / (_kBlobCount - 1);
    final baseFrac = _kRadiusMinFrac + tier * span;
    final jit = (_rng.nextDouble() - 0.5) * stepFrac * 0.8;
    final frac =
        (baseFrac + jit).clamp(_kRadiusMinFrac, _kRadiusMaxFrac).toDouble();
    return _size.shortestSide * frac;
  }

  double _signed(double lo, double hi) =>
      (_rng.nextBool() ? 1.0 : -1.0) * (lo + _rng.nextDouble() * (hi - lo));

  Offset _ownVel() => Offset.fromDirection(
      _rng.nextDouble() * 2 * math.pi,
      _kOwnVelMin + _rng.nextDouble() * (_kOwnVelMax - _kOwnVelMin));

  /// (Re)assign the time-varying personality of a blob: colour, drift, breath
  /// and morph parameters. Used both at spawn and on recycle. The size tier is
  /// left untouched so the even distribution persists.
  void _refresh(_Blob b) {
    b.radius = _radiusForTier(b.sizeTier);
    b.color = _pickColor();
    b.ownVel = _ownVel();

    // Slow breathing: each blob swells/shrinks on its own ~18–38 s period.
    b.breathPeriodS = 18.0 + _rng.nextDouble() * 20.0;
    b.breathPhase = _rng.nextDouble() * 2 * math.pi;

    // Subtle elliptical morph: independent x/y squash on ~22–48 s periods plus
    // a slow rotation, so the soft circle drifts gently between round and oval.
    b.morphPeriodX = 22.0 + _rng.nextDouble() * 26.0;
    b.morphPeriodY = 22.0 + _rng.nextDouble() * 26.0;
    b.morphPhaseX = _rng.nextDouble() * 2 * math.pi;
    b.morphPhaseY = _rng.nextDouble() * 2 * math.pi;
    b.morphRot = _signed(0.02, 0.08); // rad/s
    b.morphPhaseR = _rng.nextDouble() * 2 * math.pi;
  }

  // --- Spawning / recycling --------------------------------------------------

  /// Populate the screen at start so the field is full immediately.
  void _spawnInitial() {
    _scene.blobs
      ..clear()
      ..addAll(List<_Blob>.generate(_kBlobCount, (i) {
        // Evenly spaced size tier: equal numbers of blobs from smallest to
        // largest across the field.
        final tier = _kBlobCount > 1 ? i / (_kBlobCount - 1) : 0.5;
        final b = _Blob(
          pos: Offset(_rng.nextDouble() * _size.width,
              _rng.nextDouble() * _size.height),
          sizeTier: tier,
        );
        _refresh(b);
        return b;
      }));
  }

  /// Recycle a blob that has fully left the screen: fresh identity, placed just
  /// outside the *leading* edge so it flows back in. Tier is preserved.
  void _recycle(_Blob b) {
    _refresh(b);
    b.pos = _entryPos(b.maxExtent);
  }

  /// A point just off-screen on the edge opposite to the current travel — so
  /// the blob enters from the leading side as the canvas scrolls.
  Offset _entryPos(double ext) {
    final w = _size.width, h = _size.height;
    final f = _flow.distance > 1e-3 ? _flow / _flow.distance : const Offset(1, 0);
    if (f.dx.abs() >= f.dy.abs()) {
      // Horizontal travel: enter from the left when moving right, else right.
      final x = f.dx > 0 ? -ext : w + ext;
      return Offset(x, _rng.nextDouble() * h);
    } else {
      final y = f.dy > 0 ? -ext : h + ext;
      return Offset(_rng.nextDouble() * w, y);
    }
  }

  // --- Continuous integration ------------------------------------------------

  void _onTick(Duration elapsed) {
    final newElapsedS = elapsed.inMicroseconds / 1e6;
    final dt = (newElapsedS - _prevElapsedS).clamp(0.0, 0.1).toDouble();
    _prevElapsedS = newElapsedS;
    _scene.elapsedS = newElapsedS;

    // Autonomous hue shimmer — the field is never strictly static.
    _scene.hueDrift += dt * _kHueDriftRate;

    if (_size.width > 0 && _size.height > 0 && _scene.blobs.isNotEmpty) {
      // Ambient current: a lazy, slowly-wandering baseline drift.
      _ambientAngle += dt * _kAmbientTurn;
      final ambient = Offset.fromDirection(_ambientAngle, _kAmbientSpeed);

      // Total camera translation this frame = live 1:1 drag + (ambient + inertia).
      final move = _pendingScroll + (ambient + _camVel) * dt;
      _pendingScroll = Offset.zero;
      _camVel = _camVel * math.exp(-dt / _kInertiaTau); // momentum eases out

      // Smooth the travel direction for stable recycling decisions.
      _flow = Offset.lerp(_flow, move, 0.18) ?? _flow;

      final w = _size.width, h = _size.height;
      for (final b in _scene.blobs) {
        b.pos += move + b.ownVel * dt;
        final ext = b.maxExtent;
        if (b.pos.dx < -ext ||
            b.pos.dx > w + ext ||
            b.pos.dy < -ext ||
            b.pos.dy > h + ext) {
          _recycle(b);
        }
      }
    }

    _frame.value += 1;
  }

  // --- Gesture ---------------------------------------------------------------

  void _onMotion() {
    final m = widget.motion;

    if (m.isDragging && !_wasDragging) {
      _wasDragging = true;
      _camVel = Offset.zero; // the drag itself now drives motion 1:1
    } else if (!m.isDragging && _wasDragging) {
      _wasDragging = false;
      // Release: the throw becomes momentum (capped), then decays to ambient.
      var v = m.velocity;
      if (v.distance > _kMaxReleaseSpeed) {
        v = v / v.distance * _kMaxReleaseSpeed;
      }
      _camVel = v;
    }

    // Live drag: scroll the whole field 1:1 with the arm.
    if (m.isDragging && m.updateTick != _lastUpdateTick) {
      _lastUpdateTick = m.updateTick;
      _pendingScroll += m.liveDelta;
    }

    // Per-minute commit nudges the palette: forward warms, backward cools.
    if (m.committedScrolls != _lastCommit) {
      _lastCommit = m.committedScrolls;
      _onCommit(m.lastDirection);
    }
  }

  void _onCommit(int direction) {
    final jitter = (_rng.nextDouble() - 0.5) * 40.0;
    var next = (_paletteAnchor + direction * _kCommitWarmStep + jitter) % 360.0;
    if (next < 0) next += 360.0;
    _paletteAnchor = next;
  }

  // --- Colour ----------------------------------------------------------------

  /// One colour from the evolving palette: a character band (vivid / dusty /
  /// moody) and a hue near the anchor, with occasional complementary pops so
  /// the field is cohesive but never monotone.
  HSVColor _pickColor() {
    final ch = _rng.nextDouble();
    final double sMin, sMax, vMin, vMax;
    if (ch < 0.70) {
      // vivid (most common)
      sMin = 0.70;
      sMax = 1.00;
      vMin = 0.82;
      vMax = 1.00;
    } else if (ch < 0.90) {
      // dusty / desaturated
      sMin = 0.25;
      sMax = 0.55;
      vMin = 0.70;
      vMax = 0.95;
    } else {
      // moody (saturated, a touch darker)
      sMin = 0.65;
      sMax = 0.95;
      vMin = 0.55;
      vMax = 0.80;
    }

    // Harmony offsets from the anchor — weighted toward analogous hues with
    // occasional triadic / complementary accents.
    const offsets = <double>[
      0, 0, 0, 30, -30, 45, -45, 60, -60, 120, -120, 180,
    ];
    final off = offsets[_rng.nextInt(offsets.length)] +
        (_rng.nextDouble() - 0.5) * 16.0;
    final hue = (((_paletteAnchor + off) % 360.0) + 360.0) % 360.0;
    return HSVColor.fromAHSV(
      1.0,
      hue,
      sMin + _rng.nextDouble() * (sMax - sMin),
      vMin + _rng.nextDouble() * (vMax - vMin),
    );
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _CloudPainter(scene: _scene, repaint: _frame),
      ),
    );
  }
}

// --- Data --------------------------------------------------------------------

class _Blob {
  Offset pos; // screen-space centre
  double sizeTier; // 0 (smallest) .. 1 (largest); fixed per blob for even spread

  // Filled in by _refresh():
  double radius = 1.0; // base radius (px), before breathing
  HSVColor color = const HSVColor.fromAHSV(1, 0, 1, 1);
  Offset ownVel = Offset.zero; // faint independent drift (px/s)

  double breathPeriodS = 24.0; // radius breathing period
  double breathPhase = 0.0;

  double morphPeriodX = 30.0; // elliptical morph periods (x / y axes)
  double morphPeriodY = 36.0;
  double morphPhaseX = 0.0;
  double morphPhaseY = 0.0;
  double morphRot = 0.04; // slow rotation of the morph axes (rad/s)
  double morphPhaseR = 0.0;

  _Blob({required this.pos, required this.sizeTier});

  /// Farthest the (breathing + morphing) blob can reach from [pos] — used for
  /// off-screen testing and for placing a recycled blob fully outside.
  double get maxExtent =>
      radius * (1.0 + _kBreathAmp) * (1.0 + _kMorphAmp) * 1.06;
}

/// Shared scratch the State writes and the painter reads.
class _Scene {
  final List<_Blob> blobs = <_Blob>[];
  double elapsedS = 0.0;
  double hueDrift = 0.0;
}

// --- Painter -----------------------------------------------------------------

class _CloudPainter extends CustomPainter {
  final _Scene scene;
  final Listenable repaint;

  _CloudPainter({required this.scene, required this.repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // Pure black base.
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    final t = scene.elapsedS;
    final hueDrift = scene.hueDrift;

    for (final b in scene.blobs) {
      // Colour: base hue plus the slow autonomous drift.
      final shiftedHue = ((b.color.hue + hueDrift) % 360.0 + 360.0) % 360.0;
      final color = b.color.withHue(shiftedHue).toColor();

      // Breathing radius — the single circle gently swells and shrinks.
      final breath =
          1.0 + _kBreathAmp * math.sin(2 * math.pi * t / b.breathPeriodS + b.breathPhase);
      final r = (b.radius * breath).clamp(1.0, double.infinity).toDouble();

      // Subtle elliptical morph: independent per-axis squash + slow rotation.
      final ax = 1.0 +
          _kMorphAmp * math.sin(2 * math.pi * t / b.morphPeriodX + b.morphPhaseX);
      final ay = 1.0 +
          _kMorphAmp * math.sin(2 * math.pi * t / b.morphPeriodY + b.morphPhaseY);
      final angle = b.morphRot * t + b.morphPhaseR;

      // Big blobs render gentler so several broad masses don't wash to white;
      // small dots stay punchy and richly saturated.
      final alpha = _kCoreAlpha * (1.0 - _kBigDim * b.sizeTier);

      // One soft radial gradient — a 3-stop falloff for a luminous, painterly
      // core that fades smoothly to nothing (no hard edge, ever).
      final shader = RadialGradient(
        colors: [
          color.withValues(alpha: alpha),
          color.withValues(alpha: alpha * 0.5),
          color.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: r));

      final paint = Paint()
        ..shader = shader
        // screen preserves colour at overlaps (red + green = yellow), reading
        // as painterly rather than stage-lit.
        ..blendMode = BlendMode.screen;

      // Draw the single gradient through the morph transform: translate to the
      // blob centre, rotate, then scale the two axes differently so the round
      // gradient becomes a gently morphing ellipse. Still one draw call.
      canvas.save();
      canvas.translate(b.pos.dx, b.pos.dy);
      canvas.rotate(angle);
      canvas.scale(ax, ay);
      canvas.drawCircle(Offset.zero, r, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _CloudPainter old) => true;
}