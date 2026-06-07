// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'motion_controller.dart';
import 'time_screen.dart';
import 'line_art_screen.dart';
import 'color_art_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Allow both mountings; the app detects the actual orientation at runtime.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // True full-screen: no status bar, no navigation bar.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // NOTE: for the permanent wall installation, keep the screen awake by adding
  // `wakelock_plus` to pubspec.yaml and calling `WakelockPlus.enable();` here.
  runApp(const InfiniteScrollClockApp());
}

class InfiniteScrollClockApp extends StatelessWidget {
  const InfiniteScrollClockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Infinite Scroll Clock',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // Single source of truth for gestures, shared with the active mode screen.
  final MotionController _motion = MotionController();

  String _mode = 'Time';
  bool _is24Hour = true;
  DateTime _time = DateTime.now();

  // Menu is a custom overlay (NOT a Scaffold drawer) so its taps can never be
  // lost to the full-screen gesture detector, and the mechanical arm's edge
  // swipes can never trip it open.
  bool _menuButtonVisible = false;
  bool _menuOpen = false;
  Timer? _hideTimer;

  bool _isLandscape = true;
  bool _committedThisGesture = false;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  // --- Persistence -----------------------------------------------------------

  Future<void> _loadPreferences() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _mode = p.getString('mode') ?? 'Time';
      _is24Hour = p.getBool('is24Hour') ?? true;
      final saved = p.getString('savedTime');
      if (saved != null) {
        final t = DateTime.tryParse(saved);
        if (t != null) _time = t;
      }
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('mode', _mode);
    await p.setBool('is24Hour', _is24Hour);
    await p.setString('savedTime', _time.toIso8601String());
  }

  // --- Time control ----------------------------------------------------------

  /// Advance (or reverse) the displayed time. DateTime arithmetic handles the
  /// 23:59 -> 00:00 wrap (and back) for free.
  void _advance(int minutes) {
    setState(() => _time = _time.add(Duration(minutes: minutes)));
    _save();
  }

  void _syncToRealTime() {
    setState(() => _time = DateTime.now());
    _save();
  }

  // --- Gesture handling (centralised for ALL modes) --------------------------

  void _onPanStart(DragStartDetails d) {
    _committedThisGesture = false;
    _motion.begin(_isLandscape);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    _motion.update(d.delta);

    // Time and Line Art modes run a physics model in their own screens (live
    // 1:1 follow + inertia) and report each committed minute back via onStep.
    // Only Color Art relies on the threshold-based commit here.
    if (_mode == 'Time' || _mode == 'Line Art') return;
    if (_committedThisGesture) return;

    // Landscape: rightward (+dx) is forward. Portrait: upward (-dy) is forward.
    final primary =
        _isLandscape ? _motion.gestureTotal.dx : -_motion.gestureTotal.dy;

    if (primary.abs() >= kCommitThreshold) {
      var dir = primary > 0 ? 1 : -1;
      if (kInvertScrollDirection) dir = -dir;
      _committedThisGesture = true;
      _advance(dir);
      _motion.commit(dir); // lets Color Art evolve on the step
    }
  }

  void _onPanEnd(DragEndDetails d) {
    _motion.end(d.velocity.pixelsPerSecond);
  }

  // --- Menu ------------------------------------------------------------------

  void _revealMenuButton() {
    if (_menuOpen) return;
    setState(() => _menuButtonVisible = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _menuButtonVisible = false);
    });
  }

  void _openMenu() {
    _hideTimer?.cancel();
    setState(() {
      _menuOpen = true;
      _menuButtonVisible = false;
    });
  }

  void _closeMenu() => setState(() => _menuOpen = false);

  void _changeMode(String m) {
    setState(() {
      _mode = m;
      _menuOpen = false;
    });
    _save();
  }

  void _toggleFormat() {
    setState(() => _is24Hour = !_is24Hour); // keep the menu open
    _save();
  }

  void _openAbout() {
    setState(() => _menuOpen = false);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AboutScreen()),
    );
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    _isLandscape = size.width > size.height;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1) Gesture-driven content (bottom layer).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _revealMenuButton,
              onDoubleTap: _syncToRealTime,
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: _buildMode(),
            ),
          ),

          // 2) Hamburger button — sits ABOVE the gesture layer, so a tap on it
          //    resolves to the button (no arena loss to the background).
          if (_menuButtonVisible && !_menuOpen)
            Positioned(
              top: 14,
              left: 14,
              child: SafeArea(child: _MenuButton(onTap: _openMenu)),
            ),

          // 3) Slide-in menu overlay (top layer). Ignores pointers when closed.
          Positioned.fill(
            child: _MenuOverlay(
              open: _menuOpen,
              currentMode: _mode,
              is24Hour: _is24Hour,
              onClose: _closeMenu,
              onSelect: _changeMode,
              onToggleFormat: _toggleFormat,
              onAbout: _openAbout,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMode() {
    switch (_mode) {
      case 'Color Art':
        return ColorArtScreen(motion: _motion);
      case 'Line Art':
        return LineArtScreen(
          currentTime: _time,
          motion: _motion,
          onStep: _advance, // physics model commits a minute through here
        );
      case 'Time':
      default:
        return TimeScreen(
          currentTime: _time,
          is24Hour: _is24Hour,
          motion: _motion,
          onStep: _advance, // physics model commits a minute through here
        );
    }
  }
}

/// Minimal three-bar hamburger button.
class _MenuButton extends StatelessWidget {
  final VoidCallback onTap;
  const _MenuButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Icon(Icons.menu, color: Colors.white, size: 30),
        ),
      ),
    );
  }
}

