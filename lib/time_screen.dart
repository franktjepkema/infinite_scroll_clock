// lib/time_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'motion_controller.dart';

/// The clock face.
///
/// The time is NOT driven by the system clock; it is supplied by [MainScreen]
/// and changes only when a swipe commits a minute or the user double-taps to
/// sync.
///
/// Interaction model (a vertical/horizontal "film-strip" of minutes):
///   * While the mechanical arm swipes, the digits follow it 1:1 in real time.
///   * On release the motion continues with the arm's release velocity
///     (inertia) via a spring simulation.
///   * The current minute and the adjacent minute are rendered one screen apart,
///     so the old time slides off one edge at the exact instant the new time
///     arrives from the opposite edge — a single continuous hand-off.
///   * If the swipe doesn't pass the half-screen point, it springs back and no
///     minute is committed.
class TimeScreen extends StatefulWidget {
  final DateTime currentTime;
  final bool is24Hour;
  final MotionController motion;

  /// Called when a swipe settles onto the next/previous minute. [direction] is
  /// +1 (forward) or -1 (back). [MainScreen] updates the authoritative time.
  final void Function(int direction) onStep;

  const TimeScreen({
    super.key,
    required this.currentTime,
    required this.is24Hour,
    required this.motion,
    required this.onStep,
  });

  @override
  State<TimeScreen> createState() => _TimeScreenState();
}

