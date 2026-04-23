import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'dart:async';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login_screen.dart';
import 'firebase_options.dart';

void main() async {
  _diagLog('­ƒÜÇ App Launching...');
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialiser Firebase
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    _diagLog('­ƒöÑ Firebase Initialized');
  } catch (e) {
    _diagLog('ÔØî Firebase Error: $e');
  }

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  
  // 2. V├®rifier l'├®tat de connexion
  final prefs = await SharedPreferences.getInstance();
  final bool isLoggedIn = prefs.getBool('is_logged_in') ?? false;

  _diagLog('­ƒôª Running App... (LoggedIn: $isLoggedIn)');
  runApp(MimoNdiApp(isLoggedIn: isLoggedIn));

  // Ô£à Permissions d├®plac├®es dans MainNavigationScreen pour laisser l'interface s'afficher
}

Future<void> _requestPermissions() async {
  try {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.photos,
    ].request();
    _diagLog('Ô£à Permissions handled');
  } catch (e) {
    _diagLog('ÔØî Permissions error: $e');
  }
}

// Helper pour unawaited (si non disponible via pedantic/lints)
void unawaited(Future<void> future) {}

// Diagnostic Console
final List<String> _diagnosticLogs = [];
void _diagLog(String msg) {
  _diagnosticLogs.add('[${DateTime.now().toString().split(' ').last}] $msg');
  if (_diagnosticLogs.length > 50) _diagnosticLogs.removeAt(0);
  print(msg);
}

class MimoNdiApp extends StatelessWidget {
  final bool isLoggedIn;
  const MimoNdiApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MIMO_NDI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF6200EE),
        scaffoldBackgroundColor: Colors.transparent,
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      initialRoute: isLoggedIn ? '/main' : '/login',
      routes: {
        '/login': (context) => const LoginScreen(),
        '/main': (context) => const MainNavigationScreen(),
        '/settings': (context) => const SettingsScreen(),
      },
    );
  }
}

// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
// NAVIGATION PRINCIPALE
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  static const _channel = MethodChannel('com.antigravity/ndi');
  int _selectedIndex = 0;
  List<String> _sources = [];
  bool _isScanning = false;
  Timer? _scanTimer;

  @override
  void initState() {
    // Ô£à S├ëQUENCEUR DE D├ëMARRAGE ULTRA-ROBUSTE
    // T+0: L'interface s'affiche (pas d'├®cran noir)
    
    // T+3s: On r├®veille NDI (Le singleton s'initialise au premier acc├¿s)
    Future.delayed(const Duration(seconds: 3), () {
      _diagLog('­ƒôí Waking up NDI Manager...');
      _channel.invokeMethod('getSources'); // D├®clenche l'init du singleton si pas encore fait
    });

    // T+6s: On commence ├á scanner les sources
    Future.delayed(const Duration(seconds: 6), () {
      _diagLog('­ƒôí Starting Global Scan...');
      _startGlobalScan();
      _scanTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
        _startGlobalScan();
      });
    });

    // T+9s: On demande les permissions Cam├®ra/Micro (d├®clenche le 2├¿me popup)
    // On attend 9s pour ├¬tre S├øR que l'utilisateur a eu le temps de valider le R├®seau Local.
    Future.delayed(const Duration(seconds: 9), () {
      _diagLog('­ƒöÉ Requesting Permissions (Camera/Mic)...');
      _requestPermissions();
    });
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }

  Future<void> _startGlobalScan() async {
    if (_isScanning) return;
    _isScanning = true;
    try {
      final List<dynamic>? result = await _channel.invokeMethod('getSources');
      if (mounted && result != null) {
        final List<String> newSources = result.cast<String>();
        // On ne fait le setState que si la liste change pour ├®viter de clignoter
        if (newSources.length != _sources.length || 
            !newSources.every((s) => _sources.contains(s))) {
          setState(() {
            _sources = newSources;
          });
        }
      }
    } catch (_) {
    } finally {
      _isScanning = false;
    }
  }

  final List<String> _titles = ["Reception Flux", "Transmettre Camera", "Multiview 4", "Regie Mobile", "LivePanel Officiel"];

  List<Widget> get _pages => [
        _selectedIndex == 0 ? NdiReceiveScreen(sources: _sources, isScanning: _isScanning, onRefresh: _startGlobalScan) : const SizedBox.shrink(),
        _selectedIndex == 1 ? const NdiSendScreen() : const SizedBox.shrink(),
        _selectedIndex == 2 ? MultiviewScreen(sources: _sources) : const SizedBox.shrink(),
        _selectedIndex == 3 ? SwitcherScreen(sources: _sources, onRefresh: _startGlobalScan) : const SizedBox.shrink(),
        _selectedIndex == 4 ? const LivePanelScreen() : const SizedBox.shrink(),
      ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E2024), // NewTek NC1 Dark Theme Background
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: FloatingActionButton(
          mini: true,
          backgroundColor: Colors.red.withOpacity(0.5),
          onPressed: () => _showDiagnosticConsole(context),
          child: const Icon(Icons.bug_report, size: 18),
        ),
        appBar: AppBar(
          backgroundColor: Colors.black.withOpacity(0.3),
          elevation: 0,
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(color: Colors.transparent),
            ),
          ),
          title: Text(_titles[_selectedIndex],
              style: const TextStyle(
                  fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          centerTitle: true,
        ),
        drawer: _buildDrawer(),
        body: IndexedStack(
          index: _selectedIndex,
          children: _pages,
        ),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Colors.black.withOpacity(0.8),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(
              image: DecorationImage(
                image: AssetImage('IMG_0730.JPG'),
                fit: BoxFit.cover,
                colorFilter:
                    ColorFilter.mode(Colors.black38, BlendMode.darken),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                CircleAvatar(
                    radius: 30,
                    backgroundImage: AssetImage('IMG_0730.JPG')),
                SizedBox(height: 10),
                Text('MIMO_NDI',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
                Text('Professional Broadcast',
                    style:
                        TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
          ),
          _drawerItem(0, Icons.download, 'Recevoir Flux'),
          _drawerItem(1, Icons.videocam, 'Transmettre Camera'),
          _drawerItem(2, Icons.grid_view, 'Multiview 4'),
          _drawerItem(3, Icons.cut, 'Regie Mobile'),
          _drawerItem(4, Icons.language, 'LivePanel Officiel'),
          const Divider(color: Colors.white24),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.orangeAccent),
            title: const Text('Deconnexion'),
            onTap: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('is_logged_in', false);
              if (context.mounted) {
                Navigator.of(context).pushReplacementNamed('/login');
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings, color: Colors.blueAccent),
            title: const Text('Param├¿tres'),
            onTap: () {
              Navigator.pop(context); // Close drawer
              Navigator.pushNamed(context, '/settings');
            },
          ),
          ListTile(
            leading:
                const Icon(Icons.info_outline, color: Colors.white70),
            title: const Text('├Ç propos'),
            onTap: () {},
          ),
        ],
      ),
    );
  }

  Widget _drawerItem(int index, IconData icon, String title) {
    bool isSelected = _selectedIndex == index;
    return ListTile(
      selected: isSelected,
      selectedTileColor: Colors.white10,
      leading: Icon(icon,
          color: isSelected ? Colors.greenAccent : Colors.white70),
      title: Text(title,
          style: TextStyle(
              color: isSelected ? Colors.greenAccent : Colors.white)),
      onTap: () {
        setState(() => _selectedIndex = index);
        Navigator.pop(context);
      },
    );
  }
}

// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
// ├ëCRAN R├ëCEPTION - LISTE DES SOURCES
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
class NdiReceiveScreen extends StatefulWidget {
  final List<String> sources;
  final bool isScanning;
  final VoidCallback onRefresh;
  
  const NdiReceiveScreen({
    super.key, 
    required this.sources, 
    required this.isScanning, 
    required this.onRefresh
  });

  @override
  State<NdiReceiveScreen> createState() => _NdiReceiveScreenState();
}

class _NdiReceiveScreenState extends State<NdiReceiveScreen> {
  @override
  void initState() {
    super.initState();
  }

  void _openPlayer(String source) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NdiPlayerScreen(sourceName: source),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header sources
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('SOURCES DISPONIBLES',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: Colors.white54)),
              widget.isScanning
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.blueAccent))
                  : IconButton(
                      icon: const Icon(Icons.refresh,
                          size: 20, color: Colors.blueAccent),
                      onPressed: widget.onRefresh,
                      tooltip: "Actualiser la liste",
                    ),

            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white10),
        Expanded(
          child: widget.sources.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_off,
                          size: 48, color: Colors.white24),
                      const SizedBox(height: 16),
                      Text(
                          widget.isScanning
                              ? 'Recherche de sources NDI...'
                              : 'Aucune source trouv├®e',
                          style: const TextStyle(color: Colors.white38)),
                      if (!widget.isScanning) ...[
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: widget.onRefresh,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Rechercher'),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.greenAccent,
                              foregroundColor: Colors.black),
                        )
                      ]
                    ],
                  ),
                )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: widget.sources.length,
                    itemBuilder: (context, index) {
                      final source = widget.sources[index];
                      // Ô£à Utilisation de Card avec InkWell pour un feedback INSTANTAN├ë
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        color: Colors.white.withOpacity(0.08),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Colors.white.withOpacity(0.1)),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _openPlayer(source),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.greenAccent.withOpacity(0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.sensors,
                                      color: Colors.greenAccent, size: 24),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(source,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold)),
                                      const Text('­ƒôí Flux NDI┬« Direct',
                                          style: TextStyle(
                                              color: Colors.white38,
                                              fontSize: 12)),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.play_circle_fill,
                                    color: Colors.greenAccent, size: 36),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }
}

// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
// ├ëCRAN LECTEUR PLEIN ├ëCRAN NDI
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
void _showDiagnosticConsole(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.black,
    builder: (context) => Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('DIAGNOSTIC CONSOLE', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, color: Colors.white)),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _diagnosticLogs.length,
              itemBuilder: (context, i) => Text(_diagnosticLogs[i], style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontFamily: 'monospace')),
            ),
          ),
        ],
      ),
    ),
  );
}

