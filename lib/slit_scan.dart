// lib/slit_scan.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Slit-Scan mode — a living mosaic of the viewers, built from the screen-side
/// (front) camera.
///
/// The screen is divided into a row of vertical strips. Each strip holds a
/// *frozen* slice of the camera from whatever moment it was last refreshed. A
/// swipe brushes a few random strips up to the present: each chosen strip wipes
/// upward to reveal the live camera content captured at that instant. A longer
/// or faster swipe brushes more strips. Between swipes the mosaic persists, so
/// as different people pass in front of the work — and the mechanical arm keeps
/// swiping — their fragments accumulate and blend across the columns. A still
/// viewer slowly resolves into one coherent picture; movement, or a change of
/// visitor, leaves the strips out of step, smeared across time.
///
/// **Local only.** Frames are processed live and never stored or transmitted —
/// nothing leaves the device.
class SlitScanScreen extends StatefulWidget {
  final MotionController motion;
  const SlitScanScreen({super.key, required this.motion});

  @override
  State<SlitScanScreen> createState() => _SlitScanScreenState();
}

/// Camera lifecycle.
enum _Status { initializing, denied, noCamera, ready }

// --- Tuning ------------------------------------------------------------------

/// Capture resolution. Slit-scan is abstract, so a modest preset is plenty and
/// keeps the per-frame YUV→RGBA conversion cheap. Drop to `.low` if an older
/// device stutters; raise to `.high` for crisper detail.
const ResolutionPreset _kResolution = ResolutionPreset.medium;

/// Minimum interval between camera-frame conversions (ms). The display runs at
/// 60 fps regardless; the camera only needs to refresh ~25×/s.
const int _kConvertMinIntervalMs = 40;

/// Working resolution of the mosaic (longest edge, px). Upscaled to the screen.
const int _kAccumMaxEdge = 1000;

/// Number of vertical strips the picture is divided into.
const int _kSliceCount = 20;

/// How long a strip takes to wipe up to its new content.
const double _kStrokeDurationS = 0.55;

/// A new strip is brushed for every this-fraction-of-the-screen swiped, so a
/// short arm swipe paints a few strips and a long one paints many.
const double _kStrokeSpacingFrac = 0.10;

/// Cap on simultaneously-animating strips.
const int _kMaxConcurrentStrokes = 12;

/// Front cameras are normally shown mirrored, like a bathroom mirror — natural
/// for someone watching themselves. Set false for a "true" (un-mirrored) view.
const bool _kMirror = true;

/// Fine-tune for the captured frame's rotation. The base rotation is derived
/// from the sensor + device orientation; if the picture is sideways or upside
/// down, change this 0 → 1 → 2 → 3 until it stands upright. (2 = 180°, the fix
/// for an upside-down image.)
const int _kExtraQuarterTurns = 2;

