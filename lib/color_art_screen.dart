import 'package:flutter/material.dart';
import 'dart:math';

class ColorArtScreen extends StatefulWidget {
  const ColorArtScreen({super.key});

  @override
  State<ColorArtScreen> createState() => _ColorArtScreenState();
}

class _ColorArtScreenState extends State<ColorArtScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<Color> colors = [];
  List<Alignment> centers = [];
  List<double> radii = [];
  int _version = 0;
  final Random rnd = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 90))..repeat();
    _generateNewComposition();
  }

  void _generateNewComposition() {
    _version++;
    colors = List.generate(5, (i) => _randomVividColor()); // 5 colors for richer blobs

    centers = List.generate(5, (i) => Alignment(
      -0.9 + rnd.nextDouble() * 1.8,
      -0.9 + rnd.nextDouble() * 1.8,
    ));

    radii = List.generate(5, (i) => 0.8 + rnd.nextDouble() * 1.4);
  }

  Color _randomVividColor() {
    return HSVColor.fromAHSV(
      1.0,
      rnd.nextDouble() * 360,
      0.75 + rnd.nextDouble() * 0.25,
      0.75 + rnd.nextDouble() * 0.25,
    ).toColor();
  }

  void _triggerNewArtwork() {
    setState(() => _generateNewComposition());
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (_) => _triggerNewArtwork(),
      onHorizontalDragEnd: (_) => _triggerNewArtwork(),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 900),
        transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
        child: Container(
          key: ValueKey(_version),
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: centers[0],
              radius: radii[0],
              colors: [colors[0], colors[1], colors[2]],
              stops: const [0.1, 0.5, 1.0],
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: centers[1],
                radius: radii[1],
                colors: [colors[2].withOpacity(0.85), colors[3].withOpacity(0.7), Colors.transparent],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}