/// Self-contained slide-in menu: a tap-to-dismiss scrim plus a panel that
/// animates in from the left. Fully state-driven, so nothing depends on the
/// gesture arena and the arm cannot open it by accident.
class _MenuOverlay extends StatelessWidget {
  final bool open;
  final String currentMode;
  final bool is24Hour;
  final VoidCallback onClose;
  final void Function(String mode) onSelect;
  final VoidCallback onToggleFormat;
  final VoidCallback onAbout;

  const _MenuOverlay({
    required this.open,
    required this.currentMode,
    required this.is24Hour,
    required this.onClose,
    required this.onSelect,
    required this.onToggleFormat,
    required this.onAbout,
  });

  @override
  Widget build(BuildContext context) {
    final panelW =
        (MediaQuery.of(context).size.width * 0.78).clamp(220.0, 340.0);

    return IgnorePointer(
      ignoring: !open,
      child: Stack(
        children: [
          // Scrim.
          AnimatedOpacity(
            duration: const Duration(milliseconds: 220),
            opacity: open ? 1 : 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: Container(color: Colors.black.withOpacity(0.55)),
            ),
          ),
          // Panel.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            left: open ? 0 : -panelW,
            top: 0,
            bottom: 0,
            width: panelW,
            child: Material(
              color: const Color(0xF2000000),
              child: SafeArea(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 36, 24, 24),
                      child: Text(
                        'Infinite Scroll',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w300,
                            letterSpacing: 0.5),
                      ),
                    ),
                    _tile('Time',
                        selected: currentMode == 'Time',
                        onTap: () => onSelect('Time')),
                    _tile('Color Art',
                        selected: currentMode == 'Color Art',
                        onTap: () => onSelect('Color Art')),
                    _tile('Line Art',
                        selected: currentMode == 'Line Art',
                        onTap: () => onSelect('Line Art')),
                    const Divider(
                        color: Colors.white24,
                        height: 1,
                        indent: 24,
                        endIndent: 24),
                    _tile('Time Format',
                        trailing: is24Hour ? '24H' : '12H',
                        onTap: onToggleFormat),
                    _tile('About', onTap: onAbout),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(String label,
      {bool selected = false, String? trailing, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white70,
                  fontSize: 18,
                  fontWeight: selected ? FontWeight.w400 : FontWeight.w300,
                ),
              ),
            ),
            if (trailing != null)
              Text(trailing,
                  style: const TextStyle(color: Colors.white54, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

/// About page: short context on the series plus a setup/usage tutorial.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(
        color: Colors.white,
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w300);
    const head = TextStyle(
        color: Colors.white,
        fontSize: 22,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.5);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(28, 72, 28, 40),
              children: const [
                Text('Infinite Scroll', style: head),
                SizedBox(height: 16),
                Text(
                  'Infinite Scroll is a series of kinetic sculptures by the design '
                  'studio Tjep. that mechanize the compulsive gesture of digital '
                  'scrolling. In Scrolling Through Time, a wall-mounted smartphone '
                  'becomes a clock whose minutes are advanced only by a precise '
                  'mechanical arm.',
                  style: body,
                ),
                SizedBox(height: 28),
                Text('Setup', style: head),
                SizedBox(height: 12),
                Text(
                  'Mount the phone in the sculpture (horizontal or vertical) and '
                  'launch this app. It runs full-screen and adapts to the '
                  'orientation automatically.',
                  style: body,
                ),
                SizedBox(height: 20),
                Text('How time works', style: head),
                SizedBox(height: 12),
                Text(
                  'The clock ignores the system time. Each clean swipe from the '
                  'mechanical arm advances the display by exactly one minute; a '
                  'swipe the other way moves it back.',
                  style: body,
                ),
                SizedBox(height: 20),
                Text('Synchronising', style: head),
                SizedBox(height: 12),
                Text(
                  'Double-tap anywhere on the screen to snap the clock to the real '
                  'current time. After that, only mechanical scrolling advances it.',
                  style: body,
                ),
                SizedBox(height: 20),
                Text('Switching artworks', style: head),
                SizedBox(height: 12),
                Text(
                  'Touch the screen to reveal the menu in the top-left corner, then '
                  'choose Time, Color Art or Line Art, or toggle the 24-hour / '
                  '12-hour format.',
                  style: body,
                ),
              ],
            ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}