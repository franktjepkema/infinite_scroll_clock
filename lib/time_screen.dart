import 'package:flutter/material.dart';

class TimeScreen extends StatefulWidget {
  final DateTime currentTime;
  final bool is24Hour;
  final Offset dragOffset;
  final bool isDragging;

  const TimeScreen({
    super.key,
    required this.currentTime,
    required this.is24Hour,
    this.dragOffset = Offset.zero,
    this.isDragging = false,
  });

  @override
  State<TimeScreen> createState() => _TimeScreenState();
}

class _TimeScreenState extends State<TimeScreen> with SingleTickerProviderStateMixin {
  late AnimationController _snapController;
  DateTime? _previousTime;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750), // Slower, more luxurious snap
    );
  }

  @override
  void didUpdateWidget(covariant TimeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTime != widget.currentTime) {
      _previousTime = oldWidget.currentTime;
      _snapController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    final fontSize = isLandscape ? 180.0 : 110.0;

    final String currentText = widget.is24Hour
        ? "${widget.currentTime.hour.toString().padLeft(2, '0')}:${widget.currentTime.minute.toString().padLeft(2, '0')}"
        : _to12HourFormat(widget.currentTime);

    return Container(
      color: Colors.black,
      child: Center(
        child: AnimatedBuilder(
          animation: _snapController,
          builder: (context, child) {
            // During drag: follow the mechanical arm slowly
            final Offset dragOffset = widget.isDragging 
                ? widget.dragOffset * 0.75 
                : Offset.zero;

            // After release: slow elegant slide up from bottom
            final double slideProgress = 1.0 - Curves.easeOutCubic.transform(_snapController.value);
            final double slideUp = slideProgress * 180;

            return Transform.translate(
              offset: dragOffset + Offset(0, slideUp),
              child: Text(
                currentText,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w300,
                  fontFamily: 'Helvetica Neue',
                  letterSpacing: -5,
                ),
                textAlign: TextAlign.center,
              ),
            );
          },
        ),
      ),
    );
  }

  String _to12HourFormat(DateTime time) {
    int hour = time.hour % 12;
    if (hour == 0) hour = 12;
    final period = time.hour >= 12 ? 'PM' : 'AM';
    return "${hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} $period";
  }
}