// lib/volume_scene.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Volumes mode.
///
/// A from-scratch reconstruction of the harmonograph "specimen" scene as a set
/// of discrete 3-D **volumes**, arranged so that — viewed head-on — they
/// recompose the original image:
///
///   • a bright pulsing core orb at the centre;
///   • two faint "iris" rings hugging the core;
///   • two large overlapping rings whose intersection forms the eye / lens;
///   • two dense wireframe ellipsoids (top & bottom) standing in for the woven
///     harmonograph lobes — slowly counter-rotating so they shimmer;
///   • a solid bounding oval and a dashed outer oval;
///   • a horizontal axis with bead nodes;
///   • four corner node marks.
///
/// Everything lives in a single [_Volume] scene-graph. Each volume owns its own
/// centre, scale, orientation and style, so individual elements can be picked
/// and manipulated later — for now a swipe orbits the whole scene as one rigid
/// assembly and eases back to the frontal composition.
///
/// **Interaction.** The mechanical arm's horizontal motion yaws the scene and
/// its vertical motion pitches it; a light spring returns it to head-on, so a
/// slow swipe reads as a deliberate turn that reveals the depth of the forms
/// before settling. At rest a tiny ambient sway keeps it alive.
///
/// Rendering is orthographic (so each volume's centre projects exactly to its
/// intended screen position when frontal) with luminous, depth-shaded white
/// line-work over pure black — consistent with the rest of the series.
class VolumeSceneScreen extends StatefulWidget {
  final MotionController motion;
  const VolumeSceneScreen({super.key, required this.motion});

  @override
  State<VolumeSceneScreen> createState() => _VolumeSceneScreenState();
}

// --- Tuning ------------------------------------------------------------------

// Camera spring (returns the scene to head-on after a swipe).
const double _kCamGain = 0.0016; // yaw/pitch velocity per px of drag
const double _kCamReleaseGain = 0.00012; // extra kick per px/s on release
const double _kCamStiff = 2.2; // restoring stiffness
const double _kCamDamp = 1.4; // damping
const double _kCamMax = 0.6; // clamp on yaw/pitch (rad) — keep it readable

// Ambient idle sway (so the frontal scene is never frozen).
const double _kSwayAmp = 0.045; // rad
const double _kSwayF1 = 0.13; // yaw breathing freq
const double _kSwayF2 = 0.097; // pitch breathing freq

// Core orb pulse.
const double _kPulseRate = 0.9; // rad/s
const double _kPulseAmp = 0.06;

// Lobe self-rotation (the shimmer).
const double _kLobeSpin = 0.05; // rad/s (top +, bottom -)

// Fit: fraction of the available half-extent the composition is allowed to use.
const double _kFitMargin = 0.96;

// Scene half-extents in normalised units (used to compute the fit scale).
const double _kSceneHalfW = 0.49;
const double _kSceneHalfH = 0.82;

const int _kStarCount = 70;

