// lib/still_life.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Still Life mode.
///
/// A from-scratch reconstruction of the surreal still-life render as a set of
/// discrete 3-D **volumes**, rebuilt in the series' white-on-black house style
/// (luminous, depth-shaded wireframe) and recomposed to read well on a tall
/// portrait screen.
///
/// The source tableau — a grey cone, a flared pink horn on a rod, a splayed
/// cluster of green pods, a small spearhead, a hanging ring on a string, a ball
/// on a needle, a tall colour bar, and a little nub on the floor — is rebuilt
/// here with each object as its own [_Volume]: a centre, a scale, a base
/// orientation, optional spin/wobble and style. Because every transform is
/// mutable, individual objects can be picked and manipulated later; for now a
/// swipe orbits the whole assembly and a light spring eases it back to a slowly
/// breathing baseline (echoing the gentle turntable of the clip).
///
/// **Interaction.** The mechanical arm's horizontal motion yaws the scene, its
/// vertical motion pitches it; both spring back toward the breathing baseline,
/// so a long slow swipe turns the assembly to reveal the depth of the forms and
/// then settles. The green pods carry a faint independent wobble so the cluster
/// articulates like the limb in the source.
///
/// Rendering is orthographic (centres project to their intended screen spots
/// when head-on) with additive white line-work over pure black.
class StillLifeScreen extends StatefulWidget {
  final MotionController motion;
  const StillLifeScreen({super.key, required this.motion});

  @override
  State<StillLifeScreen> createState() => _StillLifeScreenState();
}

// --- Tuning ------------------------------------------------------------------

// Camera spring (returns the assembly to the breathing baseline after a swipe).
const double _kCamGain = 0.0015; // yaw/pitch velocity per px of drag
const double _kCamReleaseGain = 0.00011; // extra kick per px/s on release
const double _kCamStiff = 2.0;
const double _kCamDamp = 1.35;
const double _kCamMax = 0.7; // clamp on yaw/pitch (rad)

// Ambient idle turntable (subtle, like the clip).
const double _kSwayYaw = 0.16; // rad
const double _kSwayPitch = 0.05; // rad
const double _kSwayFYaw = 0.06; // Hz-ish
const double _kSwayFPitch = 0.045;
const double _kPitchBias = -0.04; // look very slightly down

// Fit margins / scene extents (normalised units; portrait-tall composition).
const double _kFitMargin = 0.94;
const double _kSceneHalfW = 0.62;
const double _kSceneHalfH = 0.98;

const int _kStarCount = 70;

