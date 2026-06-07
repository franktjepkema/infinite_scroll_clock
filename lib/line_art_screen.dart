import 'dart:math';
import 'package:flutter/material.dart';

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
  late AnimationController _floatController;
  List<Line> _lines = [];
  Offset _scrollOffset = Offset.zero;
  Size? _screenSize;
  bool _isLandscape = true;

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 32),
    )..repeat(reverse: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newSize = MediaQuery.of(context).size;
    final newIsLandscape = newSize.width > newSize.height;

    if (_screenSize != newSize || _isLandscape != newIsLandscape) {
      _screenSize = newSize;
      _isLandscape = newIsLandscape;
      _generateLines();
    }
  }

  @override
  void didUpdateWidget(covariant LineArtScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTime != widget.currentTime) {
      _generateLines();
    }
  }

  @override
  void dispose() {
    _floatController.dispose();
    super.dispose();
  }

  void _generateLines() {
    if (_screenSize == null) return;
    final random = Random();
    final size = _screenSize!;

    _lines.clear();

    final hour = widget.currentTime.hour;
    final minute = widget.currentTime.minute;

    final baseCount = _isLandscape ? 1.0 : 0.75; // Fewer lines in portrait

    for (int i = 0; i < (hour.clamp(3, 23) * baseCount + 5).toInt(); i++) {
      _lines.add(Line(
        start: _randomCentralPoint(size, random),
        length: 65 + random.nextDouble() * 135,
        thickness: 10 + random.nextDouble() * 20,
        angle: random.nextDouble() * pi * 2,
        isHour: true,
      ));
    }

    for (int i = 0; i < (minute.clamp(10, 60) * baseCount + 10).toInt(); i++) {
      _lines.add(Line(
        start: _randomCentralPoint(size, random),
        length: 30 + random.nextDouble() * 100,
        thickness: 1.0,
        angle: random.nextDouble() * pi * 2,
        isHour: false,
      ));
    }

    setState(() {});
  }

  Offset _randomCentralPoint(Size size, Random random) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    return Offset(
      centerX + (random.nextDouble() - 0.5) * size.width * 0.68,
      centerY + (random.nextDouble() - 0.5) * size.height * 0.68,
    );
  }

  void _handleScroll(Offset delta) {
    // Use the dominant direction based on orientation
    final primaryDelta = _isLandscape ? delta.dx : delta.dy;
    
    setState(() {
      _scrollOffset += Offset(delta.dx * 0.8, delta.dy * 0.8);
    });

    widget.onScroll();
    _addEnteringLines(delta);
  }

  void _addEnteringLines(Offset delta) {
    if (_screenSize == null) return;
    final random = Random();
    final size = _screenSize!;

    for (int i = 0; i < 3; i++) {
      _lines.add(Line(
        start: _randomCentralPoint(size, random) - delta * 2.0,
        length: 40 + random.nextDouble() * 110,
        thickness: random.nextBool() ? 1.0 : 11 + random.nextDouble() * 16,
        angle: random.nextDouble() * pi * 2,
        isHour: random.nextBool(),
      ));
    }

    _lines.removeWhere((line) =>
        (line.start + _scrollOffset).distance > size.width * 2.5);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (details) => _handleScroll(details.delta),
      child: Container(
        color: Colors.black,
        child: CustomPaint(
          painter: LineArtPainter(
            lines: _lines,
            scrollOffset: _scrollOffset,
            floatAnimation: _floatController,
            screenSize: _screenSize ?? MediaQuery.of(context).size,
          ),
          size: _screenSize ?? MediaQuery.of(context).size,
        ),
      ),
    );
  }
}

// Line and Painter classes remain the same as before
class Line {
  final Offset start;
  final double length;
  final double thickness;
  final double angle;
  final bool isHour;
  Line({required this.start, required this.length, required this.thickness, required this.angle, required this.isHour});
}

class LineArtPainter extends CustomPainter {
  final List<Line> lines;
  final Offset scrollOffset;
  final Animation<double> floatAnimation;
  final Size screenSize;

  LineArtPainter({required this.lines, required this.scrollOffset, required this.floatAnimation, required this.screenSize});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white..strokeCap = StrokeCap.square;
    final float = sin(floatAnimation.value * pi * 2) * 2.0;

    for (final line in lines) {
      final baseStart = line.start + scrollOffset;
      final floatedStart = baseStart + Offset(0, float * (line.isHour ? 1.4 : 0.8));

      final end = floatedStart + Offset(
        cos(line.angle) * line.length,
        sin(line.angle) * line.length,
      );

      paint.strokeWidth = line.thickness;
      final maxOverhang = line.length * 0.3;

      if (_isMostlyOnScreen(floatedStart, end, size, maxOverhang)) {
        canvas.drawLine(floatedStart, end, paint);
      }
    }
  }

  bool _isMostlyOnScreen(Offset start, Offset end, Size size, double maxOverhang) {
    final lineRect = Rect.fromPoints(start, end);
    final screenRect = Rect.fromLTWH(0, 0, size.width, size.height).inflate(maxOverhang);
    return screenRect.overlaps(lineRect);
  }

  @override
  bool shouldRepaint(covariant LineArtPainter oldDelegate) => true;
}