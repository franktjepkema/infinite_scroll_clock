// lib/motion_controller.dart
import 'package:flutter/material.dart';

// --- Shared tuning constants -------------------------------------------------

/// Net movement (logical pixels, along the primary axis) a swipe must reach
/// before it commits one minute in the *art* modes. Displacement-based, not
/// velocity-based, so slow mechanical-arm swipes register reliably.
/// (Time mode uses its own physics model in TimeScreen and ignores this.)
const double kCommitThreshold = 34.0;

/// Flip if the mechanical arm advances time opposite to what reads naturally on
/// screen. Inverts forward/backward globally for every mode.
const bool kInvertScrollDirection = false;

/// Central, lightweight motion/gesture bus shared between [MainScreen] and the
/// individual mode screens.
///
/// Why this exists:
/// All gestures are captured by ONE detector in [MainScreen] and pushed into
/// this [ChangeNotifier]. Only the active mode screen listens, so a single
/// CustomPaint / strip repaints per frame instead of rebuilding the whole tree
/// at 60 fps. Time mode reads the live deltas (for 1:1 follow) and the release
/// velocity (for inertia); the art modes read the deltas and the commit counter.
class MotionController extends ChangeNotifier {
  /// True while a pan gesture (finger or mechanical arm) is in progress.
  bool isDragging = false;

  /// True when the current display orientation is landscape (horizontal mount).
  bool isLandscape = true;

  /// The most recent incremental movement for the active gesture (this frame).
  Offset liveDelta = Offset.zero;

  /// Accumulated movement since the current gesture began.
  Offset gestureTotal = Offset.zero;

  /// Release velocity (logical px/s), set on [end]. Drives Time-mode inertia.
  Offset velocity = Offset.zero;

  /// Increments on every [update] call. Listeners cache the last value to
  /// distinguish a genuine drag frame from a begin/commit/end notification.
  int updateTick = 0;

  /// Monotonic counter, incremented once for every committed minute step
  /// (used by the art modes; Time mode steps through its own callback).
  int committedScrolls = 0;

  /// Sign (+1 / -1) of the most recently committed scroll step.
  int lastDirection = 1;

  /// Called by [MainScreen] when a new pan gesture begins.
  void begin(bool landscape) {
    isDragging = true;
    isLandscape = landscape;
    liveDelta = Offset.zero;
    gestureTotal = Offset.zero;
    notifyListeners();
  }

  /// Called on every pan update with the per-frame delta.
  void update(Offset delta) {
    liveDelta = delta;
    gestureTotal += delta;
    updateTick++;
    notifyListeners();
  }

  /// Called when an art-mode swipe crosses the commit threshold. [direction] is
  /// +1 / -1.
  void commit(int direction) {
    lastDirection = direction;
    committedScrolls++;
    notifyListeners();
  }

  /// Called when the pan gesture finishes. [v] is the fling velocity in px/s.
  void end(Offset v) {
    isDragging = false;
    velocity = v;
    liveDelta = Offset.zero;
    gestureTotal = Offset.zero;
    notifyListeners();
  }
}