class _VolumeSceneScreenState extends State<VolumeSceneScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final math.Random _rng = math.Random();

  late final List<_Volume> _scene;
  late final List<_Star> _stars;

  // Camera state (eased toward the ambient sway baseline).
  double _yaw = 0.0, _pitch = 0.0;
  double _yawVel = 0.0, _pitchVel = 0.0;

  double _elapsed = 0.0;
  double _prevS = 0.0;
  int _lastTick = -1;

  @override
  void initState() {
    super.initState();
    _scene = _buildScene();
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
  void didUpdateWidget(VolumeSceneScreen old) {
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
  // Normalised coordinates: origin at the composition centre, +y up, +z toward
  // the viewer. The painter scales these to fit the screen each frame.

  List<_Volume> _buildScene() {
    final s = <_Volume>[];

    // Two dense lobes (the woven harmonograph clusters) as wireframe ellipsoids,
    // counter-rotating so they shimmer. Drawn first (behind everything).
    s.add(_Volume.sphere(
      center: const _V3(0, 0.42, 0),
      scale: const _V3(0.27, 0.32, 0.20),
      lon: 16,
      lat: 10,
      bright: 0.50,
      spinYRate: _kLobeSpin,
      spinYPhase: 0.0,
    ));
    s.add(_Volume.sphere(
      center: const _V3(0, -0.42, 0),
      scale: const _V3(0.27, 0.32, 0.20),
      lon: 16,
      lat: 10,
      bright: 0.50,
      spinYRate: -_kLobeSpin,
      spinYPhase: math.pi,
    ));

    // The eye / lens: two large flat rings offset left & right; their overlap
    // brackets the core. Faint — the bright crescents emerge where they cross.
    s.add(_Volume.ring(
      center: const _V3(-0.17, 0, 0),
      scale: const _V3(0.36, 0.46, 1),
      seg: 72,
      bright: 0.42,
    ));
    s.add(_Volume.ring(
      center: const _V3(0.17, 0, 0),
      scale: const _V3(0.36, 0.46, 1),
      seg: 72,
      bright: 0.42,
    ));

    // Two iris rings hugging the core.
    s.add(_Volume.ring(
      center: const _V3(0, 0, 0),
      scale: const _V3(0.215, 0.175, 1),
      seg: 64,
      bright: 0.45,
    ));
    s.add(_Volume.ring(
      center: const _V3(0, 0, 0),
      scale: const _V3(0.16, 0.13, 1),
      seg: 64,
      bright: 0.50,
    ));

    // Horizontal axis + bead nodes.
    s.add(_Volume.rod(
      center: const _V3(0, 0, 0),
      halfLen: 0.46,
      bright: 0.45,
      glow: true,
    ));
    for (final x in const [0.085, 0.16, -0.085, -0.16]) {
      s.add(_Volume.node(
        center: _V3(x, 0, 0),
        radius: 0.016,
        bright: 0.6,
        dot: false,
      ));
    }

    // Solid bounding oval + dashed outer oval.
    s.add(_Volume.ring(
      center: const _V3(0, 0, 0),
      scale: const _V3(0.46, 0.78, 1),
      seg: 96,
      bright: 0.55,
      lineW: 1.2,
      glow: true,
    ));
    s.add(_Volume.ring(
      center: const _V3(0, 0, 0),
      scale: const _V3(0.49, 0.82, 1),
      seg: 100,
      bright: 0.5,
      dashed: true,
    ));

    // Four corner node marks (outside the oval).
    for (final c in const [
      _V3(0.40, 0.66, 0),
      _V3(-0.40, 0.66, 0),
      _V3(0.40, -0.66, 0),
      _V3(-0.40, -0.66, 0),
    ]) {
      s.add(_Volume.node(
        center: c,
        radius: 0.026,
        bright: 0.65,
        dot: true,
        glow: true,
      ));
    }

    // The core orb — drawn last so its glow sits on top.
    s.add(_Volume.sphere(
      center: const _V3(0, 0, 0),
      scale: const _V3(0.075, 0.075, 0.075),
      lon: 12,
      lat: 7,
      bright: 0.9,
      isCore: true,
    ));

    return s;
  }

  // --- Gesture (orbit the scene) ---------------------------------------------

  void _onMotion() {
    final m = widget.motion;
    if (m.isDragging && m.updateTick != _lastTick) {
      _lastTick = m.updateTick;
      _yawVel += m.liveDelta.dx * _kCamGain;
      _pitchVel += -m.liveDelta.dy * _kCamGain; // up-swipe tips the top back
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

    // Spring the camera toward a gently breathing baseline rather than to a
    // dead zero, so the head-on scene is alive but stable.
    final yawTarget = _kSwayAmp * math.sin(t * _kSwayF1);
    final pitchTarget = _kSwayAmp * math.sin(t * _kSwayF2 + 1.0);

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
        painter: _ScenePainter(
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

// --- Data --------------------------------------------------------------------

class _V3 {
  final double x, y, z;
  const _V3(this.x, this.y, this.z);
}

enum _Kind { sphere, ring, rod, node }

/// A single manipulable element of the scene. Centre / scale / orientation are
/// mutable so future code can grab one volume and move, scale or spin it.
class _Volume {
  final _Kind kind;
  _V3 center;
  _V3 scale; // (rx, ry, rz) in normalised units
  double spinXRate, spinYRate, spinXPhase, spinYPhase;

  // Style.
  double bright;
  double lineW;
  bool glow;
  bool dashed;
  bool dot;
  bool isCore;

  // Geometry resolution.
  int lon, lat, seg;
  double halfLen; // rod only

  _Volume._({
    required this.kind,
    required this.center,
    required this.scale,
    this.spinXRate = 0.0,
    this.spinYRate = 0.0,
    this.spinXPhase = 0.0,
    this.spinYPhase = 0.0,
    this.bright = 0.5,
    this.lineW = 1.0,
    this.glow = false,
    this.dashed = false,
    this.dot = false,
    this.isCore = false,
    this.lon = 16,
    this.lat = 10,
    this.seg = 64,
    this.halfLen = 0.0,
  });

  factory _Volume.sphere({
    required _V3 center,
    required _V3 scale,
    int lon = 16,
    int lat = 10,
    double bright = 0.5,
    double lineW = 1.0,
    double spinYRate = 0.0,
    double spinYPhase = 0.0,
    bool isCore = false,
  }) =>
      _Volume._(
        kind: _Kind.sphere,
        center: center,
        scale: scale,
        lon: lon,
        lat: lat,
        bright: bright,
        lineW: lineW,
        spinYRate: spinYRate,
        spinYPhase: spinYPhase,
        glow: isCore,
        isCore: isCore,
      );

  factory _Volume.ring({
    required _V3 center,
    required _V3 scale,
    int seg = 64,
    double bright = 0.5,
    double lineW = 1.0,
    bool glow = false,
    bool dashed = false,
  }) =>
      _Volume._(
        kind: _Kind.ring,
        center: center,
        scale: scale,
        seg: seg,
        bright: bright,
        lineW: lineW,
        glow: glow,
        dashed: dashed,
      );

  factory _Volume.rod({
    required _V3 center,
    required double halfLen,
    double bright = 0.5,
    bool glow = false,
  }) =>
      _Volume._(
        kind: _Kind.rod,
        center: center,
        scale: const _V3(1, 1, 1),
        halfLen: halfLen,
        bright: bright,
        glow: glow,
        lineW: 1.0,
      );

  factory _Volume.node({
    required _V3 center,
    required double radius,
    double bright = 0.6,
    bool dot = false,
    bool glow = false,
  }) =>
      _Volume._(
        kind: _Kind.node,
        center: center,
        scale: _V3(radius, radius, 1),
        seg: 22,
        bright: bright,
        dot: dot,
        glow: glow,
      );
}

class _Star {
  final double fx, fy, r, a;
  const _Star(this.fx, this.fy, this.r, this.a);
}

// --- Painter -----------------------------------------------------------------

class _ScenePainter extends CustomPainter {
  final List<_Volume> scene;
  final List<_Star> stars;
  final double Function() yawOf;
  final double Function() pitchOf;
  final double Function() timeOf;

  _ScenePainter({
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
    // Uniform fit: keep the composition's aspect and fit it to whichever screen
    // dimension binds — works for portrait and landscape alike.
    final halfW = size.width / 2, halfH = size.height / 2;
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

  // --- Atmosphere ------------------------------------------------------------

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
    // Build model geometry (unit forms).
    final List<_V3> verts;
    final List<int> edges;
    switch (v.kind) {
      case _Kind.sphere:
        final g = _sphereGeom(v.lon, v.lat);
        verts = g.v;
        edges = g.e;
        break;
      case _Kind.ring:
      case _Kind.node:
        final g = _ringGeom(v.seg);
        verts = g.v;
        edges = g.e;
        break;
      case _Kind.rod:
        verts = const [_V3(-1, 0, 0), _V3(1, 0, 0)];
        edges = const [0, 1];
        break;
    }

    // Own rotation (about the volume's own centre).
    final ox = v.spinXPhase + v.spinXRate * t;
    final oy = v.spinYPhase + v.spinYRate * t;
    final cox = math.cos(ox), sox = math.sin(ox);
    final coy = math.cos(oy), soy = math.sin(oy);

    final sx = v.kind == _Kind.rod ? v.halfLen : v.scale.x;
    final sy = v.scale.y;
    final sz = v.scale.z;

    final n = verts.length;
    final px = List<double>.filled(n, 0.0);
    final py = List<double>.filled(n, 0.0);
    final pd = List<double>.filled(n, 0.0); // view-space depth (normalised)

    for (var i = 0; i < n; i++) {
      final m = verts[i];
      // scale
      var x = m.x * sx, y = m.y * sy, z = m.z * sz;
      // own rotate (Y then X)
      final x1 = x * coy + z * soy;
      final z1 = -x * soy + z * coy;
      final y1 = y;
      final y2 = y1 * cox - z1 * sox;
      final z2 = y1 * sox + z1 * cox;
      x = x1;
      y = y2;
      z = z2;
      // translate to world
      x += v.center.x;
      y += v.center.y;
      z += v.center.z;
      // camera yaw (Y) then pitch (X)
      final wx = x * cyaw + z * syaw;
      final wz = -x * syaw + z * cyaw;
      final wy = y;
      final vy = wy * cpit - wz * spit;
      final vz = wy * spit + wz * cpit;
      // orthographic projection (+y up -> screen y down)
      px[i] = cx + wx * s;
      py[i] = cy - vy * s;
      pd[i] = vz;
    }

    // Per-volume depth normaliser for front/back shading.
    final depthScale = math.max(
        0.06, math.max(v.scale.x.abs(), math.max(v.scale.y.abs(), v.scale.z.abs())));

    if (v.isCore) {
      _paintCoreGlow(canvas, Offset(cx, cy), v.scale.x * s, t);
    }
    if (v.glow && !v.isCore) {
      final r = (v.kind == _Kind.rod ? v.halfLen : v.scale.x) * s;
      _glow(canvas, Offset(cx, cy), math.max(8.0, r * 0.5), 0.05 * v.bright);
    }

    // Draw edges.
    final base = Paint()
      ..blendMode = BlendMode.plus
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round
      ..strokeWidth = v.lineW;

    final wide = Paint()
      ..blendMode = BlendMode.plus
      ..isAntiAlias = true
      ..strokeWidth = v.lineW + 2.0;

    final eCount = edges.length;
    for (var k = 0; k < eCount; k += 2) {
      // Dashed rings skip alternate segments.
      if (v.dashed && ((k ~/ 2) & 1) == 1) continue;
      final a = edges[k], b = edges[k + 1];
      final depth = (pd[a] + pd[b]) * 0.5;
      final d = (0.5 + 0.5 * depth / depthScale).clamp(0.0, 1.0).toDouble();
      final alpha = v.bright * (0.42 + 0.58 * d);
      final p1 = Offset(px[a], py[a]), p2 = Offset(px[b], py[b]);
      if (v.glow || v.isCore) {
        wide.color = Colors.white.withValues(alpha: alpha * 0.28);
        canvas.drawLine(p1, p2, wide);
      }
      base.color = Colors.white.withValues(alpha: alpha);
      canvas.drawLine(p1, p2, base);
    }

    // Node centre dot.
    if (v.kind == _Kind.node && v.dot) {
      canvas.drawCircle(
        Offset(cx + v.center.x * s, cy - v.center.y * s),
        math.max(1.3, v.scale.x * s * 0.18),
        Paint()
          ..blendMode = BlendMode.plus
          ..color = Colors.white.withValues(alpha: v.bright),
      );
    }
  }

  /// The luminous, gently pulsing core orb: a soft halo, a bright solid centre,
  /// then the wire sphere is drawn over it by the edge loop above.
  void _paintCoreGlow(Canvas canvas, Offset c, double rPx, double t) {
    final pulse = 1.0 + _kPulseAmp * math.sin(t * _kPulseRate);
    final r = rPx * pulse;
    _glow(canvas, c, r * 2.4, 0.28);
    canvas.drawCircle(
      c,
      r * 0.9,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.95),
            Colors.white.withValues(alpha: 0.65),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.9)),
    );
  }

  void _glow(Canvas canvas, Offset c, double r, double alpha) {
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: alpha),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
  }

  @override
  bool shouldRepaint(covariant _ScenePainter old) => true;
}

// --- Geometry ----------------------------------------------------------------

/// Unit UV-sphere wireframe: `lon` meridians × `lat` latitude bands.
/// Returns (vertices, flat edge-pairs). Poles are single coincident points so
/// the meridians converge cleanly.
_Geom _sphereGeom(int lon, int lat) {
  final v = <_V3>[];
  // rings i = 0..lat (i=0 south pole, i=lat north pole)
  for (var i = 0; i <= lat; i++) {
    final phi = -math.pi / 2 + math.pi * i / lat; // -90°..+90°
    final cy = math.sin(phi);
    final r = math.cos(phi);
    for (var j = 0; j < lon; j++) {
      final th = 2 * math.pi * j / lon;
      v.add(_V3(r * math.cos(th), cy, r * math.sin(th)));
    }
  }
  int idx(int i, int j) => i * lon + (j % lon);
  final e = <int>[];
  // meridian edges (connect ring i to i+1)
  for (var i = 0; i < lat; i++) {
    for (var j = 0; j < lon; j++) {
      e..add(idx(i, j))..add(idx(i + 1, j));
    }
  }
  // latitude edges (skip the pole rings, which are degenerate)
  for (var i = 1; i < lat; i++) {
    for (var j = 0; j < lon; j++) {
      e..add(idx(i, j))..add(idx(i, j + 1));
    }
  }
  return _Geom(v, e);
}

/// Unit circle in the XY plane (z = 0), `seg` segments, closed loop.
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

/// Tiny geometry holder (vertices + flat edge-pairs). Avoids relying on the
/// Dart 3 records language feature so the file compiles under any SDK
/// language version.
class _Geom {
  final List<_V3> v;
  final List<int> e;
  const _Geom(this.v, this.e);
}