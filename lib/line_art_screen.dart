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

class _LineArtScreenState extends State<LineArtScreen> with TickerProviderStateMixin {
  late List<AnimationController> controllers;
  List<LineData> lines = [];
  final Random rnd = Random();
  int _version = 0;

  @override
  void initState() {
    super.initState();
    _generateLines();
  }

  void _generateLines() {
    lines.clear();
    _version++;

    final hour = widget.currentTime.hour;
    final minute = widget.currentTime.minute;
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;

    controllers = List.generate(hour12 + minute + 25, (index) {
      final controller = AnimationController(
        vsync: this,
        duration: Duration(seconds: 12 + rnd.nextInt(18)),
      )..repeat();
      return controller;
    });

    // Thick lines = Hour
    for (int i = 0; i < hour12; i++) {
      lines.add(LineData(
        thickness: 14.0,
        length: 100 + rnd.nextDouble() * 400,
        angle: rnd.nextDouble() * pi * 2,
        isHour: true,
        controllerIndex: i,
      ));
    }

    // Thin lines = Minute
    for (int i = 0; i < minute; i++) {
      lines.add(LineData(
        thickness: 1.0,
        length: 50 + rnd.nextDouble() * 220,
        angle: rnd.nextDouble() * pi * 2,
        isHour: false,
        controllerIndex: hour12 + i,
      ));
    }

    // Extra thin lines
    for (int i = 0; i < 25; i++) {
      lines.add(LineData(
        thickness: 1.0,
        length: 40 + rnd.nextDouble() * 160,
        angle: rnd.nextDouble() * pi * 2,
        isHour: false,
        controllerIndex: hour12 + minute + i,
      ));
    }
  }

  @override
  void didUpdateWidget(covariant LineArtScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTime != widget.currentTime) {
      // Dispose old controllers
      for (var c in controllers) c.dispose();
      _generateLines();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity!.abs() > 300) widget.onScroll();
      },
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity!.abs() > 300) widget.onScroll();
      },
      child: Stack(
        children: lines.map((line) {
          final controller = controllers[line.controllerIndex];
          final offset = Offset(
            sin(controller.value * 2 * pi) * 25,
            cos(controller.value * 2.3 * pi) * 18,
          );

          return Center(
            child: Transform.translate(
              offset: offset,
              child: Transform.rotate(
                angle: line.angle,
                child: Container(
                  width: line.length,
                  height: line.thickness,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(0),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  @override
  void dispose() {
    for (var controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }
}

class LineData {
  final double thickness;
  final double length;
  final double angle;
  final bool isHour;
  final int controllerIndex;

  LineData({
    required this.thickness,
    required this.length,
    required this.angle,
    required this.isHour,
    required this.controllerIndex,
  });
}