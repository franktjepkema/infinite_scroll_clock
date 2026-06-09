// lib/glitch_art.dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Glitch Art mode.
///
/// **The look.** A base layer of soft, saturated colour fields drifts slowly
/// across a pure-black field (the same family of blobs as Color Art). On top
/// sits a datamosh-style glitch layer built from a handful of recognisable
/// operators — hard colour quantisation into a punchy near-neon palette,
/// ordered-dither dot-matrix checkerboards, vertical "comb" smears that drip
/// columns downward, horizontal scanline tears with RGB channel splitting,
/// rectangular block displacement, and black drop-outs that eat holes in the
/// image.
///
/// **Idle vs. reaction.** At rest the field floats and the glitch is gentle
/// and slowly reshuffling (a low resting `chaos`). A swipe drives `chaos` up
/// dramatically — more displacement, more shredding, channel tearing, faster
/// region reshuffle — then it eases back down to idle.
///
/// **Tuned for the mechanical arm.** The arm swipes *slowly*, so the reaction
/// must not depend on finger-speed. Two mechanisms make a slow swipe land
/// hard: (1) while a gesture is in progress `chaos` ramps with how far the arm
/// has travelled toward a commit, and (2) every committed minute fires a full
/// dramatic spike and reshuffles the glitch regions — the definitive "the
/// swiper came" event. Forward and backward commits shred in opposite
/// directions and warm/cool the palette, so the two directions read
/// differently.
///
/// **Pipeline.** Everything is computed on a small low-resolution pixel buffer
/// (chunky cells, sized from the screen), then uploaded to a [ui.Image] and
/// drawn up to full size with [FilterQuality.none] — crisp blocky pixels and a
/// tiny per-frame cost regardless of screen resolution. Decoding is pipelined
/// (one frame may be in flight) so the work stays bounded and the mode holds
/// 60 fps in either orientation.

// --- Tuning ------------------------------------------------------------------
// Everything you'd reach for to change the character lives here.

const int _kCellPx = 4; // on-screen size of one buffer cell (bigger = chunkier)
const int _kMaxBufDim = 240; // cap on offscreen buffer resolution (perf)

const double _kIdleChaos = 0.07; // resting glitch level when untouched
const double _kChaosTau = 1.15; // s — how slowly a swipe spike decays to idle
const double _kDragTau = 0.45; // s — decay of the directional smear

const int _kBlobCount = 5;
const double _kHueDriftDegPerS = 4.5; // never strictly static

const int _kQuantLevels = 4; // posterize steps per channel (crushes with chaos)
const double _kSatBoost = 1.7; // saturation push for the neon snap
const double _kDitherCoverage = 0.42; // fraction of regions as dot-matrix
const double _kCombCoverage = 0.30; // column bands that drip vertically
const double _kTearCoverage = 0.16; // row bands that shear horizontally
const double _kBlockCoverage = 0.10; // coarse blocks that displace

class GlitchArtScreen extends StatefulWidget {
  final MotionController motion;
  const GlitchArtScreen({super.key, required this.motion});

  @override
  State<GlitchArtScreen> createState() => _GlitchArtScreenState();
}

