import 'package:flutter/material.dart';
import 'dart:math';

class LineArtScreen extends StatefulWidget {
  final DateTime currentTime;
  final VoidCallback onScroll;

  const LineArtScreen({
    super.key,
    required this.currentTime,
    required this.onScroll,
  });

  @override
  State<LineArtScreen> createState() => _LineArtScreenState();
}

class _LineArtScreenState extends State<LineArtScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<Line> lines = [];
  final Random rnd = Random();
  int _lastHour = -1;
  int _lastMinute = -1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 24))..repeat();
    _generateLines();
  }

  void _generateLines() {
    lines.clear();

    final size = MediaQuery.of(context).size;
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    final safeWidth = size.width * 0.85;
    final safeHeight = size.height * 0.85;

    final hour = widget.currentTime.hour;
    final minute = widget.currentTime.minute;

    // === THICK LINES = HOUR ===
    for (int i = 0; i < hour; i++) {
      lines.add(Line(
        start: Offset(
          centerX - safeWidth / 2 + rnd.nextDouble() * safeWidth,
          centerY - safeHeight / 2 + rnd.nextDouble() * safeHeight,
        ),
        length: 100 + rnd.nextDouble() * 380,
        angle: rnd.nextDouble() * pi * 2,
        thickness: 14.0,
      ));
    }

    // === THIN LINES = MINUTE ===
    for (int i = 0; i < minute; i++) {
      lines.add(Line(
        start: Offset(
          centerX - safeWidth / 2 + rnd.nextDouble() * safeWidth,
          centerY - safeHeight / 2 + rnd.nextDouble() * safeHeight,
        ),
        length: 45 + rnd.nextDouble() * 220,
        angle: rnd.nextDouble() * pi * 2,
        thickness: 1.0,
      ));
    }

    _lastHour = hour;
    _lastMinute = minute;
  }

  @override
  void didUpdateWidget(covariant LineArtScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTime != widget.currentTime) {
      _generateLines();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Extra safety: force regeneration if time changed
    if (widget.currentTime.hour != _lastHour || widget.currentTime.minute != _lastMinute) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _generateLines();
        if (mounted) setState(() {});
      });
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity!.abs() > 300) widget.onScroll();
      },
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity!.abs() > 300) widget.onScroll();
      },
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: LineArtPainter(
              lines: lines,
              animationValue: _controller.value,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class Line {
  Offset start;
  double length;
  double angle;
  double thickness;

  Line({
    required this.start,
    required this.length,
    required this.angle,
    required this.thickness,
  });
}

class LineArtPainter extends CustomPainter {
  final List<Line> lines;
  final double animationValue;

  LineArtPainter({required this.lines, required this.animationValue});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeCap = StrokeCap.butt;

    for (var line in lines) {
      final t = animationValue * 2 * pi;
      final floatX = sin(t * 2.8 + line.start.dx * 0.018) * 11.0;
      final floatY = cos(t * 2.4 + line.start.dy * 0.016) * 8.5;

      final p1 = line.start + Offset(floatX, floatY);
      final p2 = p1 + Offset(cos(line.angle) * line.length, sin(line.angle) * line.length);

      paint.strokeWidth = line.thickness;
      canvas.drawLine(p1, p2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant LineArtPainter oldDelegate) => true;
}