import 'package:flutter/material.dart';

class TimeScreen extends StatefulWidget {
  final DateTime currentTime;
  final bool is24Hour;
  final int direction;

  const TimeScreen({
    super.key,
    required this.currentTime,
    required this.is24Hour,
    required this.direction,
  });

  @override
  State<TimeScreen> createState() => _TimeScreenState();
}

class _TimeScreenState extends State<TimeScreen> {
  DateTime? previousTime;

  @override
  void didUpdateWidget(covariant TimeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTime != widget.currentTime) {
      previousTime = oldWidget.currentTime;
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeString = _formatTime(widget.currentTime);
    final isSync = previousTime == null;

    // Detect orientation
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        transitionBuilder: (Widget child, Animation<double> animation) {
          final isNew = child.key == ValueKey(timeString);

          Offset beginOffset;

          if (isSync) {
            // Double-tap sync
            if (isLandscape) {
              beginOffset = const Offset(1.0, 0);   // Reversed: from right
            } else {
              beginOffset = const Offset(0, -1.0);  // Vertical: from above (as before)
            }
          } else {
            // Normal scroll behavior
            if (isLandscape) {
              // Horizontal: reversed as requested
              beginOffset = widget.direction > 0 
                  ? const Offset(1.0, 0)    // forward: from right
                  : const Offset(-1.0, 0);  // backward: from left
            } else {
              // Vertical: unchanged
              beginOffset = isNew
                  ? (widget.direction > 0 ? const Offset(0, 1.0) : const Offset(0, -1.0))
                  : (widget.direction > 0 ? const Offset(0, -1.0) : const Offset(0, 1.0));
            }
          }

          return SlideTransition(
            position: Tween<Offset>(begin: beginOffset, end: Offset.zero)
                .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: Text(
          timeString,
          key: ValueKey(timeString),
          style: const TextStyle(
            fontSize: 160,
            fontWeight: FontWeight.w300,
            color: Colors.white,
            letterSpacing: -5,
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final h = time.hour;
    final m = time.minute;
    if (widget.is24Hour) {
      return "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";
    } else {
      final dh = h % 12 == 0 ? 12 : h % 12;
      return "${dh.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} ${h >= 12 ? 'PM' : 'AM'}";
    }
  }
}