class _GlitchArtScreenState extends State<GlitchArtScreen>
    with SingleTickerProviderStateMixin {
  // --- Frame driver ----------------------------------------------------------
  late final Ticker _ticker;
  // Bumped whenever a freshly decoded image is ready; the painter listens.
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final math.Random _rng = math.Random();

  // --- Pixel buffers ---------------------------------------------------------
  int _w = 0, _h = 0; // buffer dimensions in cells
  Uint8List? _field; // base colour field, RGBA
  Uint8List? _pixels; // final glitched frame, RGBA
  ui.Image? _image; // most recent decoded frame
  bool _decoding = false; // a decode is in flight (pipeline guard)

  // --- Timing ----------------------------------------------------------------
  double _prevElapsedS = 0.0;
  double _elapsedS = 0.0;
  double _hueDrift = 0.0;

  // --- Dynamics --------------------------------------------------------------
  double _chaos = _kIdleChaos;
  double _dragX = 0.0, _dragY = 0.0; // directional smear (buffer cells), decays
  int _commitSalt = 0; // reshuffles all glitch regions on each commit

  // --- Gesture bookkeeping ---------------------------------------------------
  bool _wasDragging = false;
  int _lastUpdateTick = -1;
  int _lastCommit = 0;
  bool _isLandscape = true;
  double _dim = 1.0; // primary-axis screen dimension (for the chaos ramp)
  Size _size = Size.zero;

  // --- Colour field ----------------------------------------------------------
  late final List<_Blob> _blobs;
  // Per-frame scratch for blob positions/radii/colours (allocated once).
  late final Float64List _bx;
  late final Float64List _by;
  late final Float64List _br;
  late final Float64List _brgb; // blobCount * 3 (r,g,b in 0..1)

  // Ordered-dither thresholds (Bayer 4×4), precomputed to 0..1.
  static final List<double> _bayer = <int>[
    0, 8, 2, 10, //
    12, 4, 14, 6, //
    3, 11, 1, 9, //
    15, 7, 13, 5,
  ].map((v) => (v + 0.5) / 16.0).toList(growable: false);

  @override
  void initState() {
    super.initState();
    _blobs = _initBlobs();
    _bx = Float64List(_kBlobCount);
    _by = Float64List(_kBlobCount);
    _br = Float64List(_kBlobCount);
    _brgb = Float64List(_kBlobCount * 3);
    _lastCommit = widget.motion.committedScrolls;
    widget.motion.addListener(_onMotion);
    _ticker = createTicker(_onTick)..start();
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
      _allocBuffers(size);
    }
  }

  @override
  void didUpdateWidget(GlitchArtScreen old) {
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
    _image?.dispose();
    _image = null;
    _frame.dispose();
    super.dispose();
  }

  // --- Setup -----------------------------------------------------------------

  List<_Blob> _initBlobs() {
    return List<_Blob>.generate(
      _kBlobCount,
      (i) => _Blob(
        px: _rng.nextDouble() * 73 + 60, // orbit divisors (period-like)
        py: _rng.nextDouble() * 97 + 60,
        rx: 0.26 + _rng.nextDouble() * 0.18, // orbit reach (fraction of W/H)
        ry: 0.26 + _rng.nextDouble() * 0.18,
        base: 0.5 + _rng.nextDouble() * 0.5, // base radius (fraction of short)
        breathP: 19 + _rng.nextDouble() * 22,
        breathPh: _rng.nextDouble() * 2 * math.pi,
        hue: _rng.nextDouble() * 360,
      ),
      growable: false,
    );
  }

  void _allocBuffers(Size size) {
    final cell = _kCellPx.toDouble();
    final w = (size.width / cell).round().clamp(40, _kMaxBufDim);
    final h = (size.height / cell).round().clamp(40, _kMaxBufDim);
    _w = w;
    _h = h;
    _field = Uint8List(w * h * 4);
    _pixels = Uint8List(w * h * 4);
    // A decode for the previous size (if any) becomes irrelevant; let the next
    // tick render fresh.
    _decoding = false;
  }

  // --- Continuous integration ------------------------------------------------

  void _onTick(Duration elapsed) {
    final newElapsedS = elapsed.inMicroseconds / 1e6;
    final dt = (newElapsedS - _prevElapsedS).clamp(0.0, 0.05);
    _prevElapsedS = newElapsedS;
    _elapsedS = newElapsedS;

    _hueDrift += dt * _kHueDriftDegPerS;

    final dragging = widget.motion.isDragging;

    if (dragging && _dim > 0) {
      // While the arm is mid-swipe, ramp chaos with travel toward a commit, so
      // even a slow swipe builds to a dramatic state (speed-independent).
      final primary = _isLandscape
          ? widget.motion.gestureTotal.dx
          : -widget.motion.gestureTotal.dy;
      var progress = primary.abs() / _dim;
      if (progress > 1.0) progress = 1.0;
      final ramp = _kIdleChaos + progress * 0.9;
      if (ramp > _chaos) _chaos = ramp;
    } else {
      // Ease chaos back toward the resting level once the swipe is over.
      _chaos = _kIdleChaos + (_chaos - _kIdleChaos) * math.exp(-dt / _kChaosTau);
    }

    // The directional smear always relaxes back to centre.
    final dragDecay = math.exp(-dt / _kDragTau);
    _dragX *= dragDecay;
    _dragY *= dragDecay;

    // Produce a frame only when buffers are ready and no decode is in flight.
    if (_w > 0 && _field != null && !_decoding) {
      _renderField();
      _renderGlitch(_chaos, _dragX, _dragY, _elapsedS);
      _kickDecode();
    }
  }

  // --- Discrete motion handling ----------------------------------------------

  void _onMotion() {
    final m = widget.motion;

    if (m.isDragging && !_wasDragging) {
      _wasDragging = true;
    } else if (!m.isDragging && _wasDragging) {
      _wasDragging = false;
    }

    // Live drag: accumulate a directional smear and let fast finger swipes add
    // chaos directly (the slow mechanical arm is handled by the ramp + commit).
    if (m.isDragging && m.updateTick != _lastUpdateTick) {
      _lastUpdateTick = m.updateTick;
      const k = 0.10; // logical px -> buffer-cell smear
      _dragX = _clampD(_dragX + m.liveDelta.dx * k, -48.0, 48.0);
      _dragY = _clampD(_dragY + m.liveDelta.dy * k, -48.0, 48.0);
      final inst = m.liveDelta.distance * 60.0; // ~px/s
      _chaos = math.min(1.4, _chaos + math.min(0.5, inst / 2600.0));
    }

    // Commit: the definitive dramatic reaction for the minute step.
    if (m.committedScrolls != _lastCommit) {
      _lastCommit = m.committedScrolls;
      _onCommit(m.lastDirection);
    }
  }

  void _onCommit(int direction) {
    _chaos = 1.2; // full spike
    _commitSalt += 1; // snap: reshuffle every glitch region at the commit
    // Forward and backward shred in opposite directions so they feel distinct.
    _dragX = _clampD(_dragX + direction * 34.0, -60.0, 60.0);
    _dragY = _clampD(_dragY + direction * 22.0, -60.0, 60.0);
    // Palette evolves with direction (warm forward, cool backward), echoing the
    // Color Art anchor.
    for (final b in _blobs) {
      var h = (b.hue + direction * 18.0) % 360.0;
      if (h < 0) h += 360.0;
      b.hue = h;
    }
  }

  // --- Base colour field (the slow floating layer) ---------------------------

  void _renderField() {
    final w = _w, h = _h;
    final field = _field!;
    final t = _elapsedS;
    final cx = w / 2.0, cy = h / 2.0;
    final shortest = math.min(w, h).toDouble();

    // Per-blob frame data: centre, radius, colour — computed once per frame.
    for (var i = 0; i < _kBlobCount; i++) {
      final b = _blobs[i];
      final ox = math.cos(t / b.px) * w * b.rx;
      final oy = math.sin(t / b.py) * h * b.ry;
      _bx[i] = cx + ox;
      _by[i] = cy + oy;
      final breath = 1.0 + 0.28 * math.sin(2 * math.pi * t / b.breathP + b.breathPh);
      _br[i] = shortest * b.base * 0.9 * breath;
      _hslToRgb((b.hue + _hueDrift) % 360.0, 0.95, 0.60, _brgb, i * 3);
    }

    // Recurring horizontal band (the reference's magenta tear-line).
    final bandY = (0.5 + 0.18 * math.sin(t * 0.21)) * h;
    final bandHalf = math.max(2.0, h * 0.05);
    _hslToRgb((300.0 + _hueDrift) % 360.0, 1.0, 0.55, _bandRgb, 0);

    var p = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var accR = 0.0, accG = 0.0, accB = 0.0;

        // Sum the blobs with a screen blend (overlaps mix as colour).
        for (var i = 0; i < _kBlobCount; i++) {
          final dx = x - _bx[i];
          final dy = y - _by[i];
          final r = _br[i];
          final r2 = r * r;
          final d2 = dx * dx + dy * dy;
          if (d2 < r2) {
            final a = 0.95 * (1.0 - d2 / r2); // soft quadratic falloff
            final j = i * 3;
            final sr = _brgb[j] * a, sg = _brgb[j + 1] * a, sb = _brgb[j + 2] * a;
            accR = 1.0 - (1.0 - accR) * (1.0 - sr);
            accG = 1.0 - (1.0 - accG) * (1.0 - sg);
            accB = 1.0 - (1.0 - accB) * (1.0 - sb);
          }
        }

        // Band (also screen-blended).
        final db = (y - bandY).abs();
        if (db < bandHalf) {
          final a = 0.85 * (1.0 - db / bandHalf);
          final sr = _bandRgb[0] * a, sg = _bandRgb[1] * a, sb = _bandRgb[2] * a;
          accR = 1.0 - (1.0 - accR) * (1.0 - sr);
          accG = 1.0 - (1.0 - accG) * (1.0 - sg);
          accB = 1.0 - (1.0 - accB) * (1.0 - sb);
        }

        field[p] = (accR * 255.0).toInt();
        field[p + 1] = (accG * 255.0).toInt();
        field[p + 2] = (accB * 255.0).toInt();
        field[p + 3] = 255;
        p += 4;
      }
    }

  }

  // Scratch for the band colour (allocated once).
  final Float64List _bandRgb = Float64List(3);

  // --- Glitch layer ----------------------------------------------------------
  // For each destination cell, pick a (displaced) source coordinate, sample the
  // field with a per-channel split, then crush the colour and apply dither and
  // black drop-out. All operator strengths scale with `chaos`.

  void _renderGlitch(double chaos, double dragX, double dragY, double seedT) {
    final w = _w, h = _h;
    final src = _field!;
    final dst = _pixels!;
    final salt = _commitSalt;

    // Region seeds reshuffle in glitchy steps; faster with chaos, and snapped
    // hard on every commit via `salt`.
    final reshuffle = 0.6 + chaos * 4.0;
    final sA = (_mul32((seedT * reshuffle).floor(), 2654435761) +
            _mul32(salt, 40503)) &
        0xFFFFFFFF; // dither
    final sB = (_mul32((seedT * reshuffle * 1.3).floor(), 40503) +
            _mul32(salt, 2654435761)) &
        0xFFFFFFFF; // comb
    final sC = (_mul32((seedT * reshuffle * 0.9).floor(), 2246822519) +
            _mul32(salt, 3266489917)) &
        0xFFFFFFFF; // tear
    final sD = (_mul32((seedT * reshuffle * 0.7).floor(), 3266489917) +
            _mul32(salt, 2246822519)) &
        0xFFFFFFFF; // blocks

    final combMax = (2 + chaos * h * 0.55).toInt();
    final tearMax = (1 + chaos * w * 0.30).toInt();
    final blockMax = (1 + chaos * w * 0.12).toInt();
    final chanSplit = (chaos * w * 0.045).toInt(); // RGB channel shift (cells)
    final levels = math.max(3, (_kQuantLevels - chaos * 1.5).round());
    final qstep = 255.0 / (levels - 1);
    final darkCut = 0.12 + chaos * 0.14; // more black voids with chaos
    final drift = chaos * 8.0 + 0.6; // ambient wobble so idle never freezes

    const colBand = 6, rowBand = 4, blockSz = 16, ditReg = 8;

    var p = 0;
    for (var y = 0; y < h; y++) {
      final rowId = y ~/ rowBand;
      final tearOn = _hash2(rowId, sC) < (_kTearCoverage + chaos * 0.25);
      var tearShift = 0;
      if (tearOn) {
        final dir = _hash2(rowId * 7 + 1, sC) < 0.5 ? -1 : 1;
        tearShift =
            (dir * (0.2 + _hash2(rowId * 13 + 3, sC)) * tearMax + dragX * 0.6)
                .toInt();
      }
      final driftCol = (math.sin(y * 0.07 + seedT * 0.6) * drift).toInt();

      for (var x = 0; x < w; x++) {
        var sx = x, sy = y;

        // Horizontal tear / shear.
        if (tearOn) sx += tearShift;

        // Vertical comb (drip downward => sample from above).
        final colId = x ~/ colBand;
        if (_hash2(colId, sB) < (_kCombCoverage + chaos * 0.2)) {
          final off = ((0.25 + _hash2(colId * 5 + 2, sB)) * combMax + dragY * 0.6)
              .toInt();
          sy -= off;
        }

        // Block displacement.
        final bId = (x ~/ blockSz) * 131 + (y ~/ blockSz);
        if (_hash2(bId, sD) < (_kBlockCoverage + chaos * 0.18)) {
          sx += (((_hash2(bId * 3 + 1, sD) - 0.5) * 2 * blockMax) + dragX * 0.4)
              .toInt();
          sy += (((_hash2(bId * 3 + 2, sD) - 0.5) * 2 * blockMax) + dragY * 0.4)
              .toInt();
        }

        // Ambient drift so the resting state is always alive.
        sx += driftCol;

        // Sample (wrapped) with a per-channel split.
        final gi = _idx(sx, sy, w, h);
        final ri = _idx(sx + chanSplit, sy, w, h);
        final bi = _idx(sx - chanSplit, sy, w, h);
        var rr = src[ri].toDouble();
        var gg = src[gi + 1].toDouble();
        var bb = src[bi + 2].toDouble();

        // Saturation boost (push away from luma) for the neon snap.
        final luma = 0.299 * rr + 0.587 * gg + 0.114 * bb;
        rr = luma + (rr - luma) * _kSatBoost;
        gg = luma + (gg - luma) * _kSatBoost;
        bb = luma + (bb - luma) * _kSatBoost;
        if (rr < 0) rr = 0; else if (rr > 255) rr = 255;
        if (gg < 0) gg = 0; else if (gg > 255) gg = 255;
        if (bb < 0) bb = 0; else if (bb > 255) bb = 255;

        // Posterize to a punchy limited palette.
        rr = (rr / qstep).round() * qstep;
        gg = (gg / qstep).round() * qstep;
        bb = (bb / qstep).round() * qstep;

        // Dot-matrix dither in selected regions.
        final dReg = (x ~/ ditReg) * 71 + (y ~/ ditReg);
        if (_hash2(dReg, sA) < _kDitherCoverage) {
          final thr = _bayer[(y & 3) * 4 + (x & 3)];
          final v = (0.299 * rr + 0.587 * gg + 0.114 * bb) / 255.0;
          if (v < thr) {
            rr = 0;
            gg = 0;
            bb = 0;
          }
        }

        // Black drop-out for dim cells (the voids that eat the image).
        if ((0.299 * rr + 0.587 * gg + 0.114 * bb) / 255.0 < darkCut) {
          rr = 0;
          gg = 0;
          bb = 0;
        }

        dst[p] = rr.round();
        dst[p + 1] = gg.round();
        dst[p + 2] = bb.round();
        dst[p + 3] = 255;
        p += 4;
      }
    }
  }

  void _kickDecode() {
    _decoding = true;
    final w = _w, h = _h;
    ui.decodeImageFromPixels(
      _pixels!,
      w,
      h,
      ui.PixelFormat.rgba8888,
      (ui.Image img) {
        if (!mounted) {
          img.dispose();
          return;
        }
        _image?.dispose();
        _image = img;
        _decoding = false;
        _frame.value++; // triggers a single repaint
      },
    );
  }

  // --- Helpers ---------------------------------------------------------------

  /// HSL -> RGB (0..1), written into [out] at [o], [o+1], [o+2].
  static void _hslToRgb(double h, double s, double l, Float64List out, int o) {
    h %= 360.0;
    if (h < 0) h += 360.0;
    final c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    final hp = h / 60.0;
    final xx = c * (1.0 - ((hp % 2.0) - 1.0).abs());
    double r, g, b;
    if (hp < 1) {
      r = c; g = xx; b = 0;
    } else if (hp < 2) {
      r = xx; g = c; b = 0;
    } else if (hp < 3) {
      r = 0; g = c; b = xx;
    } else if (hp < 4) {
      r = 0; g = xx; b = c;
    } else if (hp < 5) {
      r = xx; g = 0; b = c;
    } else {
      r = c; g = 0; b = xx;
    }
    final m = l - c / 2.0;
    out[o] = r + m;
    out[o + 1] = g + m;
    out[o + 2] = b + m;
  }

  /// Wrapped linear pixel index. Dart's `%` is non-negative for positive w/h.
  static int _idx(int x, int y, int w, int h) {
    x %= w;
    y %= h;
    return (y * w + x) * 4;
  }

  static double _clampD(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  /// 32-bit multiply that stays within 53-bit float precision, so the hash is
  /// identical on native (phone) and on web (dart2js / Chrome).
  static int _mul32(int a, int b) {
    final aLo = a & 0xFFFF;
    final aHi = (a >>> 16) & 0xFFFF;
    return (aLo * b + (((aHi * b) & 0xFFFF) << 16)) & 0xFFFFFFFF;
  }

  /// Stable hash -> [0,1) used to select which regions glitch.
  static double _hash2(int n, int s) {
    var h = (n ^ s) & 0xFFFFFFFF;
    h ^= h >>> 16;
    h &= 0xFFFFFFFF;
    h = _mul32(h, 0x85ebca6b);
    h ^= h >>> 13;
    h &= 0xFFFFFFFF;
    h = _mul32(h, 0xc2b2ae35);
    h ^= h >>> 16;
    h &= 0xFFFFFFFF;
    return h / 4294967296.0;
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _GlitchPainter(state: this, repaint: _frame),
      ),
    );
  }
}

class _Blob {
  double px, py; // orbit divisors (period-like)
  double rx, ry; // orbit reach (fraction of W / H)
  double base; // base radius (fraction of shortest side)
  double breathP, breathPh; // radius breathing
  double hue; // 0..360; evolves on commit

  _Blob({
    required this.px,
    required this.py,
    required this.rx,
    required this.ry,
    required this.base,
    required this.breathP,
    required this.breathPh,
    required this.hue,
  });
}

class _GlitchPainter extends CustomPainter {
  final _GlitchArtScreenState state;
  _GlitchPainter({required this.state, required Listenable repaint})
      : super(repaint: repaint);

  final Paint _bg = Paint()..color = Colors.black;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _bg);
    final img = state._image;
    if (img == null) return;

    // Nearest-neighbour up-scale -> crisp chunky pixels, GPU-cheap.
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Offset.zero & size,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _GlitchPainter old) => true;
}