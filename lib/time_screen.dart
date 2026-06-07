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
  late AnimationController _transitionController;
  DateTime? _oldTime;

  @override
  void initState() {
    super.initState();
    _transitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 7200),
    );

    _transitionController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _oldTime = null);
      }
    });
  }

  @override
  void didUpdateWidget(covariant TimeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTime != widget.currentTime) {
      _oldTime = oldWidget.currentTime;
      _transitionController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _transitionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isLandscape = screenSize.width > screenSize.height;
    final fontSize = isLandscape ? 172.0 : 112.0;

    final String currentText = widget.is24Hour
        ? "${widget.currentTime.hour.toString().padLeft(2, '0')}:${widget.currentTime.minute.toString().padLeft(2, '0')}"
        : _to12HourFormat(widget.currentTime);

    final String oldText = _oldTime != null
        ? (widget.is24Hour
            ? "${_oldTime!.hour.toString().padLeft(2, '0')}:${_oldTime!.minute.toString().padLeft(2, '0')}"
            : _to12HourFormat(_oldTime!))
        : currentText;

    return Container(
      color: Colors.black,
      child: Center(
        child: AnimatedBuilder(
          animation: _transitionController,
          builder: (context, child) {
            final progress = _transitionController.value;
            final slowedProgress = (progress * 0.32).clamp(0.0, 1.0);
            final ease = Curves.easeOutCubic.transform(slowedProgress);

            final drag = widget.isDragging ? widget.dragOffset * 0.94 : Offset.zero;

            // Sequential: new time only starts after old time is 65% gone
            final newTimeProgress = (progress - 0.65).clamp(0.0, 1.0) / 0.35;

            return Stack(
              alignment: Alignment.center,
              children: [
                // Old time — pushed out by mech arm (strong live drag restored)
                if (_oldTime != null)
                  Transform.translate(
                    offset: drag + Offset(0, -ease * 650),
                    child: Opacity(
                      opacity: (1.0 - progress) * 0.9,
                      child: Text(
                        oldText,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: fontSize,
                          fontWeight: FontWeight.w200,
                          letterSpacing: -7.0,
                          height: 1.0,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),

                // New time — automated, starts only after old time is mostly out (exactly as you like)
                Transform.translate(
                  offset: Offset(0, (1.0 - newTimeProgress) * 620),
                  child: Text(
                    currentText,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: fontSize,
                      fontWeight: FontWeight.w200,
                      letterSpacing: -7.0,
                      height: 1.0,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
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