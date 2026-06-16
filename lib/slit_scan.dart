// lib/slit_scan.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'motion_controller.dart';

/// Slit-Scan mode — "Time Echoes".
///
/// A live video-feedback piece built from the screen-side (front) camera. A
/// persistent light-buffer holds the recent past: every frame it is dimmed
/// slightly (so old light decays), nudged by the current scroll, and then the
/// live camera frame is *added* on top. The result is long-exposure painting
/// with time — a still figure resolves into a clean, luminous image, while any
/// movement leaves glowing trails that fade like comet tails.
///
/// **The swipe drags time.** The whole light-buffer is displaced by the arm's
/// motion — 1:1 during a drag, with momentum on release and a slow ambient
/// drift at rest. So a swipe physically pulls the accumulated light into long
/// streaks across the frame, then the live image re-asserts and the picture
/// heals. Slow mechanical-arm swipes smear the light into deliberate ribbons.
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

/// Capture resolution. The effect is luminous and abstract, so a modest preset
/// is plenty and keeps the per-frame YUV→RGBA conversion cheap. Drop to `.low`
/// if an older device stutters.
const ResolutionPreset _kResolution = ResolutionPreset.medium;

/// Minimum interval between camera-frame conversions (ms). The display runs at
/// 60 fps regardless; the camera only needs to refresh ~25×/s.
const int _kConvertMinIntervalMs = 40;

/// Working resolution of the light-buffer (longest edge, px); upscaled to fill.
const int _kAccumMaxEdge = 1000;

/// How much of the previous buffer survives each frame (0..1). Higher = longer,
/// silkier trails (and a slower heal-back); lower = snappier, shorter trails.
const double _kPersistence = 0.92;

/// Light-buffer motion (accumulator px / s), reused from the Color Art scroll.
const double _kAmbientSpeed = 8.0; // gentle drift at rest, so it's never frozen
const double _kAmbientTurn = 0.05; // how fast that drift's direction wanders
const double _kInertiaTau = 1.3; // release-momentum decay
const double _kMaxReleaseSpeed = 3000.0; // cap on fling momentum

/// Optional feedback zoom per frame (1.0 = off). Slightly above 1 gives a
/// gentle tunnelling echo; below 1 pulls trails inward.
const double _kFeedbackZoom = 1.0;

/// Render as luminous white-on-black (matches the rest of the series) instead
/// of full colour.
const bool _kMonochrome = false;

/// Front cameras are normally shown mirrored, like a bathroom mirror.
const bool _kMirror = true;

/// Rotation fine-tune. 2 = 180° (the fix for an upside-down sensor). If the
/// picture is sideways, try 1 or 3.
const int _kExtraQuarterTurns = 2;