class _StillLifeScreenState extends State<StillLifeScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final math.Random _rng = math.Random();

  late final List<_Volume> _scene;
  late final List<_Star> _stars;

  double _yaw = 0.0, _pitch = 0.0;
  double _yawVel = 0.0, _pitchVel = 0.0;
  double _elapsed = 0.0, _prevS = 0.0;
  int _lastTick = -1;

  @override
  void initState() {
    super.initState();
    _scene = _buildScene();
    for (final v in _scene) {
      v.bake(); // precompute static geometry once (no per-frame allocation)
    }
    _stars = List.generate(
      _kStarCount,
      (_) => _Star(
        _rng.nextDouble(),
        _rng.nextDouble(),
        0.4 + _rng.nextDouble() * 1.2,
        0.08 + _rng.nextDouble() * 0.4,
      ),
    );
    widget.motion.addListener(_onMotion);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(StillLifeScreen old) {
    super.didUpdateWidget(old);
    if (old.motion != widget.motion) {
      old.motion.removeListener(_onMotion);
      widget.motion.addListener(_onMotion);
    }
  }

  @override
  void dispose() {
    widget.motion.removeListener(_onMotion);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  // --- Scene graph -----------------------------------------------------------
  //
  // Normalised coordinates: origin at composition centre, +y up, +z toward the
  // viewer. Recomposed taller-than-wide for a portrait screen.

  List<_Volume> _buildScene() {
    final s = <_Volume>[];

    // Faint floor ellipse to ground the assembly (a ring laid flat in XZ).
    s.add(_Volume.ring(
      center: const _V3(0, -0.74, 0),
      scale: const _V3(0.5, 0.5, 1),
      rx: math.pi / 2, // lay it down
      seg: 56,
      bright: 0.13,
    ));

    // The grey cone — the vertical spine, upper-centre, slightly tilted.
    s.add(_Volume.lathe(
      profile: _coneProfile,
      center: const _V3(0.02, 0.16, -0.02),
      scale: const _V3(0.24, 0.5, 0.24),
      rz: -0.12,
      seg: 24,
      bright: 0.5,
      glow: true,
    ));

    // The flared pink horn, left, opening toward the viewer; on a rod.
    s.add(_Volume.lathe(
      profile: _hornProfile,
      center: const _V3(-0.34, 0.04, 0.06),
      scale: const _V3(0.22, 0.24, 0.22),
      rz: 1.45, // axis points to -x: the bell opens left/front
      ry: 0.35,
      seg: 16,
      bright: 0.55,
      glow: true,
    ));

    // Rod skewering the horn, running up to the spearhead (explicit segment).
    s.add(_Volume.segment(
      a: const _V3(-0.30, 0.05, 0.06),
      b: const _V3(0.27, 0.45, 0.0),
      bright: 0.45,
      glow: true,
    ));

    // The splayed green pod cluster, radiating from a joint on the right.
    const joint = _V3(0.18, -0.04, 0.06);
    const podAngles = <double>[0.55, 0.22, -0.10, -0.55, -1.05]; // from +x, rad
    const podLens = <double>[0.20, 0.23, 0.22, 0.21, 0.18];
    for (var i = 0; i < podAngles.length; i++) {
      final ang = podAngles[i];
      final len = podLens[i];
      final dir = _V3(math.cos(ang), math.sin(ang), 0);
      final center = _V3(
        joint.x + dir.x * len * 0.9,
        joint.y + dir.y * len * 0.9,
        joint.z + (i.isEven ? 0.04 : -0.04),
      );
      s.add(_Volume.lathe(
        profile: _podProfile,
        center: center,
        scale: _V3(0.055, len, 0.055),
        rz: ang - math.pi / 2, // pod long-axis (model +y) points along dir
        rx: (i.isEven ? 0.18 : -0.14), // small out-of-plane spread
        seg: 12,
        bright: 0.5,
        wobbleAmp: 0.06,
        wobbleRate: 0.5 + i * 0.07,
        wobblePhase: i * 1.3,
        wobbleAxis: 2, // gentle articulation about the splay axis
      ));
    }

    // Small spearhead / spinning teardrop at the top of the rod.
    s.add(_Volume.lathe(
      profile: _spearProfile,
      center: const _V3(0.28, 0.49, 0.0),
      scale: const _V3(0.06, 0.12, 0.06),
      rz: 0.2,
      seg: 14,
      bright: 0.6,
      spinYRate: 0.6, // it slowly spins like a top
      glow: true,
    ));

    // Hanging ring on a string, top-centre.
    s.add(_Volume.segment(
      a: const _V3(0.0, 0.93, 0.0),
      b: const _V3(0.0, 0.66, 0.0),
      bright: 0.5,
      glow: true,
    ));
    s.add(_Volume.ring(
      center: const _V3(0.0, 0.61, 0.02),
      scale: const _V3(0.055, 0.055, 1),
      rx: 0.25,
      seg: 40,
      bright: 0.7,
      glow: true,
    ));

    // Ball on a needle, upper-right.
    s.add(_Volume.segment(
      a: const _V3(0.22, 0.60, 0.0),
      b: const _V3(0.38, 0.60, 0.0),
      bright: 0.45,
    ));
    s.add(_Volume.sphere(
      center: const _V3(0.43, 0.60, 0.0),
      scale: const _V3(0.05, 0.05, 0.05),
      lon: 12,
      lat: 7,
      bright: 0.7,
      glow: true,
    ));

    // Tall colour-bar, recast as a slim luminous prism with two dividers, right.
    s.add(_Volume.box(
      center: const _V3(0.47, 0.06, -0.04),
      scale: const _V3(0.045, 0.42, 0.03),
      divs: 2,
      bright: 0.55,
      glow: true,
    ));

    // The little nub on the floor, lower-left (a small knobbly icosahedron).
    s.add(_Volume.icosa(
      center: const _V3(-0.30, -0.62, 0.10),
      scale: const _V3(0.085, 0.065, 0.075),
      bright: 0.5,
      spinYRate: 0.18,
      glow: true,
    ));

    return s;
  }

  // --- Gesture (orbit the assembly) ------------------------------------------

  void _onMotion() {
    final m = widget.motion;
    if (m.isDragging && m.updateTick != _lastTick) {
      _lastTick = m.updateTick;
      _yawVel += m.liveDelta.dx * _kCamGain;
      _pitchVel += -m.liveDelta.dy * _kCamGain;
    } else if (!m.isDragging && m.velocity != Offset.zero) {
      _yawVel += m.velocity.dx * _kCamReleaseGain;
      _pitchVel += -m.velocity.dy * _kCamReleaseGain;
    }
  }

  // --- Integration -----------------------------------------------------------

  void _onTick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    final dt = (t - _prevS).clamp(0.0, 0.05).toDouble();
    _prevS = t;
    _elapsed = t;

    // Breathing baseline (a slow, shallow turntable) the camera springs toward.
    final yawTarget = _kSwayYaw * math.sin(t * _kSwayFYaw * 2 * math.pi);
    final pitchTarget =
        _kPitchBias + _kSwayPitch * math.sin(t * _kSwayFPitch * 2 * math.pi);

    _yawVel += (-_kCamStiff * (_yaw - yawTarget) - _kCamDamp * _yawVel) * dt;
    _pitchVel +=
        (-_kCamStiff * (_pitch - pitchTarget) - _kCamDamp * _pitchVel) * dt;
    _yaw = (_yaw + _yawVel * dt).clamp(-_kCamMax, _kCamMax).toDouble();
    _pitch = (_pitch + _pitchVel * dt).clamp(-_kCamMax, _kCamMax).toDouble();

    _frame.value += 1;
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _StillLifePainter(
          scene: _scene,
          stars: _stars,
          repaint: _frame,
          yawOf: () => _yaw,
          pitchOf: () => _pitch,
          timeOf: () => _elapsed,
        ),
      ),
    );
  }
}

