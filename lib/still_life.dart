// lib/still_life.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Still Life mode — "cloud + whirlwind".
///
/// The vocabulary of the original still-life render (cones, flared horns,
/// spindle pods, teardrops, rods, balls, bars and knobbly nubs) is scattered as
/// a slowly-tumbling **random cloud** of luminous wireframe volumes on pure
/// black. At rest each object floats near its randomly-assigned home position,
/// held there by a soft spring, turning gently on its own axes.
///
/// **Interaction — the whirlwind.** A swipe pumps "energy" into the field. While
/// that energy is high the objects are caught in a gentle vortex: a tangential
/// swirl about the vertical axis, a little lift, and per-object turbulence, and
/// every object tumbles faster. The energy then decays, the swirl fades, and the
/// home-springs draw everything back — so the chaos blooms and then **settles**.
/// Longer / faster swipes inject more energy (good for slow mechanical-arm
/// swipes, which accumulate it steadily); the horizontal direction of the swipe
/// sets the spin direction of the vortex.
///
/// Rendering is orthographic with additive white line-work, depth-shaded per
/// object, over a faint starfield and vignette — consistent with the series.
class StillLifeScreen extends StatefulWidget {
  final MotionController motion;
  const StillLifeScreen({super.key, required this.motion});

  @override
  State<StillLifeScreen> createState() => _StillLifeScreenState();
}

// --- Tuning ------------------------------------------------------------------

// Cloud.
const int _kCloudCount = 30; // number of objects in the cloud

// Home-spring (pulls each object back to rest -> "stabilize").
const double _kSpring = 4.0; // restoring stiffness
const double _kDamp = 1.6; // velocity damping
const double _kVMax = 3.0; // clamp on object speed (normalised units/s)
const double _kPosBound = 1.45; // soft world bound

// Whirlwind (active in proportion to energy).
const double _kSwirl = 6.0; // tangential vortex strength
const double _kLift = 1.0; // upward lift
const double _kTurb = 2.2; // per-object turbulence
const double _kSpinBoost = 4.0; // how much faster objects tumble at full energy

// Energy (pumped by swipes, decays on its own).
const double _kEnergyTau = 2.5; // s — whirlwind persistence
const double _kEnergyMax = 1.6;
const double _kPump = 0.004; // energy per px of drag
const double _kRelease = 0.0006; // energy per px/s of release velocity

// Ambient camera sway (slow parallax so the cloud has depth, not gesture-bound).
const double _kSwayYaw = 0.12;
const double _kSwayPitch = 0.05;
const double _kSwayFYaw = 0.05;
const double _kSwayFPitch = 0.037;
const double _kPitchBias = -0.03;

// Fit.
const double _kFitMargin = 0.94;
const double _kSceneHalfW = 0.66;
const double _kSceneHalfH = 1.04;

const int _kStarCount = 70;

