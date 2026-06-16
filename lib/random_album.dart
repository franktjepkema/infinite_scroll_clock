// lib/random_album.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:photo_manager/photo_manager.dart';

import 'motion_controller.dart';

/// Random Album mode — "Scrolling Through Photo Library".
///
/// The phone's own gallery becomes an endless, shuffled feed. Each committed
/// swipe from the mechanical arm advances to a *new randomly chosen* photo, so
/// the installation scrolls through personal/photographic memory the same way
/// the other pieces scroll through time, colour, or content.
///
/// **Feel.** A single full-screen photo at rest (BoxFit.cover on pure black).
/// During a drag the current photo follows the arm 1:1 and the incoming random
/// photo slides in from the leading edge; on release a spring (the same
/// mass/stiffness/damping used elsewhere) carries the strip the rest of the
/// way to the committed photo, then the buffer rotates seamlessly. One clean
/// arm swipe = exactly one new photo. Backward swipes step back through the
/// photos already seen.
///
/// **Orientation.** Forward is rightward in landscape and upward in portrait;
/// the slide axis follows automatically from the raw gesture, so it adapts to
/// either mounting with no manual tuning.
///
/// **Buffering.** Only three decoded thumbnails are ever held (previous /
/// current / next), each sized to the screen, so memory stays flat and
/// transitions are instant. A fresh random thumbnail is loaded into the
/// vacated slot in the background after every step.
class RandomAlbumScreen extends StatefulWidget {
  final MotionController motion;
  const RandomAlbumScreen({super.key, required this.motion});

  @override
  State<RandomAlbumScreen> createState() => _RandomAlbumScreenState();
}

/// Loading lifecycle of the gallery feed.
enum _Status { loading, denied, empty, ready }

/// Spring tuning — matched to the Time / Line Art commit physics for a
/// consistent mechanical feel across modes.
const double _kStiffness = 220.0;
const double _kDamping = 30.0;
const double _kMass = 1.0;

/// Largest thumbnail edge we will request (keeps memory + decode bounded while
/// staying crisp on a flagship screen).
const int _kMaxThumbEdge = 1920;

/// How long a freshly-loaded photo takes to fade up from black.
const double _kFadeSeconds = 0.6;

/// Request images only — this matches the single READ_MEDIA_IMAGES permission
/// declared in the manifest. photo_manager's default asks for images *and*
/// video, which would require READ_MEDIA_VIDEO too and otherwise report "no
/// access" on Android 13+ even after the visitor grants Photos.
const PermissionRequestOption _kImagesOnly = PermissionRequestOption(
  androidPermission:
      AndroidPermission(type: RequestType.image, mediaLocation: false),
);