class _SlitScanScreenState extends State<SlitScanScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final math.Random _rng = math.Random();

  // --- Camera ---------------------------------------------------------------
  _Status _status = _Status.initializing;
  CameraController? _controller;
  int _sensorOrientation = 0;
  bool _initializing = false;

  ui.Image? _camImage; // latest converted live frame
  double _camW = 0, _camH = 0;
  bool _converting = false;
  int _lastConvertMs = 0;

  // Retry watchdog: while the camera isn't ready, re-attempt init so it
  // recovers on its own once permission is granted — no app restart needed.
  Timer? _retry;

  // --- Mosaic ----------------------------------------------------------------
  final _Surface _surface = _Surface(); // baked, settled mosaic
  final List<_Stroke> _strokes = <_Stroke>[]; // strips currently wiping in
  int _accumW = 0, _accumH = 0;
  bool _seeded = false; // first live frame painted into all strips yet?

  // --- Gesture ---------------------------------------------------------------
  double _swipeAccum = 0.0; // swipe distance since the last brushed strip
  int _spawnedThisGesture = 0;
  bool _wasDragging = false;
  int _lastUpdateTick = -1;

  double _prevElapsedS = 0.0;
  double _nowS = 0.0;

  // --- Layout ---------------------------------------------------------------
  Size _size = Size.zero;
  bool _isLandscape = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.motion.addListener(_onMotion);
    _ticker = createTicker(_onTick)..start();
    _initCamera();
    _startRetry();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = MediaQuery.of(context).size;
    if (s != _size) {
      _size = s;
      _isLandscape = s.width > s.height;
      _resizeMosaic();
    }
  }

  @override
  void didUpdateWidget(SlitScanScreen old) {
    super.didUpdateWidget(old);
    if (old.motion != widget.motion) {
      old.motion.removeListener(_onMotion);
      widget.motion.addListener(_onMotion);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera only when truly backgrounded — NOT on the brief
    // `inactive` flash the permission dialog causes (which would tear the
    // camera down mid-initialise).
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      if (_status != _Status.ready) {
        _initCamera();
        _startRetry();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.motion.removeListener(_onMotion);
    _retry?.cancel();
    _ticker.dispose();
    _disposeCamera();
    for (final s in _strokes) {
      s.strip.dispose();
    }
    _camImage?.dispose();
    _surface.image?.dispose();
    _frame.dispose();
    super.dispose();
  }

  // --- Camera setup ----------------------------------------------------------

  Future<void> _initCamera() async {
    if (_initializing || _controller != null) return;
    _initializing = true;
    _status = _Status.initializing;
    try {
      final cams = await availableCameras();
      if (!mounted) return;
      CameraDescription? front;
      for (final c in cams) {
        if (c.lensDirection == CameraLensDirection.front) {
          front = c;
          break;
        }
      }
      front ??= cams.isNotEmpty ? cams.first : null;
      if (front == null) {
        _status = _Status.noCamera;
        return;
      }
      _sensorOrientation = front.sensorOrientation;

      final ctrl = CameraController(front, _kResolution, enableAudio: false);
      _controller = ctrl;
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        _controller = null;
        return;
      }
      await ctrl.startImageStream(_onCameraImage);
      _status = _Status.ready;
      _retry?.cancel();
      _retry = null;
    } on CameraException catch (_) {
      await _disposeCamera();
      _status = _Status.denied;
      _startRetry();
    } catch (_) {
      await _disposeCamera();
      _status = _Status.noCamera;
      _startRetry();
    } finally {
      _initializing = false;
    }
  }

  void _startRetry() {
    _retry ??= Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || _status == _Status.ready) {
        _retry?.cancel();
        _retry = null;
        return;
      }
      _initCamera();
    });
  }

  Future<void> _disposeCamera() async {
    final ctrl = _controller;
    _controller = null;
    if (ctrl == null) return;
    try {
      if (ctrl.value.isStreamingImages) await ctrl.stopImageStream();
    } catch (_) {/* ignore */}
    try {
      await ctrl.dispose();
    } catch (_) {/* ignore */}
  }

  // --- Camera frame → ui.Image ----------------------------------------------

  void _onCameraImage(CameraImage image) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_converting || now - _lastConvertMs < _kConvertMinIntervalMs) return;
    _converting = true;
    _lastConvertMs = now;

    try {
      final w = image.width, h = image.height;
      final rgba = _toRgba(image);
      if (rgba == null) {
        _converting = false;
        return;
      }
      ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
        if (!mounted) {
          img.dispose();
          return;
        }
        _camImage?.dispose();
        _camImage = img;
        _camW = w.toDouble();
        _camH = h.toDouble();
        _converting = false;
      });
    } catch (_) {
      _converting = false;
    }
  }

  Uint8List? _toRgba(CameraImage image) {
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        return _yuv420ToRgba(image);
      case ImageFormatGroup.bgra8888:
        return _bgraToRgba(image);
      default:
        if (image.planes.length >= 3) return _yuv420ToRgba(image);
        return null;
    }
  }

  Uint8List _yuv420ToRgba(CameraImage image) {
    final w = image.width, h = image.height;
    final yP = image.planes[0];
    final uP = image.planes[1];
    final vP = image.planes[2];
    final yRow = yP.bytesPerRow;
    final uvRow = uP.bytesPerRow;
    final uvPix = uP.bytesPerPixel ?? 1;
    final yB = yP.bytes, uB = uP.bytes, vB = vP.bytes;

    final out = Uint8List(w * h * 4);
    var o = 0;
    for (var y = 0; y < h; y++) {
      final yr = y * yRow;
      final uvr = (y >> 1) * uvRow;
      for (var x = 0; x < w; x++) {
        final yy = yB[yr + x].toDouble();
        final uvIndex = uvr + (x >> 1) * uvPix;
        final uu = uB[uvIndex] - 128.0;
        final vv = vB[uvIndex] - 128.0;

        var r = yy + 1.402 * vv;
        var g = yy - 0.344136 * uu - 0.714136 * vv;
        var b = yy + 1.772 * uu;

        out[o++] = r < 0 ? 0 : (r > 255 ? 255 : r.toInt());
        out[o++] = g < 0 ? 0 : (g > 255 ? 255 : g.toInt());
        out[o++] = b < 0 ? 0 : (b > 255 ? 255 : b.toInt());
        out[o++] = 255;
      }
    }
    return out;
  }

  Uint8List _bgraToRgba(CameraImage image) {
    final w = image.width, h = image.height;
    final p = image.planes[0];
    final row = p.bytesPerRow;
    final src = p.bytes;
    final out = Uint8List(w * h * 4);
    var o = 0;
    for (var y = 0; y < h; y++) {
      var i = y * row;
      for (var x = 0; x < w; x++) {
        final b = src[i], g = src[i + 1], r = src[i + 2], a = src[i + 3];
        out[o++] = r;
        out[o++] = g;
        out[o++] = b;
        out[o++] = a;
        i += 4;
      }
    }
    return out;
  }

  // --- Mosaic geometry / seeding --------------------------------------------

  void _resizeMosaic() {
    if (_size.width <= 0 || _size.height <= 0) return;
    final longest = math.max(_size.width, _size.height);
    final scale = longest > _kAccumMaxEdge ? _kAccumMaxEdge / longest : 1.0;
    final w = (_size.width * scale).round().clamp(16, _kAccumMaxEdge).toInt();
    final h = (_size.height * scale).round().clamp(16, _kAccumMaxEdge).toInt();
    if (w == _accumW && h == _accumH && _surface.image != null) return;
    _accumW = w;
    _accumH = h;
    _seeded = false; // re-seed from the next live frame at the new size
    _paintBlack();
  }

  void _paintBlack() {
    if (_accumW <= 0 || _accumH <= 0) return;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, _accumW.toDouble(), _accumH.toDouble()),
        Paint()..color = Colors.black);
    final pic = rec.endRecording();
    final img = pic.toImageSync(_accumW, _accumH);
    pic.dispose();
    _surface.image?.dispose();
    _surface.image = img;
  }

  /// Paint the current live frame across the whole mosaic, so the mode opens on
  /// a coherent picture that then diverges strip-by-strip as it's brushed.
  void _seedFrom(ui.Image cam) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, _accumW.toDouble(), _accumH.toDouble()),
        Paint()..color = Colors.black);
    _drawFrameCover(c, cam);
    final pic = rec.endRecording();
    final img = pic.toImageSync(_accumW, _accumH);
    pic.dispose();
    _surface.image?.dispose();
    _surface.image = img;
  }

  /// Draw the live frame to fill the whole mosaic, centred, cover-fit, rotated
  /// for the sensor/device, and mirrored for the front camera.
  void _drawFrameCover(Canvas canvas, ui.Image cam) {
    final aw = _accumW.toDouble(), ah = _accumH.toDouble();
    final deviceDeg = _isLandscape ? 90 : 0;
    var qt =
        (((_sensorOrientation + deviceDeg) ~/ 90) + _kExtraQuarterTurns) % 4;
    if (qt < 0) qt += 4;
    final odd = qt.isOdd;
    final effW = odd ? _camH : _camW;
    final effH = odd ? _camW : _camH;
    final cover =
        (effW <= 0 || effH <= 0) ? 1.0 : math.max(aw / effW, ah / effH);

    canvas.save();
    canvas.translate(aw / 2, ah / 2);
    canvas.rotate(qt * math.pi / 2);
    if (_kMirror) canvas.scale(-1.0, 1.0);
    canvas.scale(cover, cover);
    canvas.drawImage(cam, Offset(-_camW / 2, -_camH / 2),
        Paint()..filterQuality = FilterQuality.low);
    canvas.restore();
  }

  // --- Brushing strips -------------------------------------------------------

  double get _sliceW => _accumW / _kSliceCount;

  /// Capture the current live frame for just strip [index] as a standalone
  /// strip image (so it stays fixed even as new camera frames arrive).
  ui.Image _captureSlice(int index, ui.Image cam) {
    final sliceW = _sliceW;
    final x0 = index * sliceW;
    final wPx = sliceW.ceil().clamp(1, _accumW).toInt();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.clipRect(Rect.fromLTWH(0, 0, sliceW, _accumH.toDouble()));
    c.translate(-x0, 0);
    _drawFrameCover(c, cam);
    final pic = rec.endRecording();
    final img = pic.toImageSync(wPx, _accumH);
    pic.dispose();
    return img;
  }

  /// Brush one random strip (not already animating) up to the live frame.
  void _brushStrip() {
    final cam = _camImage;
    if (cam == null || _accumW <= 0 || !_seeded) return;
    if (_strokes.length >= _kMaxConcurrentStrokes) return;

    final busy = <int>{for (final s in _strokes) s.index};
    if (busy.length >= _kSliceCount) return;

    int idx = _rng.nextInt(_kSliceCount);
    var tries = 0;
    while (busy.contains(idx) && tries < 24) {
      idx = _rng.nextInt(_kSliceCount);
      tries++;
    }
    if (busy.contains(idx)) return;

    _strokes.add(_Stroke(
      index: idx,
      strip: _captureSlice(idx, cam),
      startS: _nowS,
    ));
    _spawnedThisGesture++;
  }

  /// Permanently composite a finished strip into the settled mosaic.
  void _bake(_Stroke s) {
    final sliceW = _sliceW;
    final x0 = s.index * sliceW;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    if (_surface.image != null) c.drawImage(_surface.image!, Offset.zero, Paint());
    final src = Rect.fromLTWH(
        0, 0, s.strip.width.toDouble(), s.strip.height.toDouble());
    final dst = Rect.fromLTWH(x0, 0, sliceW, _accumH.toDouble());
    c.drawImageRect(s.strip, src, dst, Paint());
    final pic = rec.endRecording();
    final img = pic.toImageSync(_accumW, _accumH);
    pic.dispose();
    _surface.image?.dispose();
    _surface.image = img;
  }

  // --- Per-frame -------------------------------------------------------------

  void _onTick(Duration elapsed) {
    _nowS = elapsed.inMicroseconds / 1e6;
    _prevElapsedS = _nowS;

    if (_status == _Status.ready && _accumW > 0 && _camImage != null) {
      if (!_seeded) {
        _seedFrom(_camImage!);
        _seeded = true;
      }
      // Bake and retire any strokes that have finished wiping in.
      for (var i = _strokes.length - 1; i >= 0; i--) {
        final s = _strokes[i];
        if (_nowS - s.startS >= _kStrokeDurationS) {
          _bake(s);
          s.strip.dispose();
          _strokes.removeAt(i);
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
      _swipeAccum = 0.0;
      _spawnedThisGesture = 0;
      _brushStrip(); // immediate feedback on touch-down
    } else if (!m.isDragging && _wasDragging) {
      _wasDragging = false;
      if (_spawnedThisGesture == 0) _brushStrip(); // ensure a short tap paints
    }

    // Accumulate total swipe travel (any direction) and brush a strip each time
    // the arm has moved another step's worth.
    if (m.isDragging && m.updateTick != _lastUpdateTick) {
      _lastUpdateTick = m.updateTick;
      _swipeAccum += m.liveDelta.distance;
      final screenDim = _isLandscape ? _size.width : _size.height;
      final spacing = _kStrokeSpacingFrac * (screenDim <= 0 ? 1000.0 : screenDim);
      var guard = 0;
      while (_swipeAccum >= spacing && guard < _kSliceCount) {
        _swipeAccum -= spacing;
        _brushStrip();
        guard++;
      }
    }
    // Commits are ignored on purpose: this mode is purely visual.
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        color: Colors.black,
        child: ValueListenableBuilder<int>(
          valueListenable: _frame,
          builder: (context, _, __) {
            switch (_status) {
              case _Status.ready:
                return CustomPaint(
                  size: Size.infinite,
                  painter: _MosaicPainter(state: this, repaint: _frame),
                );
              case _Status.initializing:
                return const SizedBox.expand();
              case _Status.denied:
                return const _Message(
                  'Camera access is off.\n'
                  'Enable it for this app in Settings to begin.',
                );
              case _Status.noCamera:
                return const _Message('No camera available on this device.');
            }
          },
        ),
      ),
    );
  }
}

