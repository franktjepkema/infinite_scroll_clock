import 'dart:math';
import 'package:flutter/material.dart';

class ColorArtScreen extends StatefulWidget {
  final DateTime currentTime;
  final Offset dragOffset;
  final bool isDragging;

  const ColorArtScreen({
    super.key,
    required this.currentTime,
    this.dragOffset = Offset.zero,
    this.isDragging = false,
  });

  @override
  State<ColorArtScreen> createState() => _ColorArtScreenState();
}

class _ColorArtScreenState extends State<ColorArtScreen> with SingleTickerProviderStateMixin {
  late AnimationController _floatController;
  List<Color> _colors = [];
  List<Alignment> _centers = [];
  List<double> _radii = [];
  int _version = 0;

  Offset _scrollOffset = Offset.zero;
  Size? _screenSize;
  bool _isLandscape = true;

  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 80),
    )..repeat();

    _generateNewComposition();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newSize = MediaQuery.of(context).size;
    final newIsLandscape = newSize.width > newSize.height;

    if (_screenSize != newSize || _isLandscape != newIsLandscape) {
      _screenSize = newSize;
      _isLandscape = newIsLandscape;
      _generateNewComposition();
    }
  }

  @override
  void didUpdateWidget(covariant ColorArtScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Trigger new composition on BOTH double-tap (sync) and mechanical scroll
    if (oldWidget.currentTime != widget.currentTime) {
      _generateNewComposition();
    }
  }

  @override
  void dispose() {
    _floatController.dispose();
    super.dispose();
  }

  void _generateNewComposition() {
    setState(() {
      _version++;
      _colors = List.generate(5, (_) => _randomVividColor());
      _centers = List.generate(5, (_) => Alignment(
        -0.9 + _random.nextDouble() * 1.8,
        -0.9 + _random.nextDouble() * 1.8,
      ));
      _radii = List.generate(5, (_) => 0.7 + _random.nextDouble() * 1.6);
    });
  }

  Color _randomVividColor() {
    return HSVColor.fromAHSV(
      0.95,
      _random.nextDouble() * 360,
      0.65 + _random.nextDouble() * 0.35,
      0.65 + _random.nextDouble() * 0.35,
    ).toColor();
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    setState(() {
      _scrollOffset += details.delta * 0.75;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: _handlePanUpdate,
      child: Container(
        color: Colors.black,
        child: AnimatedBuilder(
          animation: _floatController,
          builder: (context, child) {
            final dragInfluence = widget.isDragging 
                ? widget.dragOffset * 0.75 
                : Offset.zero;

            return Stack(
              children: [
                // Main large gradient layer
                Transform.translate(
                  offset: _scrollOffset + dragInfluence,
                  child: Container(
                    key: ValueKey(_version), // Forces rebuild on new composition
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: _centers[0],
                        radius: _radii[0],
                        colors: [_colors[0], _colors[1], Colors.transparent],
                        stops: const [0.1, 0.55, 1.0],
                      ),
                    ),
                  ),
                ),
                // Second overlapping layer
                Transform.translate(
                  offset: _scrollOffset * 0.65 + dragInfluence,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: _centers[1],
                        radius: _radii[1],
                        colors: [_colors[2].withOpacity(0.85), _colors[3].withOpacity(0.65), Colors.transparent],
                        stops: const [0.2, 0.75, 1.0],
                      ),
                    ),
                  ),
                ),
                // Accent layer
                Transform.translate(
                  offset: _scrollOffset * 1.35 + dragInfluence,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: _centers[3],
                        radius: _radii[3],
                        colors: [_colors[4].withOpacity(0.75), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}