// --- Lathe profiles ([radius, y]; revolved around the Y axis) ----------------

const List<List<double>> _coneProfile = [
  [0.0, 1.0],
  [0.5, 0.0],
  [1.0, -1.0],
];

const List<List<double>> _hornProfile = [
  [0.04, -1.0],
  [0.07, -0.55],
  [0.12, -0.15],
  [0.20, 0.20],
  [0.33, 0.55],
  [0.52, 0.82],
  [0.66, 1.0],
];

const List<List<double>> _podProfile = [
  [0.0, -1.0],
  [0.16, -0.55],
  [0.22, -0.05],
  [0.20, 0.5],
  [0.0, 1.0],
];

const List<List<double>> _spearProfile = [
  [0.0, 1.0],
  [0.10, 0.55],
  [0.20, 0.05],
  [0.12, -0.55],
  [0.0, -1.0],
];

// --- Data --------------------------------------------------------------------

class _V3 {
  final double x, y, z;
  const _V3(this.x, this.y, this.z);
}

enum _Kind { lathe, box, sphere, ring, segment, icosa }

/// A single manipulable element. Centre / scale / orientation / spin / wobble
/// are mutable so future code can grab one object and move, scale, turn or
/// animate it independently.
class _Volume {
  final _Kind kind;
  _V3 center;
  _V3 scale; // (rx, ry, rz) normalised
  double rx, ry, rz; // base Euler orientation (roll Z, pitch X, yaw Y)
  double spinYRate; // continuous self-rotation about Y
  double wobbleAmp, wobbleRate, wobblePhase;
  int wobbleAxis; // 0=x, 1=y, 2=z

