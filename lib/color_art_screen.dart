// lib/color_art_screen.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Color Art mode.
///
/// Four radial colour blobs drift across a pure-black field on independent
/// orbital paths, each breathing in size on its own period and crossfading
/// to fresh colours on its own schedule. Compositing uses [BlendMode.screen]
/// so overlaps mix as *colour* rather than washing toward white.
///
/// **Magnetic interaction.** During a swipe the mechanical arm's tip acts as
/// a magnet. At the start of every gesture each of the four blobs is randomly
/// assigned attract (+1) or repel (-1), with the constraint that the count
/// of attractors is always in {1, 2, 3} — there is never an all-attract or
/// all-repel field; the four blobs are always a mix.
///
/// The pull/push is applied as a smoothly-eased target offset (τ ≈ 2 s) and
/// only ramps up once the tip is meaningfully displaced (quadratic activation
/// over 0..120 px), so at rest the magnet is genuinely dormant. After the arm
/// releases, the tip's influence decays with τ ≈ 3 s and the blobs ease back
/// toward their orbits — the entire response unfolds at a lava-lamp pace.
///
/// **Mood cycle.** Each blob has a very slow secondary modulation
/// (~95–150 s period) that coherently scales both its radius and its orbit
/// reach. At different times one blob is *expansive* — large and roaming,
/// often well past the screen edges — while another is *intimate* — small
/// and close to centre. The four moods drift on independent periods.
///
/// **Commit-driven palette evolution.** On every minute commit a new
/// four-colour palette is generated and crossfaded with per-blob staggered
/// timings; base duration is set by recent gesture speed (fast = snappy,
/// slow = languid). Direction biases a long-running palette anchor so many
/// forward swipes gradually warm the cloud and many backward swipes cool it.
/// A ~0.5°/s autonomous hue drift runs at all times so the cloud is never
/// strictly static.
class ColorArtScreen extends StatefulWidget {
  final MotionController motion;
  const ColorArtScreen({super.key, required this.motion});

  @override
  State<ColorArtScreen> createState() => _ColorArtScreenState();
}