class NdiPlayerScreen extends StatefulWidget {
  final String sourceName;
  const NdiPlayerScreen({super.key, required this.sourceName});

  @override
  State<NdiPlayerScreen> createState() => _NdiPlayerScreenState();
}

class _NdiPlayerScreenState extends State<NdiPlayerScreen> {
  MethodChannel? _viewChannel;
  String _quality = "480p"; // Ô£à D├®marrage Forc├® en 480p (Proxy)
  bool _isLandscape = true;
  bool _isMuted = false;
  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _onViewCreated(int id) {
    _viewChannel = MethodChannel('com.antigravity/ndi_view_$id');
  }

  void _toggleRecord() async {
    if (_viewChannel == null) return;
    final bool? recording = await _viewChannel!.invokeMethod('toggleRecord');
    if (recording != null) {
      setState(() {
        _isRecording = recording;
        if (_isRecording) {
          _recordSeconds = 0;
          _recordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
            setState(() => _recordSeconds++);
          });
        } else {
          _recordTimer?.cancel();
        }
      });
    }
  }

  void _toggleLandscape() {
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight
      ]);
    }
    setState(() => _isLandscape = !_isLandscape);
  }

  void _showQualityMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // Ô£à Permet de contr├┤ler la hauteur si besoin
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text("Choix de la r├®solution", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              _qualityOption("Highest", "1080p (Plein D├®bit HD)"),
              _qualityOption("Medium", "720p (├ëquilibr├®)"),
              _qualityOption("480p", "480p (Proxy - Ultra Stable)"), // Ô£à On s'assure qu'il est l├á
              const SizedBox(height: 30), // Ô£à Plus d'espace en bas
            ],
          ),
        ),
      ),
    );
  }

  Widget _qualityOption(String val, String desc) {
    return ListTile(
      leading: Icon(Icons.check,
          color: _quality == val ? Colors.greenAccent : Colors.transparent),
      title: Text(val),
      subtitle: Text(desc, style: const TextStyle(color: Colors.grey)),
      onTap: () {
        setState(() => _quality = val);
        _viewChannel?.invokeMethod('switchQuality', val);
        Navigator.pop(context);
      },
    );
  }

  void _refreshSources() {
    _viewChannel?.invokeMethod('refreshSources');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Recherche de nouvelles sources NDI..."),
        duration: Duration(seconds: 1),
        backgroundColor: Colors.blueAccent,
      ),
    );
  }

  String _formatDuration(int seconds) {
    int m = seconds ~/ 60;
    int s = seconds % 60;
    return "${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Platform.isIOS
                      ? UiKitView(
                          viewType: 'ndi-view',
                          creationParams: {
                            'name': widget.sourceName,
                            'quality': _quality,
                            'muted': _isMuted,
                          },
                          creationParamsCodec: const StandardMessageCodec(),
                          onPlatformViewCreated: _onViewCreated,
                        )
                      : AndroidView(
                          viewType: 'ndi-view',
                          creationParams: {
                            'name': widget.sourceName,
                            'quality': _quality,
                            'muted': _isMuted,
                          },
                          creationParamsCodec: const StandardMessageCodec(),
                          onPlatformViewCreated: _onViewCreated,
                        ),
              ),
            ),
          ),

          // ÔöÇÔöÇ BOUTON RETOUR
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 22),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
            ),
          ),

          // ÔöÇÔöÇ INDICATEUR ENREGISTREMENT (REC)
          if (_isRecording)
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 70,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(20)),
                child: Row(
                  children: [
                    const Icon(Icons.circle, color: Colors.white, size: 10),
                    const SizedBox(width: 8),
                    Text("REC ${_formatDuration(_recordSeconds)}",
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
              ),
            ),

          // ÔöÇÔöÇ BOUTONS ACTIONS (Droit)
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 20,
            right: 16,
            child: Column(
              children: [
                // ­ƒö┤ BOUTON REC
                GestureDetector(
                  onTap: _toggleRecord,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: _isRecording ? Colors.red : Colors.black54,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24, width: 2),
                    ),
                    child: Icon(_isRecording ? Icons.stop : Icons.videocam, color: Colors.white, size: 28),
                  ),
                ),
                // ­ƒöè Bouton Mute
                GestureDetector(
                  onTap: () => setState(() => _isMuted = !_isMuted),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: _isMuted ? Colors.redAccent : Colors.black54,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Icon(_isMuted ? Icons.volume_off : Icons.volume_up, color: Colors.white, size: 24),
                  ),
                ),
                // ÔÜÖ´©Å Bouton Action (Settings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    children: [

                      // SETTINGS
                      GestureDetector(
                        onTap: _showQualityMenu,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(30)),
                          child: const Icon(Icons.settings, color: Colors.white, size: 24),
                        ),
                      ),
                    ],
                  ),
                ),
                // ­ƒûÑ´©Å Plein ├®cran
                GestureDetector(
                  onTap: _toggleLandscape,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _isLandscape ? Colors.greenAccent.withOpacity(0.85) : Colors.black54,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Icon(_isLandscape ? Icons.fullscreen_exit : Icons.fullscreen,
                        color: _isLandscape ? Colors.black : Colors.white, size: 24),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
// ├ëCRAN TRANSMISSION CAM├ëRA NDI
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
class NdiSendScreen extends StatefulWidget {
  const NdiSendScreen({super.key});

  @override
  State<NdiSendScreen> createState() => _NdiSendScreenState();
}

class _NdiSendScreenState extends State<NdiSendScreen> {
  static const _channel = MethodChannel('com.antigravity/ndi');
  bool _isSending = false;
  String _sourceName = 'MIMO_NDI Camera';

  @override
  void initState() {
    super.initState();
    // Ô£à On attend 5 secondes avant d'allumer la cam├®ra pour laisser passer 
    // les pop-ups de permissions et ├®viter un Deadlock iOS
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) {
        _channel.invokeMethod('setupCamera');
      }
    });
  }

  Future<void> _startSend() async {
    try {
      await _channel.invokeMethod('startSend', {'name': _sourceName});
      if (mounted) setState(() => _isSending = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _stopSend() async {
    try {
      await _channel.invokeMethod('stopSend');
      if (mounted) setState(() => _isSending = false);
    } catch (e) {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  void dispose() {
    if (_isSending) _stopSend();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Aper├ºu cam├®ra (native view)
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                color: Colors.black,
                child: Stack(
                  children: [
                    // Ô£à VUE CAM├ëRA R├ëELLE (Preview Local)
                    Positioned.fill(
                      child: Platform.isIOS
                          ? const UiKitView(
                              viewType: 'ndi-camera-preview',
                              creationParamsCodec: StandardMessageCodec(),
                            )
                          : const AndroidView(
                              viewType: 'ndi-camera-preview',
                              creationParamsCodec: StandardMessageCodec(),
                            ),
                    ),
                    // Calque d'├®tat si non live
                    if (!_isSending)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black45,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.videocam, size: 80, color: Colors.white24),
                                SizedBox(height: 12),
                                Text('Cam├®ra pr├¬te', style: TextStyle(color: Colors.white38, fontSize: 16, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // Indicateur LIVE
                    if (_isSending)
                      Positioned(
                        top: 12,
                        left: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.circle,
                                  color: Colors.white, size: 10),
                              SizedBox(width: 6),
                              Text('LIVE',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Nom de la source NDI
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              children: [
                const Icon(Icons.label_outline,
                    color: Colors.white38, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Nom NDI de la source',
                      hintStyle: TextStyle(color: Colors.white24),
                    ),
                    controller:
                        TextEditingController(text: _sourceName),
                    onChanged: (v) => _sourceName = v,
                    enabled: !_isSending,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Bouton START / STOP
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _isSending ? _stopSend : _startSend,
              icon: Icon(_isSending ? Icons.stop_circle : Icons.play_circle),
              label: Text(
                _isSending
                    ? 'ÔÅ╣  Arr├¬ter la diffusion'
                    : 'ÔûÂ  D├®marrer la diffusion NDI',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    _isSending ? Colors.redAccent : Colors.greenAccent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),

          const SizedBox(height: 10),

          Text(
            _isSending
                ? 'Source visible sur le r├®seau: "$_sourceName"'
                : 'L\'iPhone diffusera sa cam├®ra en NDI sur le r├®seau local',
            textAlign: TextAlign.center,
            style:
                const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
// ├ëCRAN MULTIVIEW 4 SOURCES
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
class MultiviewScreen extends StatefulWidget {
  final List<String> sources;
  const MultiviewScreen({super.key, required this.sources});

  @override
  State<MultiviewScreen> createState() => _MultiviewScreenState();
}

class _MultiviewScreenState extends State<MultiviewScreen> {
  final List<String?> _slots = [null, null, null, null];

  @override
  void initState() {
    super.initState();
  }

  void _assignSource(int slot) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.95),
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Source pour ├®cran ${slot + 1}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            ...widget.sources.map((s) => ListTile(
                  leading: const Icon(Icons.sensors,
                      color: Colors.greenAccent),
                  title: Text(s),
                  onTap: () {
                    setState(() => _slots[slot] = s);
                    Navigator.pop(context);
                  },
                )),
            if (_slots[slot] != null)
              ListTile(
                leading: const Icon(Icons.close, color: Colors.redAccent),
                title: const Text('Vider cet ├®cran',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  setState(() => _slots[slot] = null);
                  Navigator.pop(context);
                },
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _openSlotFullscreen(int slot) {
    final src = _slots[slot];
    if (src == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => NdiPlayerScreen(sourceName: src)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                _buildSlot(0),
                const SizedBox(width: 6),
                _buildSlot(1),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Row(
              children: [
                _buildSlot(2),
                const SizedBox(width: 6),
                _buildSlot(3),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlot(int index) {
    final source = _slots[index];
    return Expanded(
      child: GestureDetector(
        onTap: () => source != null
            ? _openSlotFullscreen(index)
            : _assignSource(index),
        onLongPress: () => _assignSource(index),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border.all(color: Colors.white12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Stack(
              children: [
                // Vid├®o ou placeholder
                if (source != null)
                  Positioned.fill(
                    child: NdiNativeView(
                      key: ValueKey("mv_slot_${index}_$source"),
                      sourceName: source,
                      quality: "480p", // Ô£à On force la basse r├®solution en multiview
                      muted: true, // Ô£à Et on coupe le son pour lib├®rer le Wi-Fi
                    ),
                  )
                else
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_circle_outline,
                            color: Colors.white24, size: 36),
                        const SizedBox(height: 8),
                        Text('├ëcran ${index + 1}',
                            style: const TextStyle(
                                color: Colors.white24, fontSize: 12)),
                        const Text('Appui long pour\nassigner',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white12, fontSize: 10)),
                      ],
                    ),
                  ),
                // Label source
                if (source != null)
                  Positioned(
                    bottom: 4,
                    left: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(source,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 10)),
                    ),
                  ),
                // Bouton plein ├®cran (haut droite)
                if (source != null)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: GestureDetector(
                      onTap: () => _openSlotFullscreen(index),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.fullscreen,
                            color: Colors.white, size: 18),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
// VUE NATIVE NDI (UIKitView iOS)
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
class NdiNativeView extends StatelessWidget {
  final String? sourceName;
  final String? quality; // "Highest", "Medium", "Lowest"
  final bool? muted;
  final PlatformViewCreatedCallback? onViewCreated;
  
  const NdiNativeView({
    super.key, 
    this.sourceName, 
    this.quality,
    this.muted,
    this.onViewCreated,
  });

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return UiKitView(
          viewType: 'ndi-view',
          onPlatformViewCreated: onViewCreated,
          layoutDirection: TextDirection.ltr,
          creationParams: {
            'name': sourceName,
            'quality': quality ?? "Highest",
            'muted': muted ?? false,
          },
          creationParamsCodec: const StandardMessageCodec());
    } else if (Platform.isAndroid) {
      return AndroidView(
          viewType: 'ndi-view',
          onPlatformViewCreated: onViewCreated,
          layoutDirection: TextDirection.ltr,
          creationParams: {
            'name': sourceName,
            'quality': quality ?? "Highest",
            'muted': muted ?? false,
          },
          creationParamsCodec: const StandardMessageCodec());
    }
    return const Center(child: Text('Platform not supported'));
  }
}

class _ModeButton extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeButton({required this.title, required this.icon, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutExpo,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          gradient: isSelected 
              ? const LinearGradient(
                  colors: [Colors.greenAccent, Color(0xFF00C853)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : LinearGradient(
                  colors: [Colors.white.withOpacity(0.1), Colors.white.withOpacity(0.02)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: isSelected ? Colors.greenAccent.withOpacity(0.5) : Colors.white12,
              width: 1),
          boxShadow: isSelected
              ? [BoxShadow(color: Colors.greenAccent.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 4))]
              : [const BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isSelected ? Colors.black87 : Colors.white70, size: 20),
            const SizedBox(height: 6),
            Text(title, style: TextStyle(color: isSelected ? Colors.black87 : Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
          ],
        ),
      ),
    );
  }
}
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
// ­ƒÄ¼ R├ëGIE MOBILE - SWITCHER PRO
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
class SwitcherScreen extends StatefulWidget {
  final List<String> sources;
  final VoidCallback onRefresh;
  const SwitcherScreen({super.key, required this.sources, required this.onRefresh});

  @override
  State<SwitcherScreen> createState() => _SwitcherScreenState();
}

enum SwitcherMode { local, relay, api }

class _SwitcherScreenState extends State<SwitcherScreen> {
  static const _channel = MethodChannel('com.antigravity/ndi');
  int? _activeIndex;
  SwitcherMode _mode = SwitcherMode.local; 
  String _tricasterIp = "192.168.1.100";
  bool _isTricasterRecording = false;
  double _audioVolume = 0.50; // default 50%
  bool _isAudioMuted = false;
  
  // 🔊 VOLUME DEBOUNCING
  Timer? _volumeTimer;
  double? _lastVolumeSent;

  int? _programIndex;
  int? _previewIndex;
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;
  String _lastWords = '';

  @override
  void initState() {
    super.initState();
    _loadIp();
    // _initSpeech(); // ­ƒº¬ TEST : On d├®sactive la voix pour voir si ├ºa r├¿gle le freeze cam├®ra
  }

  Future<void> _loadIp() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _tricasterIp = prefs.getString('switch_api_url') ?? "192.168.1.100";
    });
  }

  void _initSpeech() async {
    _speechEnabled = await _speechToText.initialize();
    setState(() {});
  }

  void _startListening() async {
    if (!_speechEnabled) return; // Permission refus├®e
    await _speechToText.listen(onResult: _onSpeechResult);
    setState(() => _isListening = true);
  }

  void _stopListening() async {
    await _speechToText.stop();
    setState(() => _isListening = false);
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _lastWords = result.recognizedWords.toLowerCase();
      _processVoiceCommand(_lastWords);
    });
  }

  void _processVoiceCommand(String rawCommand) {
    if (!_isListening) return; // ­ƒøí´©Å S├®curit├®: ignorer si micro d├®sactiv├®
    print("Voice Command: $rawCommand");
    // Switcher Commands
    for (int i = 1; i <= 8; i++) {
       if (rawCommand.contains("cam├®ra $i") || rawCommand.contains("camera $i") || rawCommand.contains("num├®ro $i") || rawCommand.contains("number $i")) {
         if (widget.sources.length >= i) _cut(i - 1);
       }
    }
    // Action Commands
    if (rawCommand.contains("record") || rawCommand.contains("enregistre") || rawCommand.contains("direct")) {
      _toggleTricasterRecord();
    }
    if (rawCommand.contains("mute") || rawCommand.contains("coupe le son") || rawCommand.contains("silence")) {
      _toggleMute();
    }
  }

  // Ô£à Version robuste AE2 : On teste le port 5952 ET le port 80 en cas d'erreur
  Future<void> _tricasterCall(String params) async {
    final ports = [5952, 80];
    bool success = false;
    
    for (var port in ports) {
      if (success) break;
      final client = HttpClient();
      try {
        final url = 'http://$_tricasterIp:$port/v1/shortcut?name=$params';
        final Uri uri = Uri.parse(url);
        final req = await client.getUrl(uri).timeout(const Duration(milliseconds: 1500));
        final resp = await req.close();
        if (resp.statusCode == 200) {
          success = true;
          _diagLog('­ƒôí API OK ($port): $params');
        }
      } catch (e) {
        _diagLog('ÔÜá´©Å Port $port fail: $params');
      } finally {
        client.close();
      }
    }
  }

  void _diagLog(String msg) {
    debugPrint(msg);
    // On pourrait aussi l'afficher dans une console UI ici
  }

  Future<void> _toggleTricasterRecord() async {
    setState(() => _isTricasterRecording = !_isTricasterRecording);
    if (_mode == SwitcherMode.api) {
      await _tricasterCall('record_toggle');
    }
  }

  Future<void> _setAudioVolume(double val) async {
    setState(() => _audioVolume = val);
    
    // Ô£à Anti-ramage : On attend 50ms de stabilit├® avant d'envoyer l'ordre HTTP
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 50), () async {
      if (_mode == SwitcherMode.api) {
        // Ô£à On v├®rifie si la valeur a vraiment chang├® pour ├®conomiser le r├®seau
        if (_lastVolumeSent != val) {
          await _tricasterCall('master_volume&value=${val.toStringAsFixed(2)}');
          _lastVolumeSent = val;
        }
      }
    });
  }

  Future<void> _toggleMute() async {
    setState(() => _isAudioMuted = !_isAudioMuted);
    if (_mode == SwitcherMode.api) {
      await _tricasterCall('master_mute&value=${_isAudioMuted ? 1 : 0}');
    }
  }

  @override
  void dispose() {
    if (_mode == SwitcherMode.relay) _channel.invokeMethod('stopRelay');
    super.dispose();
  }

  @override
  void didUpdateWidget(SwitcherScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_programIndex != null && _programIndex! >= widget.sources.length) {
      setState(() => _programIndex = null);
    }
  }

  Future<void> _changeMode(SwitcherMode newMode) async {
    if (_mode == SwitcherMode.relay && newMode != SwitcherMode.relay) {
      await _channel.invokeMethod('stopRelay');
    } else if (newMode == SwitcherMode.relay && _mode != SwitcherMode.relay) {
      await _channel.invokeMethod('startRelay');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Flux RELAIS actif (MIMO_NDI_SWITCH)"),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
    setState(() {
      _mode = newMode;
      _activeIndex = null;
    });
  }

  Future<void> _cut(int index) async {
    if (_programIndex == index) return; // Ô£à ├ëconomie de bande passante
    setState(() => _programIndex = index);

    if (_mode == SwitcherMode.relay) {
      if (index < widget.sources.length) {
        final sourceName = widget.sources[index];
        await _channel.invokeMethod('switchRelay', sourceName);
      }
    } else if (_mode == SwitcherMode.api) {
      // ✅ TriCaster attend "cam1", "cam2"... pour les entrées caméra
      final inputName = "cam${index + 1}";
      await _tricasterCall('main_a_row&value=$inputName');
    }
  }

  Future<void> _preview(int index) async {
    if (_previewIndex == index) return;
    setState(() => _previewIndex = index);
    if (_mode == SwitcherMode.api) {
        final inputName = "cam${index + 1}";
        await _tricasterCall('main_b_row&value=$inputName');
    }
  }

  Future<void> _take() async {
    if (_mode == SwitcherMode.api) {
        await _tricasterCall('main_background_take&value=0');
    }
  }

  Future<void> _auto() async {
    if (_mode == SwitcherMode.api) {
        await _tricasterCall('main_background_auto&value=0');
    }
  }

  void _showDictionary() {
     Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('TriCaster Dictionary'), backgroundColor: Colors.black),
            body: WebViewWidget(
              controller: WebViewController()
                ..setJavaScriptMode(JavaScriptMode.unrestricted)
                ..loadRequest(Uri.parse('http://$_tricasterIp:5952/v1/dictionary')),
            ),
          )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            // 🚥 MODE SELECTOR (Local / Relay / API)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.black,
              child: Row(
                children: [
                  Expanded(
                    child: _ModeButton(
                      title: 'LOCAL',
                      icon: Icons.wifi,
                      isSelected: _mode == SwitcherMode.local,
                      onTap: () => _changeMode(SwitcherMode.local),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ModeButton(
                      title: 'RELAY',
                      icon: Icons.alt_route,
                      isSelected: _mode == SwitcherMode.relay,
                      onTap: () => _changeMode(SwitcherMode.relay),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ModeButton(
                      title: 'API',
                      icon: Icons.settings_remote,
                      isSelected: _mode == SwitcherMode.api,
                      onTap: () => _changeMode(SwitcherMode.api),
                    ),
                  ),
                ],
              ),
            ),
            // ─┬─ COMMANDES PRINCIPALES (REC & AUDIO)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  // REC Button
                  GestureDetector(
                    onTap: _toggleTricasterRecord,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        gradient: _isTricasterRecording 
                            ? const RadialGradient(colors: [Color(0xFFFF5252), Color(0xFFD50000)]) 
                            : RadialGradient(colors: [Colors.white.withOpacity(0.1), Colors.white.withOpacity(0.05)]),
                        shape: BoxShape.circle,
                        border: Border.all(color: _isTricasterRecording ? Colors.redAccent : Colors.white24, width: 3),
                        boxShadow: _isTricasterRecording 
                            ? [BoxShadow(color: Colors.red.withOpacity(0.6), blurRadius: 20, spreadRadius: 2)] 
                            : [],
                      ),
                      child: Center(
                        child: Text('REC', style: TextStyle(
                          color: _isTricasterRecording ? Colors.white : Colors.white70, 
                          fontWeight: FontWeight.w900, 
                          fontSize: 14,
                        )),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  // Audio Controls
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: _toggleMute,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _isAudioMuted ? Colors.redAccent : Colors.white10,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(_isAudioMuted ? Icons.volume_off : Icons.volume_up, 
                                  color: Colors.white, size: 24),
                            ),
                          ),
                          Expanded(
                            child: Column(
                               mainAxisSize: MainAxisSize.min,
                               children: [
                                 SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 12,
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
                                      activeTrackColor: Colors.cyanAccent,
                                      inactiveTrackColor: Colors.white10,
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      value: _audioVolume,
                                      min: 0.0,
                                      max: 1.0,
                                      onChanged: _setAudioVolume,
                                    ),
                                 ),
                                 Text('VOLUME MASTER: ${(_audioVolume * 100).toInt()}%', 
                                    style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                               ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ÔöÇÔöÇ TRANSITIONS AE2 (Take / Auto)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: _buildActionButton(
                      label: 'TAKE',
                      icon: Icons.cut,
                      color: Colors.orange,
                      onTap: _take,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildActionButton(
                      label: 'AUTO',
                      icon: Icons.auto_awesome,
                      color: Colors.blueAccent,
                      onTap: _auto,
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    onPressed: _showDictionary,
                    icon: const Icon(Icons.menu_book, color: Colors.white24, size: 24),
                  ),
                ],
              ),
            ),
            
            // ÔöÇÔöÇ BOUTONS M├ëDIAS & DSK (Seulement mode API)
            if (_mode == SwitcherMode.api)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildMiniButton('DDR1 ▶', () => _tricasterCall('ddr1_play&value=1'), Colors.purple),
                      _buildMiniButton('DDR1 ⏹', () => _tricasterCall('ddr1_stop&value=1'), Colors.deepPurple),
                      _buildMiniButton('DDR2 ▶', () => _tricasterCall('ddr2_play&value=1'), Colors.purple),
                      _buildMiniButton('DSK 1 AUTO', () => _tricasterCall('dsk1_auto&value=1'), Colors.cyan),
                      _buildMiniButton('DSK 2 AUTO', () => _tricasterCall('dsk2_auto&value=1'), Colors.cyan),
                      _buildMiniButton('📷 GRAB', () => _tricasterCall('record_grab&value=1'), Colors.teal),
                    ],
                  ),
                ),
              ),

            // ÔöÇÔöÇ BOUTONS CAM├ëRAS
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
                child: (widget.sources.isEmpty && _mode != SwitcherMode.api)
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.wifi_off, size: 36, color: Colors.white24),
                            const SizedBox(height: 10),
                            const Text('Aucune cam├®ra NDI d├®tect├®e',
                                style: TextStyle(color: Colors.white38)),
                            const SizedBox(height: 10),
                            ElevatedButton.icon(
                              onPressed: widget.onRefresh,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('Rechercher'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.greenAccent,
                                foregroundColor: Colors.black,
                              ),
                            ),
                          ],
                        ),
                      )
                    : GridView.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 140,
                          mainAxisExtent: 80,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: (_mode == SwitcherMode.api) ? 8 : widget.sources.length,
                        itemBuilder: (ctx, i) {
                          final isProgram = _programIndex == i;
                          final isPreview = _previewIndex == i;
                          
                          return GestureDetector(
                            onTap: () => _cut(i),
                            onLongPress: () => _preview(i), // Ô£à Long press pour le Preview
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              curve: Curves.easeOut,
                              decoration: BoxDecoration(
                                color: isProgram ? const Color(0xFF3A3C42) : isPreview ? const Color(0xFF35373C) : const Color(0xFF2B2D32), // Flat NC1 dark block
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: const Color(0xFF1E2024),
                                  width: 1,
                                ),
                              ),
                              child: Stack(
                                children: [
                                  Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text('CAM ${i + 1}',
                                            style: TextStyle(
                                              color: (isProgram || isPreview) ? Colors.white : const Color(0xFFA0A0A0),
                                              fontSize: (isProgram || isPreview) ? 22 : 18,
                                              fontWeight: FontWeight.w900,
                                              fontFamily: 'Courier', // Look plus technique
                                              letterSpacing: 1.2,
                                              shadows: (isProgram || isPreview) ? [const Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 2))] : null,
                                            )),
                                        const SizedBox(height: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.black26,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            (_mode == SwitcherMode.api) 
                                               ? 'TRICASTER IN' 
                                               : widget.sources[i].split(' ').last,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: (isProgram || isPreview) ? Colors.white : Colors.white54,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
        
        // ­ƒÄÖ´©Å VOICE HUD
        if (_isListening || _lastWords.isNotEmpty)
          Positioned(
            bottom: 100, left: 20, right: 20,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: _isListening ? 1.0 : 0.4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: _isListening ? Colors.blueAccent : Colors.white24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_isListening ? Icons.mic : Icons.mic_none, color: _isListening ? Colors.blueAccent : Colors.white54, size: 18),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _isListening ? "├ëcoute: $_lastWords" : "Dernier ordre: $_lastWords",
                          style: TextStyle(color: _isListening ? Colors.white : Colors.white54, fontSize: 13, fontStyle: FontStyle.italic),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // ­ƒÄÖ´©Å MIC BUTTON
        Positioned(
          bottom: 20,
          right: 20,
          child: FloatingActionButton(
            backgroundColor: _isListening ? Colors.blueAccent : Colors.white10,
            onPressed: () {
               if (_isListening) {
                 _stopListening();
               } else {
                 _startListening();
               }
            },
            mini: true,
            child: Icon(_isListening ? Icons.stop : Icons.mic, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton({required String label, required IconData icon, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF2B2D32),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(0.4), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, letterSpacing: 1.0, fontSize: 16)),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniButton(String label, VoidCallback onTap, Color color) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF2B2D32),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(0.3), width: 1),
        ),
        child: Text(label, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
      ),
    );
  }
}

// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
// ­ƒîÉ LIVE PANEL OFFICIEL - WEBVIEW
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ

class LivePanelScreen extends StatefulWidget {
  const LivePanelScreen({super.key});

  @override
  State<LivePanelScreen> createState() => _LivePanelScreenState();
}

class _LivePanelScreenState extends State<LivePanelScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String _targetIp = "192.168.1.100";

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {},
          onPageStarted: (String url) => setState(() => _isLoading = true),
          onPageFinished: (String url) => setState(() => _isLoading = false),
          onWebResourceError: (WebResourceError error) {},
        ),
      );

    _loadIpAndStart();
  }

  Future<void> _loadIpAndStart() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _targetIp = prefs.getString('switch_api_url') ?? "192.168.1.100";
      });
    }

    // Ô£à D├®lai de 3 secondes pour laisser l'app se stabiliser
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        _controller.loadRequest(Uri.parse('http://$_targetIp/'));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        WebViewWidget(controller: _controller),
        if (_isLoading)
          const Center(
            child: CircularProgressIndicator(color: Colors.white70),
          ),
      ],
    );
  }
}

// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ
// ÔÜÖ´©Å PARAM├êTRES R├ëGIE - IP MANUELLE
// ÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇÔöÇ

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _ipController = TextEditingController();
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text = prefs.getString('switch_api_url') ?? "192.168.1.100";
    });
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('switch_api_url', _ipController.text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ô£à Configuration enregistr├®e'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E2024),
      appBar: AppBar(
        title: const Text('PARAM├êTRES R├ëGIE', 
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        backgroundColor: Colors.black.withOpacity(0.3),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('IP TRICASTER / SOURCE API', 
            style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
          const SizedBox(height: 16),
          
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Adresse IP statique', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Utilis├®e quand le Discovery mDNS automatique ne d├®tecte pas votre TriCaster ou votre source NDI.', 
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
                const SizedBox(height: 20),
                TextField(
                  controller: _ipController,
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontFamily: 'Courier', fontWeight: FontWeight.bold),
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.lan, color: Colors.greenAccent),
                    hintText: '192.168.1.XXX',
                    hintStyle: const TextStyle(color: Colors.white10),
                    filled: true,
                    fillColor: Colors.black38,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 40),
          
          SizedBox(
            width: double.infinity,
            height: 60,
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _saveSettings,
              icon: _isSaving 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Icon(Icons.save_rounded),
              label: const Text('APPLIQUER LA CONFIGURATION', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 4,
                shadowColor: Colors.greenAccent.withOpacity(0.3),
              ),
            ),
          ),
          
          const SizedBox(height: 20),
          const Text(
            'Note : La modification de l\'IP red├®marrera les connexions API du Switcher et rechargera le LivePanel.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white24, fontSize: 11, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}