  // Segment endpoints (world, normalised) — used only by _Kind.segment.
  _V3 a, b;

  // Style.
  double bright, lineW;
  bool glow, dashed;

  // Geometry params.
  List<List<double>> profile;
  int seg, lon, lat, divs;

  // Baked geometry (filled once by [bake]).
  List<_V3> verts = const [];
  List<int> edges = const [];

  _Volume._({
    required this.kind,
    required this.center,
    required this.scale,
    this.rx = 0.0,
    this.ry = 0.0,
    this.rz = 0.0,
    this.spinYRate = 0.0,
    this.wobbleAmp = 0.0,
    this.wobbleRate = 0.0,
    this.wobblePhase = 0.0,
    this.wobbleAxis = 0,
    this.a = const _V3(0, 0, 0),
    this.b = const _V3(0, 0, 0),
    this.bright = 0.5,
    this.lineW = 1.0,
    this.glow = false,
    this.dashed = false,
    this.profile = const [],
    this.seg = 24,
    this.lon = 12,
    this.lat = 7,
    this.divs = 0,
  });

  factory _Volume.lathe({
    required List<List<double>> profile,
    required _V3 center,
    required _V3 scale,
    double rx = 0.0,
    double ry = 0.0,
    double rz = 0.0,
    int seg = 20,
    double bright = 0.5,
    double spinYRate = 0.0,
    double wobbleAmp = 0.0,
    double wobbleRate = 0.0,
    double wobblePhase = 0.0,
    int wobbleAxis = 0,
    bool glow = false,
  }) =>
      _Volume._(
        kind: _Kind.lathe,
        center: center,
        scale: scale,
        rx: rx,
        ry: ry,
        rz: rz,
        seg: seg,
        bright: bright,
        spinYRate: spinYRate,
        wobbleAmp: wobbleAmp,
        wobbleRate: wobbleRate,
        wobblePhase: wobblePhase,
        wobbleAxis: wobbleAxis,
        glow: glow,
        profile: profile,
      );

  factory _Volume.box({
    required _V3 center,
    required _V3 scale,
    int divs = 0,
    double bright = 0.5,
    bool glow = false,
  }) =>
      _Volume._(
        kind: _Kind.box,
        center: center,
        scale: scale,
        divs: divs,
        bright: bright,
        glow: glow,
      );

  factory _Volume.sphere({
    required _V3 center,
    required _V3 scale,
    int lon = 12,
    int lat = 7,
    double bright = 0.5,
    bool glow = false,
  }) =>
      _Volume._(
        kind: _Kind.sphere,
        center: center,
        scale: scale,
        lon: lon,
        lat: lat,
        bright: bright,
        glow: glow,
      );

  factory _Volume.ring({
    required _V3 center,
    required _V3 scale,
    double rx = 0.0,
    int seg = 48,
    double bright = 0.5,
    bool glow = false,
  }) =>
      _Volume._(
        kind: _Kind.ring,
        center: center,
        scale: scale,
        rx: rx,
        seg: seg,
        bright: bright,
        glow: glow,
      );

  factory _Volume.segment({
    required _V3 a,
    required _V3 b,
    double bright = 0.5,
    bool glow = false,
  }) =>
      _Volume._(
        kind: _Kind.segment,
        center: const _V3(0, 0, 0),
        scale: const _V3(1, 1, 1),
        a: a,
        b: b,
        bright: bright,
        glow: glow,
      );

  factory _Volume.icosa({
    required _V3 center,
    required _V3 scale,
    double bright = 0.5,
    double spinYRate = 0.0,
    bool glow = false,
  }) =>
      _Volume._(
        kind: _Kind.icosa,
        center: center,
        scale: scale,
        bright: bright,
        spinYRate: spinYRate,
        glow: glow,
      );