class _ColorArtScreenState extends State<ColorArtScreen>
    with TickerProviderStateMixin {
  late final Ticker _ticker;
  // Increments every frame; painter listens to it and repaints.
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  final math.Random _rng = math.Random();
  late final _Anim _anim;

  double _prevElapsedS = 0.0;
  double _recentSpeed = 0.0; // px/s, EMA of gesture speed
  int _lastCommit = 0;
  int _lastUpdateTick = -1;
  bool _wasDragging = false;

  /// Drifts on every commit by direction × 25° ± 20°; the palette gradually
  /// warms or cools over many minutes of one-way scrolling.
  late double _paletteAnchor;

  /// Tracked from MediaQuery; the magnetic update needs it to compute each
  /// blob's current orbit position when the painter isn't running.
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _paletteAnchor = _rng.nextDouble() * 360.0;
    _anim = _Anim(_initBlobs(_paletteAnchor));
    _lastCommit = widget.motion.committedScrolls;
    widget.motion.addListener(_onMotion);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _size = MediaQuery.of(context).size;
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

  // --- Initial composition ---------------------------------------------------

  List<_Blob> _initBlobs(double anchor) {
    final pal = _generatePaletteFromAnchor(anchor);

    // Per-blob parameters: orbit period and phase; orbit radii (fractions of
    // screen w/h); base radius (fraction of shortestSide); radius-breath
    // period and phase; very-slow "mood" period.
    const periods = <double>[73.0, 97.0, 113.0, 137.0];
    const phases = <double>[0.0, 1.91, 3.86, 5.56];
    const orbitRX = <double>[0.25, 0.34, 0.28, 0.42];
    const orbitRY = <double>[0.34, 0.24, 0.38, 0.28];
    const baseRadii = <double>[0.55, 0.68, 0.58, 0.74];
    const breathPeriods = <double>[23.0, 31.0, 27.0, 38.0];
    const breathPhases = <double>[0.0, 1.26, 3.14, 4.71];
    const moodPeriods = <double>[97.0, 113.0, 131.0, 149.0];

    return List<_Blob>.generate(
      4,
      (i) => _Blob(
        orbitPeriodS: periods[i],
        orbitPhase: phases[i],
        orbitRX: orbitRX[i],
        orbitRY: orbitRY[i],
        baseRadius: baseRadii[i],
        breathPeriodS: breathPeriods[i],
        breathPhase: breathPhases[i],
        moodPeriodS: moodPeriods[i],
        moodPhase: _rng.nextDouble() * 2 * math.pi,
        magnetPolarity: _rng.nextBool() ? 1 : -1,
        magnetStrength: 0.08 + _rng.nextDouble() * 0.10,
        fromColor: pal[i],
        toColor: pal[i],
        fadeStartS: 0.0,
        fadeDurationS: 0.001,
      ),
    );
  }

  /// On every new gesture, re-randomise the four magnet polarities under the
  /// constraint: the count of attractors must be 1, 2, or 3. Never all four
  /// of the same sign — we always want a visible mix of attract and repel.
  void _randomizePolarities() {
    const n = 4;
    final attractCount = 1 + _rng.nextInt(n - 1); // 1..3
    final indices = List<int>.generate(n, (i) => i);
    indices.shuffle(_rng);
    final attractSet = indices.sublist(0, attractCount).toSet();
    for (var i = 0; i < _anim.blobs.length; i++) {
      final b = _anim.blobs[i];
      b.magnetPolarity = attractSet.contains(i) ? 1 : -1;
      // Also re-pick the magnitude so successive cycles don't feel identical.
      b.magnetStrength = 0.08 + _rng.nextDouble() * 0.10;
    }
  }

  // --- Continuous time integration -------------------------------------------

  void _onTick(Duration elapsed) {
    final newElapsedS = elapsed.inMicroseconds / 1e6;
    final dt = (newElapsedS - _prevElapsedS).clamp(0.0, 0.1);
    _prevElapsedS = newElapsedS;
    _anim.elapsedS = newElapsedS;

    final isDragging = widget.motion.isDragging;

    // Drift clock advances faster during a gesture and faster still with
    // higher recent speed, lending the cloud subtle energy without ever
    // snapping.
    final speedFactor = (_recentSpeed / 800.0).clamp(0.0, 1.0);
    final driftRate = (isDragging ? 1.6 : 1.0) + speedFactor * 0.3;
    _anim.driftClock += dt * driftRate;

    // Slow autonomous hue drift — the cloud is never strictly static.
    _anim.hueDrift += dt * 0.5; // degrees per second

    // Decay tip influence and recent-speed memory after the gesture ends.
    // The tip uses a long (~3 s) tau so the magnet's pull persists and fades
    // at a lava-lamp pace.
    if (!isDragging) {
      _anim.dragOffset = _anim.dragOffset * math.exp(-dt / 3.0);
      _recentSpeed *= math.exp(-dt / 1.5);
    }

    // Update each blob's magnetic offset by easing it toward its target.
    // Target = (tip - orbit) × polarity × strength × activation, where the
    // activation gates the effect off when the tip is near zero.
    if (_size.width > 0 && _size.height > 0) {
      const magneticTauS = 2.0;
      final alpha = 1.0 - math.exp(-dt / magneticTauS);
      final tip = _anim.dragOffset;

      // Quadratic ramp 0..120 px of tip displacement -> 0..1 activation, so
      // at rest the magnet is dormant rather than holding a center-pull.
      final tipNorm = (tip.distance / 120.0).clamp(0.0, 1.0);
      final activation = tipNorm * tipNorm;

      final w = _size.width;
      final h = _size.height;
      for (final b in _anim.blobs) {
        final theta =
            2 * math.pi * _anim.driftClock / b.orbitPeriodS + b.orbitPhase;
        final mood = math.sin(
            2 * math.pi * _anim.elapsedS / b.moodPeriodS + b.moodPhase);
        final moodOrbitF = 1.0 + 0.25 * mood;
        final orbit = Offset(
          math.cos(theta) * w * b.orbitRX * moodOrbitF,
          math.sin(theta * 0.83) * h * b.orbitRY * moodOrbitF,
        );
        final target = (tip - orbit) *
            (b.magnetStrength * b.magnetPolarity.toDouble() * activation);
        b.magneticOffset = Offset.lerp(b.magneticOffset, target, alpha)!;
      }
    }

    _frame.value += 1;
  }

  // --- Discrete motion handling ----------------------------------------------

  void _onMotion() {
    final m = widget.motion;

    // Re-polarise the blobs at the very start of each gesture.
    if (m.isDragging && !_wasDragging) {
      _wasDragging = true;
      _randomizePolarities();
    } else if (!m.isDragging && _wasDragging) {
      _wasDragging = false;
    }

    // Live drag: accumulate tip displacement and update the recent-speed EMA.
    if (m.isDragging && m.updateTick != _lastUpdateTick) {
      _lastUpdateTick = m.updateTick;

      var next = _anim.dragOffset + m.liveDelta;
      const cap = 320.0; // a little more reach than before, to feed the magnet
      if (next.distance > cap) {
        next = next / next.distance * cap;
      }
      _anim.dragOffset = next;

      // Frame-time-independent speed approximation (px/s, assuming ~60 fps).
      final inst = m.liveDelta.distance * 60.0;
      _recentSpeed = _recentSpeed * 0.80 + inst * 0.20;
    }

    if (m.committedScrolls != _lastCommit) {
      _lastCommit = m.committedScrolls;
      _onCommit(m.lastDirection);
    }
  }

  void _onCommit(int direction) {
    // Long-running directional bias on the palette anchor: forward warms the
    // base hue, backward cools it. Jitter prevents it from feeling robotic.
    final jitter = (_rng.nextDouble() - 0.5) * 40.0;
    var next = (_paletteAnchor + direction * 25.0 + jitter) % 360.0;
    if (next < 0) next += 360.0;
    _paletteAnchor = next;

    final newPal = _generatePaletteFromAnchor(_paletteAnchor);

    // Recent gesture speed sets the *base* fade duration: slow swipes get
    // languid transitions, fast ones get snappier.
    final speedT = (_recentSpeed / 600.0).clamp(0.0, 1.0);
    final baseDurationS = 2.4 + (0.7 - 2.4) * speedT;

    for (var i = 0; i < _anim.blobs.length; i++) {
      final b = _anim.blobs[i];

      // Freeze the currently interpolated colour as the new "from" so we
      // never restart from a stale value mid-transition.
      final fadeT = b.fadeDurationS > 0.0
          ? ((_anim.elapsedS - b.fadeStartS) / b.fadeDurationS).clamp(0.0, 1.0)
          : 1.0;
      final easeT = Curves.easeInOutCubic.transform(fadeT);
      final current = _hsvLerp(b.fromColor, b.toColor, easeT);

      b.fromColor = current;
      b.toColor = newPal[i];
      // Per-blob stagger and ±30 % duration jitter so the four colours don't
      // resolve in lock-step.
      b.fadeStartS = _anim.elapsedS + i * 0.06;
      b.fadeDurationS = baseDurationS * (0.7 + _rng.nextDouble() * 0.6);
    }
  }

  // --- Palette generation ----------------------------------------------------

  /// Build a four-colour palette with a chosen *harmony* (triadic + accent,
  /// analogous, complementary pairs, split-complementary, monochromatic) and
  /// a chosen *character* (vivid, dusty/desaturated, moody/darker).
  List<HSVColor> _generatePaletteFromAnchor(double anchor) {
    final char = _rng.nextDouble();
    final double satMin, satMax, valMin, valMax;
    if (char < 0.70) {
      // vivid (most common)
      satMin = 0.70;
      satMax = 1.00;
      valMin = 0.82;
      valMax = 1.00;
    } else if (char < 0.90) {
      // dusty / desaturated
      satMin = 0.25;
      satMax = 0.55;
      valMin = 0.70;
      valMax = 0.95;
    } else {
      // moody (still saturated, a touch darker)
      satMin = 0.65;
      satMax = 0.95;
      valMin = 0.55;
      valMax = 0.80;
    }

    HSVColor mk(double hue) => HSVColor.fromAHSV(
          1.0,
          ((hue % 360.0) + 360.0) % 360.0,
          satMin + _rng.nextDouble() * (satMax - satMin),
          valMin + _rng.nextDouble() * (valMax - valMin),
        );

    final mode = _rng.nextDouble();
    final List<double> offsets;
    if (mode < 0.30) {
      // triadic + analogous accent
      offsets = [0.0, 120.0, 240.0, 30.0 + _rng.nextDouble() * 25.0];
    } else if (mode < 0.55) {
      // analogous, ~50° spread
      offsets = const [-50.0, -16.67, 16.67, 50.0];
    } else if (mode < 0.75) {
      // complementary pairs
      offsets = const [-10.0, 10.0, 170.0, 190.0];
    } else if (mode < 0.90) {
      // split-complementary
      offsets = const [0.0, 30.0, 150.0, 210.0];
    } else {
      // monochromatic (variation comes from sat/val randomness)
      offsets = const [0.0, 4.0, -4.0, 2.0];
    }

    return offsets.map((o) => mk(anchor + o)).toList();
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _CloudPainter(anim: _anim, repaint: _frame),
      ),
    );
  }
}

