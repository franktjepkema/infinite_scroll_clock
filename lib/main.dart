import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'time_screen.dart';
import 'line_art_screen.dart';
import 'color_art_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
  String currentMode = 'Time';
  bool is24HourFormat = true;
  DateTime currentTime = DateTime.now();
  int _lastDirection = 1;
  bool _showMenuButton = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      currentMode = prefs.getString('currentMode') ?? 'Time';
      is24HourFormat = prefs.getBool('is24HourFormat') ?? true;
      final savedTime = prefs.getString('savedTime');
      if (savedTime != null) currentTime = DateTime.parse(savedTime);
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currentMode', currentMode);
    await prefs.setBool('is24HourFormat', is24HourFormat);
    await prefs.setString('savedTime', currentTime.toIso8601String());
  }

  void _showMenuTemporarily() {
    setState(() => _showMenuButton = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showMenuButton = false);
    });
  }

  void advanceTime(int minutes) {
    setState(() {
      _lastDirection = minutes > 0 ? 1 : -1;
      currentTime = currentTime.add(Duration(minutes: minutes));
    });
    _savePreferences();
  }

  void syncToRealTime() {
    setState(() => currentTime = DateTime.now());
    _savePreferences();
  }

  void changeMode(String mode) {
    setState(() => currentMode = mode);
    _savePreferences();
  }

  void toggleTimeFormat() {
    setState(() => is24HourFormat = !is24HourFormat);
    _savePreferences();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _showMenuTemporarily,
        onDoubleTap: syncToRealTime,
        onVerticalDragEnd: (details) {
          if (currentMode == 'Time') {
            if (details.primaryVelocity! < -400) advanceTime(1);
            else if (details.primaryVelocity! > 400) advanceTime(-1);
          }
        },
        onHorizontalDragEnd: (details) {
          if (currentMode == 'Time') {
            if (details.primaryVelocity! < -400) advanceTime(1);
            else if (details.primaryVelocity! > 400) advanceTime(-1);
          }
        },
        child: Stack(
          children: [
            _buildCurrentMode(),
            if (_showMenuButton)
              Positioned(
                top: 20,
                left: 20,
                child: Builder(
                  builder: (context) => IconButton(
                    icon: const Icon(Icons.menu, color: Colors.white70, size: 32),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  ),
                ),
              ),
          ],
        ),
      ),
      drawer: _buildDrawer(),
    );
  }

  Widget _buildCurrentMode() {
    switch (currentMode) {
      case 'Color Art':
        return const ColorArtScreen();
      case 'Line Art':
        return LineArtScreen(
          currentTime: currentTime,
          onScroll: () => advanceTime(1),
        );
      case 'Time':
      default:
        return TimeScreen(
          currentTime: currentTime,
          is24Hour: is24HourFormat,
          direction: _lastDirection,
        );
    }
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Colors.black,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.black),
            child: Text('Infinite Scroll', style: TextStyle(fontSize: 28, color: Colors.white)),
          ),
          ListTile(title: const Text('Time'), onTap: () => {changeMode('Time'), Navigator.pop(context)}),
          ListTile(title: const Text('Color Art'), onTap: () => {changeMode('Color Art'), Navigator.pop(context)}),
          ListTile(title: const Text('Line Art'), onTap: () => {changeMode('Line Art'), Navigator.pop(context)}),
          ListTile(
            title: const Text('Time Format'),
            trailing: Text(is24HourFormat ? '24H' : '12H'),
            onTap: () { toggleTimeFormat(); Navigator.pop(context); },
          ),
          ListTile(title: const Text('About'), onTap: () { Navigator.pop(context); _showAboutDialog(); }),
        ],
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('About'),
        content: const Text(
          'Infinite Scroll Clock by Tjep.\n\n'
          'Time only advances through mechanical scrolling.\n\n'
          '• Double-tap to sync with real time\n'
          '• Scroll = advance / rewind time',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }
}