class _StillLifeScreenState extends State<StillLifeScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final math.Random _rng = math.Random();

  late final List<_Volume> _cloud;
  late final List<_Star> _stars;

  double _energy = 0.0; // whirlwind energy
  double _swirlSign = 1.0; // vortex direction (set by horizontal swipe)
  double _elapsed = 0.0, _prevS = 0.0;
  int _lastTick = -1;

  @override
  void initState() {
    super.initState();
    _cloud = _buildCloud(_rng);
    for (final o in _cloud) {
      o.bake();
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

  // --- Cloud generation ------------------------------------------------------
  //
  // Normalised coordinates: origin at centre, +y up, +z toward the viewer.

  /// Centre-weighted "gaussian-ish" sample in roughly [-1, 1].
  double _g() =>
      (_rng.nextDouble() + _rng.nextDouble() + _rng.nextDouble() - 1.5) / 1.5;

  double _signed(double lo, double hi) =>
      (_rng.nextBool() ? 1.0 : -1.0) * (lo + _rng.nextDouble() * (hi - lo));

  List<_Volume> _buildCloud(math.Random rng) {
    // Weighted palette of object kinds (the still-life vocabulary).
    const palette = <String>[
      'pod', 'pod', 'pod', 'pod', 'pod', 'pod', //
      'spear', 'spear', 'spear', 'spear', //
      'stick', 'stick', 'stick', 'stick', //
      'cone', 'cone', 'cone', //
      'ball', 'ball', 'ball', //
      'nub', 'nub', 'nub', //
      'ring', 'ring', 'ring', //
      'horn', 'horn', //
      'box', 'box', //
    ];

    final list = <_Volume>[];
    for (var i = 0; i < _kCloudCount; i++) {
      final type = palette[rng.nextInt(palette.length)];
      final o = _Volume();
      _configureType(o, type, rng);

      // Random home in a centre-weighted cloud, taller than wide (portrait).
      o.hx = (_g() * 0.42).clamp(-0.52, 0.52).toDouble();
      o.hy = (_g() * 0.62).clamp(-0.92, 0.92).toDouble();
      o.hz = (_g() * 0.26).clamp(-0.34, 0.34).toDouble();
      o.px = o.hx;
      o.py = o.hy;
      o.pz = o.hz;

      // Random initial orientation + gentle idle tumble.
      o.ax = rng.nextDouble() * 2 * math.pi;
      o.ay = rng.nextDouble() * 2 * math.pi;
      o.axRate = _signed(0.05, 0.22);
      o.ayRate = _signed(0.05, 0.22);

      // Per-object turbulence character.
      o.f1 = 0.5 + rng.nextDouble() * 0.9;
      o.f2 = 0.5 + rng.nextDouble() * 0.9;
      o.f3 = 0.5 + rng.nextDouble() * 0.9;
      o.ph1 = rng.nextDouble() * 6.283;
      o.ph2 = rng.nextDouble() * 6.283;
      o.ph3 = rng.nextDouble() * 6.283;

      o.bright = 0.45 + rng.nextDouble() * 0.25;
      o.glow = rng.nextDouble() < 0.45;

      list.add(o);
    }
    return list;
  }

  /// Set geometry + size for a given object type.
  void _configureType(_Volume o, String type, math.Random rng) {
    double r() => rng.nextDouble();
    switch (type) {
      case 'pod':
        o.kind = _Kind.lathe;
        o.profile = _podProfile;
        o.seg = 10;
        final rad = 0.045 + r() * 0.02;
        o.setScale(rad, 0.07 + r() * 0.06, rad);
        break;
      case 'spear':
        o.kind = _Kind.lathe;
        o.profile = _spearProfile;
        o.seg = 10;
        final rad = 0.05 + r() * 0.02;
        o.setScale(rad, 0.06 + r() * 0.05, rad);
        break;
      case 'stick':
        o.kind = _Kind.lathe;
        o.profile = _stickProfile;
        o.seg = 8;
        final rad = 0.05 + r() * 0.02;
        o.setScale(rad, 0.06 + r() * 0.07, rad);
        break;
      case 'cone':
        o.kind = _Kind.lathe;
        o.profile = _coneProfile;
        o.seg = 14;
        final rad = 0.06 + r() * 0.03;
        o.setScale(rad, 0.09 + r() * 0.05, rad);
        break;
      case 'horn':
        o.kind = _Kind.lathe;
        o.profile = _hornProfile;
        o.seg = 12;
        final rad = 0.10 + r() * 0.04;
        o.setScale(rad, 0.10 + r() * 0.04, rad);
        o.glowBiasHigh = true;
        break;
      case 'ball':
        o.kind = _Kind.sphere;
        o.lon = 10;
        o.lat = 6;
        final rad = 0.045 + r() * 0.03;
        o.setScale(rad, rad, rad);
        break;
      case 'ring':
        o.kind = _Kind.ring;
        o.seg = 28;
        final rad = 0.05 + r() * 0.04;
        o.setScale(rad, rad, rad);
        break;
      case 'box':
        o.kind = _Kind.box;
        o.divs = r() < 0.5 ? 1 : 0;
        o.setScale(0.04 + r() * 0.02, 0.10 + r() * 0.06, 0.03 + r() * 0.02);
        break;
      case 'nub':
      default:
        o.kind = _Kind.icosa;
        final rad = 0.05 + r() * 0.03;
        // Slightly irregular so it reads as a knobbly lump.
        o.setScale(rad * (0.8 + r() * 0.4), rad * (0.8 + r() * 0.4),
            rad * (0.8 + r() * 0.4));
        break;
    }
  }

  // --- Gesture (pump the whirlwind) ------------------------------------------

  void _onMotion() {
    final m = widget.motion;
    if (m.isDragging && m.updateTick != _lastTick) {
      _lastTick = m.updateTick;
      _energy =
          (_energy + m.liveDelta.distance * _kPump).clamp(0.0, _kEnergyMax).toDouble();
      if (m.liveDelta.dx.abs() > 0.01) {
        _swirlSign = m.liveDelta.dx > 0 ? 1.0 : -1.0;
      }
    } else if (!m.isDragging && m.velocity != Offset.zero) {
      _energy = (_energy + m.velocity.distance * _kRelease)
          .clamp(0.0, _kEnergyMax)
          .toDouble();
      if (m.velocity.dx.abs() > 1.0) {
        _swirlSign = m.velocity.dx > 0 ? 1.0 : -1.0;
      }
    }
  }

  // --- Integration -----------------------------------------------------------

  void _onTick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    final dt = (t - _prevS).clamp(0.0, 0.05).toDouble();
    _prevS = t;
    _elapsed = t;

    // Whirlwind energy decays toward calm.
    _energy *= math.exp(-dt / _kEnergyTau);
    final e = _energy;
    final spinBoost = 1.0 + e * _kSpinBoost;

    for (final o in _cloud) {
      // Tangential swirl about the vertical (Y) axis: t = (-z, 0, x).
      final tx = -o.pz, tz = o.px;

      // Per-object turbulence (only meaningful while energy is high).
      final turbX = math.sin(t * o.f1 + o.ph1);
      final turbY = math.sin(t * o.f2 + o.ph2);
      final turbZ = math.cos(t * o.f3 + o.ph3);

      // Acceleration = home-spring + damping + (energy * vortex).
      final ax = _kSpring * (o.hx - o.px) -
          _kDamp * o.vx +
          e * (_swirlSign * _kSwirl * tx + _kTurb * turbX);
      final ay = _kSpring * (o.hy - o.py) -
          _kDamp * o.vy +
          e * (_kLift + _kTurb * turbY);
      final az = _kSpring * (o.hz - o.pz) -
          _kDamp * o.vz +
          e * (_swirlSign * _kSwirl * tz + _kTurb * turbZ);

      o.vx += ax * dt;
      o.vy += ay * dt;
      o.vz += az * dt;

      // Clamp speed for stability under sustained swiping.
      final sp = math.sqrt(o.vx * o.vx + o.vy * o.vy + o.vz * o.vz);
      if (sp > _kVMax) {
        final k = _kVMax / sp;
        o.vx *= k;
        o.vy *= k;
        o.vz *= k;
      }

      o.px += o.vx * dt;
      o.py += o.vy * dt;
      o.pz += o.vz * dt;

      // Soft world bounds: stop a component at the wall.
      if (o.px.abs() > _kPosBound) {
        o.px = o.px.clamp(-_kPosBound, _kPosBound).toDouble();
        o.vx = 0;
      }
      if (o.py.abs() > _kPosBound) {
        o.py = o.py.clamp(-_kPosBound, _kPosBound).toDouble();
        o.vy = 0;
      }
      if (o.pz.abs() > _kPosBound) {
        o.pz = o.pz.clamp(-_kPosBound, _kPosBound).toDouble();
        o.vz = 0;
      }

      // Tumble — faster mid-whirlwind, back to a gentle idle as it settles.
      o.ax += o.axRate * spinBoost * dt;
      o.ay += o.ayRate * spinBoost * dt;
    }

    _frame.value += 1;
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _CloudPainter(
          cloud: _cloud,
          stars: _stars,
          repaint: _frame,
          timeOf: () => _elapsed,
        ),
      ),
    );
  }
}