/// HSV lerp that always takes the shortest path around the hue wheel, so
/// crossfading from 350° to 10° passes through 0° (red) rather than through
/// 180° (cyan).
HSVColor _hsvLerp(HSVColor a, HSVColor b, double t) {
  final h1 = ((a.hue % 360.0) + 360.0) % 360.0;
  final h2 = ((b.hue % 360.0) + 360.0) % 360.0;
  var diff = h2 - h1;
  if (diff > 180.0) diff -= 360.0;
  if (diff < -180.0) diff += 360.0;
  final hue = ((h1 + diff * t) % 360.0 + 360.0) % 360.0;
  return HSVColor.fromAHSV(
    a.alpha + (b.alpha - a.alpha) * t,
    hue,
    a.saturation + (b.saturation - a.saturation) * t,
    a.value + (b.value - a.value) * t,
  );
}

class _Blob {
  double orbitPeriodS;
  double orbitPhase;
  double orbitRX;
  double orbitRY;
  double baseRadius;
  double breathPeriodS;
  double breathPhase;

  /// Very slow secondary modulation period (~95–150 s); scales *both* the
  /// radius and the orbit reach so the blob alternates coherently between
  /// expansive (large + roaming) and intimate (small + near centre).
  double moodPeriodS;
  double moodPhase;

