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
  late AnimationController _animationController;
  DateTime? _previousTime;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 580),
    );
  }

  @override
  void didUpdateWidget(covariant TimeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTime != widget.currentTime) {
      _previousTime = oldWidget.currentTime;
      _animationController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
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
          animation: _animationController,
          builder: (context, child) {
            // Follow mechanical drag during swipe
            final dragInfluence = widget.isDragging 
                ? widget.dragOffset * 0.75 
                : Offset.zero;

            // New time slides up from bottom
            final double slideUp = (1.0 - Curves.easeOutCubic.transform(_animationController.value)) * 140;

            return Transform.translate(
              offset: dragInfluence + Offset(0, slideUp),
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