  /// Precompute the static unit geometry for this volume's kind.
  void bake() {
    switch (kind) {
      case _Kind.lathe:
        final g = _latheGeom(profile, seg);
        verts = g.v;
        edges = g.e;
        break;
      case _Kind.box:
        final g = _boxGeom(divs);
        verts = g.v;
        edges = g.e;
        break;
      case _Kind.sphere:
        final g = _sphereGeom(lon, lat);
        verts = g.v;
        edges = g.e;
        break;
      case _Kind.ring:
        final g = _ringGeom(seg);
        verts = g.v;
        edges = g.e;
        break;
      case _Kind.icosa:
        final g = _icosaGeom();
        verts = g.v;
        edges = g.e;
        break;
      case _Kind.segment:
        verts = [a, b];
        edges = const [0, 1];
        break;
    }
  }
}

class _Star {
  final double fx, fy, r, a;
  const _Star(this.fx, this.fy, this.r, this.a);
}

// --- Painter -----------------------------------------------------------------

class _StillLifePainter extends CustomPainter {
  final List<_Volume> scene;
  final List<_Star> stars;
  final double Function() yawOf;
  final double Function() pitchOf;
  final double Function() timeOf;

  _StillLifePainter({
    required this.scene,
    required this.stars,
    required Listenable repaint,
    required this.yawOf,
    required this.pitchOf,
    required this.timeOf,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    final cx = size.width / 2, cy = size.height / 2;
    final halfW = size.width / 2, halfH = size.height / 2;
    // Uniform fit keeps the portrait composition's aspect on any screen.
    final s = math.min(
      halfW * _kFitMargin / _kSceneHalfW,
      halfH * _kFitMargin / _kSceneHalfH,
    );

    _paintStars(canvas, size);
    _paintVignette(canvas, size, cx, cy);

    final t = timeOf();
    final yaw = yawOf(), pitch = pitchOf();
    final cyaw = math.cos(yaw), syaw = math.sin(yaw);
    final cpit = math.cos(pitch), spit = math.sin(pitch);

    for (final v in scene) {
      _drawVolume(canvas, v, t, cx, cy, s, cyaw, syaw, cpit, spit);
    }
  }

  void _paintStars(Canvas canvas, Size size) {
    final scale = size.shortestSide / 420.0;
    final p = Paint()..blendMode = BlendMode.plus;
    for (final st in stars) {
      p.color = Colors.white.withValues(alpha: st.a);
      canvas.drawCircle(
          Offset(st.fx * size.width, st.fy * size.height), st.r * scale, p);
    }
  }

  void _paintVignette(Canvas canvas, Size size, double cx, double cy) {
    final radius = size.longestSide * 0.72;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.black.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.6),
          ],
          stops: const [0.55, 1.0],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: radius)),
    );
  }

  // --- One volume ------------------------------------------------------------

  void _drawVolume(Canvas canvas, _Volume v, double t, double cx, double cy,
      double s, double cyaw, double syaw, double cpit, double spit) {
    final n = v.verts.length;
    if (n == 0) return;

    final px = List<double>.filled(n, 0.0);
    final py = List<double>.filled(n, 0.0);
    final pd = List<double>.filled(n, 0.0);

    // Per-volume base orientation (with optional wobble + continuous spin).
    var rx = v.rx, ry = v.ry + v.spinYRate * t, rz = v.rz;
    if (v.wobbleAmp != 0.0) {
      final w = v.wobbleAmp * math.sin(t * v.wobbleRate + v.wobblePhase);
      if (v.wobbleAxis == 0) {
        rx += w;
      } else if (v.wobbleAxis == 1) {
        ry += w;
      } else {
        rz += w;
      }
    }
    final crz = math.cos(rz), srz = math.sin(rz);
    final crx = math.cos(rx), srx = math.sin(rx);
    final cry = math.cos(ry), sry = math.sin(ry);

    final isSeg = v.kind == _Kind.segment;

    for (var i = 0; i < n; i++) {
      double wx, wy, wz;
      if (isSeg) {
        // Segment vertices are already in world space.
        wx = v.verts[i].x;
        wy = v.verts[i].y;
        wz = v.verts[i].z;
      } else {
        final m = v.verts[i];
        var x = m.x * v.scale.x, y = m.y * v.scale.y, z = m.z * v.scale.z;
        // roll (Z)
        final x1 = x * crz - y * srz;
        final y1 = x * srz + y * crz;
        // pitch (X)
        final y2 = y1 * crx - z * srx;
        final z1 = y1 * srx + z * crx;
        // yaw (Y)
        final x2 = x1 * cry + z1 * sry;
        final z2 = -x1 * sry + z1 * cry;
        wx = x2 + v.center.x;
        wy = y2 + v.center.y;
        wz = z2 + v.center.z;
      }
      // Camera yaw (Y) then pitch (X).
      final camX = wx * cyaw + wz * syaw;
      final camZ = -wx * syaw + wz * cyaw;
      final camY2 = wy * cpit - camZ * spit;
      final camZ2 = wy * spit + camZ * cpit;
      // Orthographic projection (+y up -> screen y down).
      px[i] = cx + camX * s;
      py[i] = cy - camY2 * s;
      pd[i] = camZ2;
    }

    final depthScale = math.max(
        0.05,
        math.max(v.scale.x.abs(), math.max(v.scale.y.abs(), v.scale.z.abs())));

    final base = Paint()
      ..blendMode = BlendMode.plus
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round
      ..strokeWidth = v.lineW;
    final wide = Paint()
      ..blendMode = BlendMode.plus
      ..isAntiAlias = true
      ..strokeWidth = v.lineW + 2.0;

    final e = v.edges;
    for (var k = 0; k < e.length; k += 2) {
      final a = e[k], b = e[k + 1];
      final depth = (pd[a] + pd[b]) * 0.5;
      final d = isSeg
          ? 1.0
          : (0.5 + 0.5 * depth / depthScale).clamp(0.0, 1.0).toDouble();
      final alpha = v.bright * (0.42 + 0.58 * d);
      final p1 = Offset(px[a], py[a]), p2 = Offset(px[b], py[b]);
      if (v.glow) {
        wide.color = Colors.white.withValues(alpha: alpha * 0.26);
        canvas.drawLine(p1, p2, wide);
      }
      base.color = Colors.white.withValues(alpha: alpha);
      canvas.drawLine(p1, p2, base);
    }
  }

  @override
  bool shouldRepaint(covariant _StillLifePainter old) => true;
}