// --- Lathe profiles ([radius, y]; revolved around Y) -------------------------

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

const List<List<double>> _stickProfile = [
  [0.07, -1.0],
  [0.07, 1.0],
];

// --- Data --------------------------------------------------------------------

class _V3 {
  final double x, y, z;
  const _V3(this.x, this.y, this.z);
}

enum _Kind { lathe, box, sphere, ring, icosa }

/// One cloud object: geometry + size + full dynamic state (home, position,
/// velocity, tumble). Every field is mutable so the physics can drive it and so
/// individual objects can be manipulated later.
class _Volume {
  _Kind kind = _Kind.icosa;

  // Geometry params.
  List<List<double>> profile = const [];
  int seg = 16, lon = 10, lat = 6, divs = 0;

  // Size (rx, ry, rz).
  double sx = 0.05, sy = 0.05, sz = 0.05;

  // Dynamic state.
  double hx = 0, hy = 0, hz = 0; // home
  double px = 0, py = 0, pz = 0; // position
  double vx = 0, vy = 0, vz = 0; // velocity
  double ax = 0, ay = 0; // tumble angles
  double axRate = 0, ayRate = 0; // idle tumble rates

  // Turbulence character.
  double f1 = 1, f2 = 1, f3 = 1, ph1 = 0, ph2 = 0, ph3 = 0;