class _TimeScreenState extends State<TimeScreen>
    with SingleTickerProviderStateMixin {
  /// Forward scroll progress in logical px. 0 = current minute centred; grows
  /// as the arm swipes "forward" (up in portrait, right in landscape).
  final ValueNotifier<double> _p = ValueNotifier<double>(0.0);

  /// Unbounded controller that plays the release inertia/spring on [_p].
  late final AnimationController _settle;

  /// Quick crossfade used only for double-tap sync.
  late final AnimationController _fade;

  bool _isLandscape = true;
  double _dim = 1.0; // primary-axis screen dimension
  int _lastTick = -1;
  bool _wasDragging = false;
  bool _selfStep = false;
  int? _pendingDir;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController.unbounded(vsync: this)
      ..addListener(() => _p.value = _settle.value);
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
      value: 1.0,
    );
    widget.motion.addListener(_onMotion);
  }

  @override
  void didUpdateWidget(TimeScreen old) {
    super.didUpdateWidget(old);
    if (old.motion != widget.motion) {
      old.motion.removeListener(_onMotion);
      widget.motion.addListener(_onMotion);
    }
    if (old.currentTime != widget.currentTime) {
      if (_selfStep) {
        // Our own committed step already reset _p; the new minute is centred.
        _selfStep = false;
      } else {
        // External change (double-tap sync): snap to centre + quick fade-in.
        if (_settle.isAnimating) _settle.stop();
        _pendingDir = null;
        _p.value = 0.0;
        _fade.forward(from: 0.0);
      }
    }
  }

  @override
  void dispose() {
    widget.motion.removeListener(_onMotion);
    _settle.dispose();
    _fade.dispose();
    _p.dispose();
    super.dispose();
  }

  // --- Gesture -> physics ----------------------------------------------------

  /// Forward component of a delta/velocity, honouring orientation + global flip.
  double _forward(Offset v) {
    var f = _isLandscape ? v.dx : -v.dy;
    if (kInvertScrollDirection) f = -f;
    return f;
  }

  void _onMotion() {
    final m = widget.motion;
    if (m.isDragging && !_wasDragging) {
      // Gesture begins: take over from any running settle.
      _wasDragging = true;
      if (_settle.isAnimating) {
        _settle.stop();
        _pendingDir = null;
      }
    } else if (m.isDragging && m.updateTick != _lastTick) {
      // Live 1:1 follow.
      _lastTick = m.updateTick;
      _p.value += _forward(m.liveDelta);
    } else if (!m.isDragging && _wasDragging) {
      // Gesture ends: continue with inertia.
      _wasDragging = false;
      _release(_forward(m.velocity));
    }
  }

  void _release(double forwardVelocity) {
    final pos = _p.value;

    // Predict where the momentum lands, then snap to at most one page.
    // The threshold is deliberately permissive (~15% of the screen) so that a
    // single clean arm swipe reliably commits and the old time continues off
    // the screen, instead of springing back to centre.
    final projected = pos + forwardVelocity * 0.25;
    int dir;
    if (projected >= _dim * 0.15) {
      dir = 1;
    } else if (projected <= -_dim * 0.15) {
      dir = -1;
    } else {
      dir = 0;
    }
    final target = dir * _dim;
    _pendingDir = dir;

    // Near-critical spring: smooth settle, negligible overshoot.
    final spring =
        SpringDescription(mass: 1.0, stiffness: 220.0, damping: 30.0);
    final sim = SpringSimulation(spring, pos, target, forwardVelocity);

    _settle.animateWith(sim).then((_) {
      final d = _pendingDir;
      _pendingDir = null;
      if (d == null) return;
      if (d != 0) {
        _selfStep = true;
        widget.onStep(d); // MainScreen advances the authoritative time
      }
      _p.value = 0.0; // new current minute is now exactly centred
    }).catchError((_) {
      // Settle was interrupted by a new drag — ignore.
      _pendingDir = null;
    });
  }

  // --- Formatting ------------------------------------------------------------

  String _format(DateTime t) {
    final m = t.minute.toString().padLeft(2, '0');
    if (widget.is24Hour) {
      return '${t.hour.toString().padLeft(2, '0')}:$m';
    }
    var h = t.hour % 12;
    if (h == 0) h = 12;
    // Pad the hour too, keeping the HH:MM block width stable and centred.
    return '${h.toString().padLeft(2, '0')}:$m';
  }

  TextStyle _style(double size) => TextStyle(
        color: Colors.white,
        fontSize: size,
        fontWeight: FontWeight.w100, // Thin — the thinnest standard weight
        // letterSpacing scales linearly with size, so the width measurement in
        // _fitFontSize stays valid after scaling.
        letterSpacing: -size * 0.03,
        fontFamily: 'Helvetica Neue',
        fontFamilyFallback: const ['Helvetica', 'Arial', 'Roboto'],
        height: 1.0,
      );

  /// Measure a 5-char sample once, then scale so the digits fill the target
  /// fraction of the box (width-bound or height-bound, whichever is tighter).
  /// All minutes share the same width, so one size fits every cell.
  double _fitFontSize(double maxWidth, double maxHeight) {
    const base = 240.0;
    final tp = TextPainter(
      text: TextSpan(text: '00:00', style: _style(base)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final wBase = tp.width;
    final hBase = tp.height;
    if (wBase <= 0 || hBase <= 0) return base;
    final byWidth = (maxWidth * 0.82) / wBase * base;
    final byHeight = (maxHeight * 0.70) / hBase * base;
    // 15% smaller than the maximum that would fit, per design.
    return (byWidth < byHeight ? byWidth : byHeight) * 0.85;
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        _isLandscape = w > h;
        _dim = _isLandscape ? w : h;

        final size = _fitFontSize(w, h); // once per layout, not per frame

        return AnimatedBuilder(
          animation: Listenable.merge([_p, _fade]),
          builder: (context, _) {
            final p = _p.value;
            final cells = <Widget>[];

            // Render the current minute and its neighbours. They sit one screen
            // apart, so the hand-off between minutes is seamless and continuous.
            for (var k = -2; k <= 2; k++) {
              final off = _isLandscape
                  ? Offset(p - k * _dim, 0)
                  : Offset(0, k * _dim - p);
              final along = _isLandscape ? off.dx : off.dy;
              if (along.abs() > _dim * 1.1) continue; // cull off-screen cells

              final t = widget.currentTime.add(Duration(minutes: k));
              cells.add(
                Transform.translate(
                  offset: off,
                  child: Text(_format(t),
                      maxLines: 1, style: _style(size)),
                ),
              );
            }

            return Opacity(
              opacity: _fade.value.clamp(0.0, 1.0),
              child: Stack(alignment: Alignment.center, children: cells),
            );
          },
        );
      },
    );
  }
}