// --- Geometry builders -------------------------------------------------------

/// Surface of revolution from a `[radius, y]` profile, revolved around Y.
_Geom _latheGeom(List<List<double>> prof, int seg) {
  final v = <_V3>[];
  final P = prof.length;
  for (var i = 0; i < P; i++) {
    final r = prof[i][0], y = prof[i][1];
    for (var j = 0; j < seg; j++) {
      final th = 2 * math.pi * j / seg;
      v.add(_V3(r * math.cos(th), y, r * math.sin(th)));
    }
  }
  int idx(int i, int j) => i * seg + (j % seg);
  final e = <int>[];
  for (var i = 0; i < P - 1; i++) {
    for (var j = 0; j < seg; j++) {
      e..add(idx(i, j))..add(idx(i + 1, j)); // lengthwise
    }
  }
  for (var i = 0; i < P; i++) {
    if (prof[i][0] <= 1e-6) continue; // skip degenerate (tip) rings
    for (var j = 0; j < seg; j++) {
      e..add(idx(i, j))..add(idx(i, j + 1)); // ring
    }
  }
  return _Geom(v, e);
}

/// Unit box [-1,1]^3 with `divs` extra horizontal divider loops.
_Geom _boxGeom(int divs) {
  final v = <_V3>[
    const _V3(-1, -1, -1), const _V3(1, -1, -1),
    const _V3(1, 1, -1), const _V3(-1, 1, -1),
    const _V3(-1, -1, 1), const _V3(1, -1, 1),
    const _V3(1, 1, 1), const _V3(-1, 1, 1),
  ];
  final e = <int>[
    0, 1, 1, 2, 2, 3, 3, 0, // back face
    4, 5, 5, 6, 6, 7, 7, 4, // front face
    0, 4, 1, 5, 2, 6, 3, 7, // verticals
  ];
  for (var k = 1; k <= divs; k++) {
    final y = -1 + 2 * k / (divs + 1);
    final base = v.length;
    v..add(_V3(-1, y, -1))..add(_V3(1, y, -1))..add(_V3(1, y, 1))..add(_V3(-1, y, 1));
    e
      ..addAll([base, base + 1, base + 1, base + 2])
      ..addAll([base + 2, base + 3, base + 3, base]);
  }
  return _Geom(v, e);
}