  // Style.
  double bright = 0.5;
  double lineW = 1.0;
  bool glow = false;
  bool glowBiasHigh = false; // unused hook; kept for tuning per type

  // Baked geometry.
  List<_V3> verts = const [];
  List<int> edges = const [];

  void setScale(double x, double y, double z) {
    sx = x;
    sy = y;
    sz = z;
  }

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
    }
  }
}

class _Star {
  final double fx, fy, r, a;
  const _Star(this.fx, this.fy, this.r, this.a);
}

// --- Painter -----------------------------------------------------------------

class _CloudPainter extends CustomPainter {
  final List<_Volume> cloud;
  final List<_Star> stars;
  final double Function() timeOf;

  _CloudPainter({
    required this.cloud,
    required this.stars,
    required Listenable repaint,
    required this.timeOf,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    final cx = size.width / 2, cy = size.height / 2;
    final s = math.min(
      (size.width / 2) * _kFitMargin / _kSceneHalfW,
      (size.height / 2) * _kFitMargin / _kSceneHalfH,
    );

    _paintStars(canvas, size);
    _paintVignette(canvas, size, cx, cy);

    // Slow ambient camera sway (parallax only — gestures drive the whirlwind).
    final t = timeOf();
    final yaw = _kSwayYaw * math.sin(t * _kSwayFYaw * 2 * math.pi);
    final pitch =
        _kPitchBias + _kSwayPitch * math.sin(t * _kSwayFPitch * 2 * math.pi);
    final cyaw = math.cos(yaw), syaw = math.sin(yaw);
    final cpit = math.cos(pitch), spit = math.sin(pitch);

    for (final o in cloud) {
      _drawObject(canvas, o, cx, cy, s, cyaw, syaw, cpit, spit);
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

  void _drawObject(Canvas canvas, _Volume o, double cx, double cy, double s,
      double cyaw, double syaw, double cpit, double spit) {
    final n = o.verts.length;
    if (n == 0) return;

    final cax = math.cos(o.ax), sax = math.sin(o.ax);
    final cay = math.cos(o.ay), say = math.sin(o.ay);

    final px = List<double>.filled(n, 0.0);
    final py = List<double>.filled(n, 0.0);
    final pd = List<double>.filled(n, 0.0);

    for (var i = 0; i < n; i++) {
      final m = o.verts[i];
      // scale
      var x = m.x * o.sx, y = m.y * o.sy, z = m.z * o.sz;
      // tumble: rotate X then Y
      final y1 = y * cax - z * sax;
      final z1 = y * sax + z * cax;
      final x1 = x;
      final x2 = x1 * cay + z1 * say;
      final z2 = -x1 * say + z1 * cay;
      final y2 = y1;
      // translate to current position
      final wx = x2 + o.px;
      final wy = y2 + o.py;
      final wz = z2 + o.pz;
      // camera yaw then pitch
      final camX = wx * cyaw + wz * syaw;
      final camZ = -wx * syaw + wz * cyaw;
      final camY2 = wy * cpit - camZ * spit;
      final camZ2 = wy * spit + camZ * cpit;
      // orthographic projection (+y up -> screen y down)
      px[i] = cx + camX * s;
      py[i] = cy - camY2 * s;
      pd[i] = camZ2;
    }

    final depthScale =
        math.max(0.05, math.max(o.sx.abs(), math.max(o.sy.abs(), o.sz.abs())));

    final base = Paint()
      ..blendMode = BlendMode.plus
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round
      ..strokeWidth = o.lineW;
    final wide = Paint()
      ..blendMode = BlendMode.plus
      ..isAntiAlias = true
      ..strokeWidth = o.lineW + 2.0;

    final e = o.edges;
    for (var k = 0; k < e.length; k += 2) {
      final a = e[k], b = e[k + 1];
      final depth = (pd[a] + pd[b]) * 0.5;
      final d = (0.5 + 0.5 * depth / depthScale).clamp(0.0, 1.0).toDouble();
      final alpha = o.bright * (0.42 + 0.58 * d);
      final p1 = Offset(px[a], py[a]), p2 = Offset(px[b], py[b]);
      if (o.glow) {
        wide.color = Colors.white.withValues(alpha: alpha * 0.26);
        canvas.drawLine(p1, p2, wide);
      }
      base.color = Colors.white.withValues(alpha: alpha);
      canvas.drawLine(p1, p2, base);
    }
  }

  @override
  bool shouldRepaint(covariant _CloudPainter old) => true;
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
      e..add(idx(i, j))..add(idx(i + 1, j));
    }
  }
  for (var i = 0; i < P; i++) {
    if (prof[i][0] <= 1e-6) continue;
    for (var j = 0; j < seg; j++) {
      e..add(idx(i, j))..add(idx(i, j + 1));
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
    0, 1, 1, 2, 2, 3, 3, 0,
    4, 5, 5, 6, 6, 7, 7, 4,
    0, 4, 1, 5, 2, 6, 3, 7,
  ];
  for (var k = 1; k <= divs; k++) {
    final y = -1 + 2 * k / (divs + 1);
    final b = v.length;
    v
      ..add(_V3(-1, y, -1))
      ..add(_V3(1, y, -1))
      ..add(_V3(1, y, 1))
      ..add(_V3(-1, y, 1));
    e
      ..addAll([b, b + 1, b + 1, b + 2])
      ..addAll([b + 2, b + 3, b + 3, b]);
  }
  return _Geom(v, e);
}

/// Unit UV-sphere: `lon` meridians × `lat` bands.
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

/// Unit icosahedron (12 vertices), edges via shortest-distance pairing.
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
/// Dart 3 records language feature so the file compiles under any SDK language
/// version.
class _Geom {
  final List<_V3> v;
  final List<int> e;
  const _Geom(this.v, this.e);
}