  /// +1 (attract toward arm tip) or -1 (repel from tip). Re-randomised at
  /// the start of every gesture, with a global mix-not-all-same constraint.
  int magnetPolarity;

  /// Unsigned magnitude of the magnetic effect (0.08–0.18 in current tuning).
  double magnetStrength;

  /// Smoothed magnetic displacement (lava-lamp tau = 2 s). The painter adds
  /// this to the orbit-derived blob centre.
  Offset magneticOffset;

  HSVColor fromColor;
  HSVColor toColor;
  double fadeStartS;
  double fadeDurationS;

  _Blob({
    required this.orbitPeriodS,
    required this.orbitPhase,
    required this.orbitRX,
    required this.orbitRY,
    required this.baseRadius,
    required this.breathPeriodS,
    required this.breathPhase,
    required this.moodPeriodS,
    required this.moodPhase,
    required this.magnetPolarity,
    required this.magnetStrength,
    required this.fromColor,
    required this.toColor,
    required this.fadeStartS,
    required this.fadeDurationS,
  }) : magneticOffset = Offset.zero;
}

/// Shared mutable scratchpad — the State writes, the painter reads.
class _Anim {
  final List<_Blob> blobs;
  double elapsedS = 0.0;
  double driftClock = 0.0;
  double hueDrift = 0.0;
  Offset dragOffset = Offset.zero;
  _Anim(this.blobs);
}

class _CloudPainter extends CustomPainter {
  final _Anim anim;
  final Listenable repaint;

  _CloudPainter({required this.anim, required this.repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // Pure black base.
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    final c = Offset(size.width / 2, size.height / 2);
    final shortest = size.shortestSide;

    for (var i = 0; i < anim.blobs.length; i++) {
      final b = anim.blobs[i];

      // --- Position: Lissajous orbit (mood-scaled) + magnetic offset ----
      final theta =
          2 * math.pi * anim.driftClock / b.orbitPeriodS + b.orbitPhase;
      final mood = math.sin(
          2 * math.pi * anim.elapsedS / b.moodPeriodS + b.moodPhase);
      final moodOrbitF = 1.0 + 0.25 * mood;
      // 0.83 y-multiplier keeps the orbit from closing on itself, so each
      // blob traces a slowly precessing path.
      final orbit = Offset(
        math.cos(theta) * size.width * b.orbitRX * moodOrbitF,
        math.sin(theta * 0.83) * size.height * b.orbitRY * moodOrbitF,
      );
      final center = c + orbit + b.magneticOffset;

      // --- Radius: breath × mood (both can be expansive simultaneously) -
      final br =
          2 * math.pi * anim.elapsedS / b.breathPeriodS + b.breathPhase;
      final moodRF = 1.0 + 0.30 * mood;
      final radius =
          shortest * b.baseRadius * (1.0 + 0.25 * math.sin(br)) * moodRF;

      // --- Colour: per-blob fade, then global hue drift ----------------
      final fadeT = b.fadeDurationS > 0.0
          ? ((anim.elapsedS - b.fadeStartS) / b.fadeDurationS).clamp(0.0, 1.0)
          : 1.0;
      final easeT = Curves.easeInOutCubic.transform(fadeT);
      final base = _hsvLerp(b.fromColor, b.toColor, easeT);
      final shiftedHue = ((base.hue + anim.hueDrift) % 360.0 + 360.0) % 360.0;
      final color = base.withHue(shiftedHue).toColor();

      // --- Draw radial gradient with screen blend ----------------------
      final shader = RadialGradient(
        colors: [color.withOpacity(0.78), color.withOpacity(0.0)],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = shader
          // screen preserves colour at overlaps (red + green = yellow, not
          // white), which reads as painterly rather than stage-lit.
          ..blendMode = BlendMode.screen,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CloudPainter old) => true;
}