/// Unit UV-sphere: `lon` meridians × `lat` bands. Poles are coincident points.
_Geom _sphereGeom(int lon, int lat) {
  final v = <_V3>[];
  for (var i = 0; i <= lat; i++) {
    final phi = -math.pi / 2 + math.pi * i / lat;
    final cyv = math.sin(phi), r = math.cos(phi);
    for (var j = 0; j < lon; j++) {
      final th = 2 * math.pi * j / lon;
      v.add(_V3(r * math.cos(th), cyv, r * math.sin(th)));
    }
  }
  int idx(int i, int j) => i * lon + (j % lon);
  final e = <int>[];
  for (var i = 0; i < lat; i++) {
    for (var j = 0; j < lon; j++) {
      e..add(idx(i, j))..add(idx(i + 1, j));
    }
  }
  for (var i = 1; i < lat; i++) {
    for (var j = 0; j < lon; j++) {
      e..add(idx(i, j))..add(idx(i, j + 1));
    }
  }
  return _Geom(v, e);
}

/// Unit circle in the XY plane (z = 0), closed loop.
_Geom _ringGeom(int seg) {
  final v = <_V3>[];
  for (var i = 0; i < seg; i++) {
    final th = 2 * math.pi * i / seg;
    v.add(_V3(math.cos(th), math.sin(th), 0));
  }
  final e = <int>[];
  for (var i = 0; i < seg; i++) {
    e..add(i)..add((i + 1) % seg);
  }
  return _Geom(v, e);
}

/// Unit icosahedron (12 vertices), edges found by shortest-distance pairing.
_Geom _icosaGeom() {
  const p = 1.618033988749895;
  final raw = <_V3>[
    _V3(0, 1, p), _V3(0, 1, -p), _V3(0, -1, p), _V3(0, -1, -p),
    _V3(1, p, 0), _V3(1, -p, 0), _V3(-1, p, 0), _V3(-1, -p, 0),
    _V3(p, 0, 1), _V3(p, 0, -1), _V3(-p, 0, 1), _V3(-p, 0, -1),
  ];
  var mx = 0.0;
  for (final q in raw) {
    final d = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
    if (d > mx) mx = d;
  }
  final v = raw.map((q) => _V3(q.x / mx, q.y / mx, q.z / mx)).toList();
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
      if (_dist2(v[i], v[j]) <= thr) e..add(i)..add(j);
    }
  }
  return _Geom(v, e);
}

double _dist2(_V3 a, _V3 b) {
  final dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return dx * dx + dy * dy + dz * dz;
}

/// Tiny geometry holder (vertices + flat edge-pairs). Avoids relying on the
/// Dart 3 records language feature so the file compiles under any SDK
/// language version.
class _Geom {
  final List<_V3> v;
  final List<int> e;
  const _Geom(this.v, this.e);
}