/// One strip currently wiping up to its new captured content.
class _Stroke {
  final int index;
  final ui.Image strip;
  final double startS;
  _Stroke({required this.index, required this.strip, required this.startS});
}

/// Mutable handle for the settled mosaic image.
class _Surface {
  ui.Image? image;
}

class _MosaicPainter extends CustomPainter {
  final _SlitScanScreenState state;
  final Listenable repaint;
  _MosaicPainter({required this.state, required this.repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    // The settled mosaic, upscaled to the screen.
    final base = state._surface.image;
    if (base != null) {
      final src =
          Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble());
      canvas.drawImageRect(base, src, Offset.zero & size,
          Paint()..filterQuality = FilterQuality.medium);
    }

    // Active strokes: each reveals its strip from the bottom up.
    final sliceWScreen = size.width / _kSliceCount;
    for (final s in state._strokes) {
      final p = ((state._nowS - s.startS) / _kStrokeDurationS)
          .clamp(0.0, 1.0)
          .toDouble();
      if (p <= 0) continue;
      final strip = s.strip;
      final sh = strip.height.toDouble();
      final sw = strip.width.toDouble();

      // Reveal the bottom fraction p (a brushstroke travelling upward).
      final srcTop = sh * (1.0 - p);
      final src = Rect.fromLTWH(0, srcTop, sw, sh - srcTop);
      final dstH = size.height * p;
      final dst = Rect.fromLTWH(
          s.index * sliceWScreen, size.height - dstH, sliceWScreen, dstH);
      canvas.drawImageRect(
          strip, src, dst, Paint()..filterQuality = FilterQuality.medium);
    }
  }

  @override
  bool shouldRepaint(covariant _MosaicPainter old) => true;
}

/// Minimal centred status text in the app's typographic voice.
class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            height: 1.5,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