class _SlitScanScreenState extends State<SlitScanScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  // --- Camera ---------------------------------------------------------------
  _Status _status = _Status.initializing;
  CameraController? _controller;
  int _sensorOrientation = 0;
  bool _initializing = false;

  ui.Image? _camImage; // latest converted live frame
  double _camW = 0, _camH = 0;
  bool _converting = false;
  int _lastConvertMs = 0;

  Timer? _retry; // re-init watchdog until the camera is ready

  // --- Light buffer ---------------------------------------------------------
  final _Surface _surface = _Surface();
  int _accumW = 0, _accumH = 0;

  // The previous buffer + its picture must stay alive until the new buffer has
  // actually been painted (toImageSync rasterises lazily). We free them one
  // frame later — disposing them immediately is what made the image go dark.
  ui.Image? _toDisposeImg;
  ui.Picture? _toDisposePic;

  // --- Scroll → displacement -------------------------------------------------
  Offset _pendingDisp = Offset.zero; // live 1:1 drag, consumed each tick
  Offset _camVel = Offset.zero; // release momentum (accumulator px/s)
  double _ambientAngle = 0.0;
  bool _wasDragging = false;
  int _lastUpdateTick = -1;

  double _prevElapsedS = 0.0;

  // --- Layout ---------------------------------------------------------------
  Size _size = Size.zero;
  bool _isLandscape = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.motion.addListener(_onMotion);
    _ambientAngle = math.Random().nextDouble() * 2 * math.pi;
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
      _resizeBuffer();
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
    _camImage?.dispose();
    _surface.image?.dispose();
    _toDisposeImg?.dispose();
    _toDisposePic?.dispose();
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

  // --- Buffer geometry -------------------------------------------------------

  void _resizeBuffer() {
    if (_size.width <= 0 || _size.height <= 0) return;
    final longest = math.max(_size.width, _size.height);
    final scale = longest > _kAccumMaxEdge ? _kAccumMaxEdge / longest : 1.0;
    final w = (_size.width * scale).round().clamp(16, _kAccumMaxEdge).toInt();
    final h = (_size.height * scale).round().clamp(16, _kAccumMaxEdge).toInt();
    if (w == _accumW && h == _accumH && _surface.image != null) return;
    _accumW = w;
    _accumH = h;
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

  // --- The feedback step -----------------------------------------------------

  void _composite(Offset disp) {
    // Free last frame's source + picture now that the new buffer they fed has
    // already been painted (one-frame deferral keeps the feedback alive).
    _toDisposePic?.dispose();
    _toDisposePic = null;
    _toDisposeImg?.dispose();
    _toDisposeImg = null;

    final aw = _accumW.toDouble(), ah = _accumH.toDouble();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    // Opaque black base so any edge the displacement uncovers stays clean.
    c.drawRect(Rect.fromLTWH(0, 0, aw, ah), Paint()..color = Colors.black);

    // Previous light, displaced (and optionally zoomed) — this is the "echo".
    final prev = _surface.image;
    if (prev != null) {
      c.save();
      if (_kFeedbackZoom != 1.0) {
        c.translate(aw / 2, ah / 2);
        c.scale(_kFeedbackZoom);
        c.translate(-aw / 2, -ah / 2);
      }
      c.translate(disp.dx, disp.dy);
      c.drawImage(prev, Offset.zero, Paint()..filterQuality = FilterQuality.low);
      c.restore();
    }

    // Decay the echo: multiply everything so far by _kPersistence (a black veil
    // at alpha 1−persistence does exactly that under srcOver).
    c.drawRect(Rect.fromLTWH(0, 0, aw, ah),
        Paint()..color = Colors.black.withValues(alpha: 1.0 - _kPersistence));

    // Draw the live frame at FULL brightness, kept wherever it is brighter than
    // the fading echo (BlendMode.lighten). Result: a clear, bright live image,
    // with the decaying ghost glowing through as trails — never a dark frame.
    final cam = _camImage;
    if (cam != null) _drawFrameLighten(c, cam);

    final pic = rec.endRecording();
    final img = pic.toImageSync(_accumW, _accumH);
    _surface.image = img;

    // Keep prev + pic alive one more frame (see fields above).
    _toDisposeImg = prev;
    _toDisposePic = pic;
  }

  /// Draw the live frame to fill the buffer — centred, cover-fit, rotated for
  /// the sensor/device, mirrored for the front camera — at full brightness,
  /// blended so it keeps the lighter of (live, fading echo).
  void _drawFrameLighten(Canvas canvas, ui.Image cam) {
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

    final paint = Paint()
      ..filterQuality = FilterQuality.low
      ..blendMode = BlendMode.lighten
      ..colorFilter = _lookFilter();

    canvas.save();
    canvas.translate(aw / 2, ah / 2);
    canvas.rotate(qt * math.pi / 2);
    if (_kMirror) canvas.scale(-1.0, 1.0);
    canvas.scale(cover, cover);
    canvas.drawImage(cam, Offset(-_camW / 2, -_camH / 2), paint);
    canvas.restore();
  }

  /// Optional white-on-black look: collapse the frame to luminance.
  ColorFilter? _lookFilter() {
    if (!_kMonochrome) return null;
    const r = 0.299, g = 0.587, b = 0.114;
    return const ColorFilter.matrix(<double>[
      r, g, b, 0, 0, //
      r, g, b, 0, 0, //
      r, g, b, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);
  }

  // --- Per-frame -------------------------------------------------------------

  void _onTick(Duration elapsed) {
    final nowS = elapsed.inMicroseconds / 1e6;
    final dt = (nowS - _prevElapsedS).clamp(0.0, 0.05).toDouble();
    _prevElapsedS = nowS;

    if (_status == _Status.ready && _accumW > 0 && _camImage != null) {
      // Ambient current keeps the light gently flowing even at rest.
      _ambientAngle += dt * _kAmbientTurn;
      final ambient = Offset.fromDirection(_ambientAngle, _kAmbientSpeed);

      var disp = _pendingDisp + (ambient + _camVel) * dt;
      _pendingDisp = Offset.zero;
      _camVel = _camVel * math.exp(-dt / _kInertiaTau);

      // Never displace more than half the buffer in one frame.
      final maxStep = 0.5 * math.min(_accumW, _accumH);
      if (disp.distance > maxStep) disp = disp / disp.distance * maxStep;

      _composite(disp);
    }

    _frame.value += 1;
  }

  // --- Gesture ---------------------------------------------------------------

  void _onMotion() {
    final m = widget.motion;
    if (_size.width <= 0 || _accumW <= 0) return;

    // Map screen-space gesture px onto buffer-space px.
    final scale = _accumW / _size.width;

    if (m.isDragging && !_wasDragging) {
      _wasDragging = true;
      _camVel = Offset.zero; // the drag itself drives motion 1:1
    } else if (!m.isDragging && _wasDragging) {
      _wasDragging = false;
      var v = m.velocity * scale;
      if (v.distance > _kMaxReleaseSpeed) {
        v = v / v.distance * _kMaxReleaseSpeed;
      }
      _camVel = v;
    }

    if (m.isDragging && m.updateTick != _lastUpdateTick) {
      _lastUpdateTick = m.updateTick;
      _pendingDisp += m.liveDelta * scale;
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
                  painter: _EchoPainter(surface: _surface, repaint: _frame),
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

/// Mutable handle for the light buffer.
class _Surface {
  ui.Image? image;
}

class _EchoPainter extends CustomPainter {
  final _Surface surface;
  final Listenable repaint;
  _EchoPainter({required this.surface, required this.repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final img = surface.image;
    if (img == null) return;
    final src =
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    canvas.drawImageRect(img, src, Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(covariant _EchoPainter old) => true;
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