class _RandomAlbumScreenState extends State<RandomAlbumScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final math.Random _rng = math.Random();

  // --- Gallery state ---------------------------------------------------------
  _Status _status = _Status.loading;
  AssetPathEntity? _album;
  int _count = 0;

  // While access is off, we re-check periodically (no prompt) so the feed
  // recovers on its own the moment the visitor grants access in Settings.
  Timer? _poll;

  // Three-slot ring of decoded photos: previous, current, next.
  final _Cell _prev = _Cell();
  final _Cell _cur = _Cell();
  final _Cell _next = _Cell();

  // --- Scroll / physics state ------------------------------------------------
  double _p = 0.0; // strip position in "screens"; 0 = current centred
  double _vel = 0.0; // spring velocity
  double _target = 0.0; // spring target after release (-1 / 0 / +1)
  int _committedDir = 0; // direction committed during the current gesture
  int _lastCommit = 0;
  int _lastUpdateTick = -1;
  bool _wasDragging = false;

  double _prevElapsedS = 0.0;
  double _nowS = 0.0; // running clock (s), used to fade newly-loaded photos in

  // Guards the album load so overlapping permission re-checks (which fire
  // during launch) can't each kick off a fresh random load — that was the
  // burst of images flashing past at startup.
  bool _busy = false;

  // --- Layout ----------------------------------------------------------------
  Size _size = Size.zero;
  double _dpr = 1.0;
  bool _isLandscape = true;
  int _tw = 1080, _th = 1080;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastCommit = widget.motion.committedScrolls;
    widget.motion.addListener(_onMotion);
    _ticker = createTicker(_onTick)..start();
    _requestAccess();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mq = MediaQuery.of(context);
    _size = mq.size;
    _dpr = mq.devicePixelRatio;
    _isLandscape = _size.width > _size.height;
    _computeThumbSize();
  }

  @override
  void didUpdateWidget(RandomAlbumScreen old) {
    super.didUpdateWidget(old);
    if (old.motion != widget.motion) {
      old.motion.removeListener(_onMotion);
      widget.motion.addListener(_onMotion);
      _lastCommit = widget.motion.committedScrolls;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check whenever we come back and aren't already showing photos — covers
    // the visitor granting access in Settings while the app was backgrounded.
    if (state == AppLifecycleState.resumed && _status != _Status.ready) {
      _requestAccess();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.motion.removeListener(_onMotion);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  // --- Thumbnail sizing ------------------------------------------------------

  void _computeThumbSize() {
    var tw = (_size.width * _dpr).round();
    var th = (_size.height * _dpr).round();
    final longest = math.max(tw, th);
    if (longest > _kMaxThumbEdge) {
      final s = _kMaxThumbEdge / longest;
      tw = (tw * s).round();
      th = (th * s).round();
    }
    _tw = tw.clamp(64, _kMaxThumbEdge).toInt();
    _th = th.clamp(64, _kMaxThumbEdge).toInt();
  }

  // --- Gallery loading -------------------------------------------------------

  /// Ask for access (shows the system prompt only when the OS allows it), then
  /// load the album. If access isn't granted, drop to the denied state and
  /// start a quiet poll so we recover the instant it's granted in Settings.
  Future<void> _requestAccess() async {
    if (_status == _Status.ready || _busy) return;
    if (_status != _Status.ready) _status = _Status.loading;

    PermissionState ps;
    try {
      ps = await PhotoManager.requestPermissionExtend(requestOption: _kImagesOnly);
    } catch (_) {
      // Fall back to a non-prompting state read if the request path throws.
      ps = await PhotoManager.getPermissionState(requestOption: _kImagesOnly);
    }
    if (!mounted) return;

    if (ps.hasAccess) {
      await _loadAlbum();
    } else {
      _status = _Status.denied;
      _startPolling();
    }
  }

  /// While access is denied, re-read the permission state every couple of
  /// seconds *without* prompting. The moment the visitor flips it on in
  /// Settings, we load the album and stop polling — no app restart needed.
  void _startPolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || _status == _Status.ready) {
        _poll?.cancel();
        _poll = null;
        return;
      }
      PermissionState ps;
      try {
        ps = await PhotoManager.getPermissionState(requestOption: _kImagesOnly);
      } catch (_) {
        return; // try again on the next tick
      }
      if (!mounted) return;
      if (ps.hasAccess) {
        _poll?.cancel();
        _poll = null;
        await _loadAlbum();
      }
    });
  }

  /// Enumerate the gallery and seed the first three random photos. Guarded so
  /// it can only run one load at a time (and never re-seeds once ready).
  Future<void> _loadAlbum() async {
    if (_busy || _status == _Status.ready) return;
    _busy = true;
    try {
      _status = _Status.loading;

      // The single "all photos" album.
      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.image,
      );
      if (!mounted) return;
      if (albums.isEmpty) {
        _status = _Status.empty;
        return;
      }
      _album = albums.first;
      _count = await _album!.assetCountAsync;
      if (!mounted) return;
      if (_count <= 0) {
        _status = _Status.empty;
        return;
      }

      // Seed three distinct random photos.
      _cur.index = _pickIndex(const <int>{});
      _next.index = _pickIndex({_cur.index});
      _prev.index = _pickIndex({_cur.index, _next.index});

      // Load the current one first so we can show something immediately, then
      // reveal the mode (the image fades up from black via shownAtS).
      final curView = await _loadCell(_cur.index);
      if (!mounted) return;
      _cur.view = curView;
      _cur.shownAtS = _nowS;
      _status = _Status.ready;

      // Neighbours load quietly in the background.
      _loadCell(_next.index).then((w) {
        if (mounted && w != null) {
          _next.view = w;
          _next.shownAtS = _nowS;
        }
      });
      _loadCell(_prev.index).then((w) {
        if (mounted && w != null) {
          _prev.view = w;
          _prev.shownAtS = _nowS;
        }
      });
    } finally {
      _busy = false;
    }
  }

  /// A random asset index that avoids the [exclude] set when the album is big
  /// enough to allow it (prevents obvious immediate repeats).
  int _pickIndex(Set<int> exclude) {
    if (_count <= 0) return 0;
    if (_count <= exclude.length + 1) return _rng.nextInt(_count);
    for (var attempt = 0; attempt < 8; attempt++) {
      final i = _rng.nextInt(_count);
      if (!exclude.contains(i)) return i;
    }
    return _rng.nextInt(_count);
  }

  /// Load one asset's screen-sized thumbnail as a ready-to-paint widget.
  Future<Widget?> _loadCell(int index) async {
    final album = _album;
    if (album == null) return null;
    try {
      final list = await album.getAssetListRange(start: index, end: index + 1);
      if (list.isEmpty) return null;
      final Uint8List? bytes =
          await list.first.thumbnailDataWithSize(ThumbnailSize(_tw, _th));
      if (bytes == null) return null;
      return SizedBox.expand(
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        ),
      );
    } catch (_) {
      return null; // corrupt/unavailable asset — skip silently, slot stays black
    }
  }

  // --- Buffer rotation -------------------------------------------------------

  /// Rotate the ring by one step in [dir] (+1 forward, -1 backward) and load a
  /// fresh random photo into the slot that just became the far edge.
  void _shift(int dir) {
    if (_status != _Status.ready) return;

    if (dir > 0) {
      // Forward: prev <- cur <- next, and a new random photo becomes next.
      _prev.copyFrom(_cur);
      _cur.copyFrom(_next);
      final idx = _pickIndex({_cur.index, _prev.index});
      _next
        ..index = idx
        ..view = null;
      _loadCell(idx).then((w) {
        if (mounted && _next.index == idx && w != null) {
          _next.view = w;
          _next.shownAtS = _nowS;
        }
      });
    } else {
      // Backward: next <- cur <- prev, and a new random photo becomes prev.
      _next.copyFrom(_cur);
      _cur.copyFrom(_prev);
      final idx = _pickIndex({_cur.index, _next.index});
      _prev
        ..index = idx
        ..view = null;
      _loadCell(idx).then((w) {
        if (mounted && _prev.index == idx && w != null) {
          _prev.view = w;
          _prev.shownAtS = _nowS;
        }
      });
    }
  }

  // --- Gesture ---------------------------------------------------------------

  double get _dim => _isLandscape ? _size.width : _size.height;

  double _primaryTotal() {
    final g = widget.motion.gestureTotal;
    return _isLandscape ? g.dx : -g.dy; // forward: right (landscape) / up (portrait)
  }

  void _onMotion() {
    final m = widget.motion;

    if (m.isDragging && !_wasDragging) {
      _wasDragging = true;
      _committedDir = 0; // new gesture
    } else if (!m.isDragging && _wasDragging) {
      _wasDragging = false;
      _onRelease(m);
    }

    // Live drag is read in the ticker (1:1 follow); we just note new frames.
    if (m.isDragging && m.updateTick != _lastUpdateTick) {
      _lastUpdateTick = m.updateTick;
    }

    // main.dart commits once per gesture at the threshold; capture its sign.
    if (m.committedScrolls != _lastCommit) {
      _lastCommit = m.committedScrolls;
      if (m.isDragging) _committedDir = m.lastDirection;
    }
  }

  void _onRelease(MotionController m) {
    if (_dim <= 0) return;
    // Decide where to settle: a committed swipe advances exactly one photo;
    // an uncommitted nudge springs back. Seed the spring with the release
    // velocity so a brisk arm flick carries through naturally.
    if (_committedDir != 0) {
      _target = _committedDir.toDouble();
    } else {
      _target = _p.abs() > 0.5 ? _p.sign : 0.0;
    }
    final relV = (_isLandscape ? m.velocity.dx : -m.velocity.dy) / _dim;
    _vel = relV.clamp(-8.0, 8.0).toDouble();
  }

  // --- Per-frame integration -------------------------------------------------

  void _onTick(Duration elapsed) {
    final nowS = elapsed.inMicroseconds / 1e6;
    final dt = (nowS - _prevElapsedS).clamp(0.0, 0.05).toDouble();
    _prevElapsedS = nowS;
    _nowS = nowS;

    final m = widget.motion;
    if (_dim > 0) {
      if (m.isDragging) {
        // Follow the arm 1:1, clamped to one screen so the incoming photo
        // never overshoots past full-frame (no black gap).
        _p = (_primaryTotal() / _dim).clamp(-1.0, 1.0).toDouble();
        _vel = 0.0;
      } else if (_p != _target || _vel != 0.0) {
        // Critically-damped-ish spring settle.
        final a = (-_kStiffness * (_p - _target) - _kDamping * _vel) / _kMass;
        _vel += a * dt;
        _p += _vel * dt;

        if ((_p - _target).abs() < 0.001 && _vel.abs() < 0.01) {
          final landed = _target;
          _p = 0.0;
          _vel = 0.0;
          _target = 0.0;
          if (landed > 0.5) {
            _shift(1);
          } else if (landed < -0.5) {
            _shift(-1);
          }
        }
      }
    }

    _frame.value += 1;
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
                return _buildStrip();
              case _Status.loading:
                // Stay quietly black while the first photo decodes; it fades
                // up on its own the moment it's ready.
                return const SizedBox.expand();
              case _Status.empty:
                return const _Message('No photos found on this device.');
              case _Status.denied:
                return const _Message(
                  'Photo access is off.\n'
                  'Enable it for this app in Settings to scroll the album.',
                );
            }
          },
        ),
      ),
    );
  }

  /// The three-cell film strip, each cell translated along the scroll axis and
  /// faded in gently when its photo first becomes available.
  Widget _buildStrip() {
    final dim = _dim;
    Widget cell(_Cell c, int slot) {
      final d = (slot - _p) * dim; // slot: -1 prev, 0 current, +1 next
      final offset = _isLandscape ? Offset(d, 0) : Offset(0, d);
      final v = c.view;
      if (v == null) {
        return Transform.translate(offset: offset, child: const SizedBox.shrink());
      }
      // Soft fade-up from black (uses the running clock, no extra controllers).
      final op = ((_nowS - (c.shownAtS ?? _nowS)) / _kFadeSeconds)
          .clamp(0.0, 1.0)
          .toDouble();
      return Transform.translate(
        offset: offset,
        child: op >= 1.0 ? v : Opacity(opacity: op, child: v),
      );
    }

    // Draw neighbours first, current last so it sits crisply on top at rest.
    return Stack(
      fit: StackFit.expand,
      children: [
        cell(_prev, -1),
        cell(_next, 1),
        cell(_cur, 0),
      ],
    );
  }
}

/// One photo slot in the ring buffer.
class _Cell {
  int index = 0;
  Widget? view;
  double? shownAtS; // running-clock time the photo became visible (for fade-in)

  void copyFrom(_Cell other) {
    index = other.index;
    view = other.view;
    shownAtS = other.shownAtS;
  }
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