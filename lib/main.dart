import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'dart:async';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const MimoNdiApp());
}

class MimoNdiApp extends StatelessWidget {
  const MimoNdiApp({super.key});

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
      home: const MainNavigationScreen(),
    );
  }
}

// ─────────────────────────────────────────────
// NAVIGATION PRINCIPALE
// ─────────────────────────────────────────────
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
    super.initState();
    _startGlobalScan();
    // Scan toutes les 5 secondes en background pour l'instantanéité
    _scanTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _startGlobalScan();
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
        // On ne fait le setState que si la liste change pour éviter de clignoter
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

  final List<String> _titles = ["Réception Flux", "Transmettre Caméra", "Multiview 4"];

  List<Widget> get _pages => [
        NdiReceiveScreen(sources: _sources, isScanning: _isScanning, onRefresh: _startGlobalScan),
        const NdiSendScreen(),
        MultiviewScreen(sources: _sources),
      ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage('IMG_0730.JPG'),
          fit: BoxFit.cover,
          colorFilter: ColorFilter.mode(Colors.black54, BlendMode.darken),
        ),
      ),

      child: Scaffold(
        backgroundColor: Colors.transparent,
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
          _drawerItem(1, Icons.videocam, 'Transmettre Caméra'),
          _drawerItem(2, Icons.grid_view, 'Multiview 4'),
          const Divider(color: Colors.white24),
          ListTile(
            leading:
                const Icon(Icons.info_outline, color: Colors.white70),
            title: const Text('À propos'),
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

// ─────────────────────────────────────────────
// ÉCRAN RÉCEPTION - LISTE DES SOURCES
// ─────────────────────────────────────────────
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
                      width: 20,
                      height: 20,
                      child:
                          CircularProgressIndicator(strokeWidth: 2))
                  : IconButton(
                      onPressed: widget.onRefresh,
                      icon: const Icon(Icons.refresh, size: 20)),
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
                              : 'Aucune source trouvée',
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
                      // ✅ Utilisation de Card avec InkWell pour un feedback INSTANTANÉ
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
                                      const Text('📡 Flux NDI® Direct',
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

// ─────────────────────────────────────────────
// ÉCRAN LECTEUR PLEIN ÉCRAN NDI
// ─────────────────────────────────────────────
class NdiPlayerScreen extends StatefulWidget {
  final String sourceName;
  const NdiPlayerScreen({super.key, required this.sourceName});

  @override
  State<NdiPlayerScreen> createState() => _NdiPlayerScreenState();
}

class _NdiPlayerScreenState extends State<NdiPlayerScreen> {
  MethodChannel? _viewChannel;
  String _quality = "Lowest";
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
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.92),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
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
              child: Text("Qualité du flux", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            _qualityOption("Highest", "1080p / 4K MAX"),
            _qualityOption("Medium", "720p"),
            _qualityOption("Lowest", "480p / Proxy"),
            const SizedBox(height: 20),
          ],
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
              child: NdiNativeView(
                key: ValueKey("${widget.sourceName}"), // On garde une clé simple, le channel gère le reste
                sourceName: widget.sourceName,
                quality: _quality,
                muted: _isMuted,
                onViewCreated: _onViewCreated,
              ),
            ),
          ),

          // ── BOUTON RETOUR
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 22),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
            ),
          ),

          // ── INDICATEUR ENREGISTREMENT (REC)
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

          // ── BOUTONS ACTIONS (Droit)
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 20,
            right: 16,
            child: Column(
              children: [
                // 🔴 BOUTON REC
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
                // 🔊 Bouton Mute
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
                // ⚙️ Qualité
                GestureDetector(
                  onTap: _showQualityMenu,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(30)),
                    child: const Icon(Icons.settings, color: Colors.white, size: 24),
                  ),
                ),
                // 🖥️ Plein écran
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

// ─────────────────────────────────────────────
// ÉCRAN TRANSMISSION CAMÉRA NDI
// ─────────────────────────────────────────────
class NdiSendScreen extends StatefulWidget {
  const NdiSendScreen({super.key});

  @override
  State<NdiSendScreen> createState() => _NdiSendScreenState();
}

class _NdiSendScreenState extends State<NdiSendScreen> {
  static const _channel = MethodChannel('com.antigravity/ndi');
  bool _isSending = false;
  String _sourceName = 'MIMO_NDI Camera';

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
          // Aperçu caméra (native view)
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                color: Colors.black,
                child: Stack(
                  children: [
                    // Vue caméra (UiKitView dédiée ou placeholder)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.videocam,
                              size: 80,
                              color: _isSending
                                  ? Colors.greenAccent
                                  : Colors.white24),
                          const SizedBox(height: 12),
                          Text(
                            _isSending
                                ? '📡 EN DIRECT — NDI'
                                : 'Caméra prête',
                            style: TextStyle(
                              color: _isSending
                                  ? Colors.greenAccent
                                  : Colors.white38,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
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
                    ? '⏹  Arrêter la diffusion'
                    : '▶  Démarrer la diffusion NDI',
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
                ? 'Source visible sur le réseau: "$_sourceName"'
                : 'L\'iPhone diffusera sa caméra en NDI sur le réseau local',
            textAlign: TextAlign.center,
            style:
                const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ÉCRAN MULTIVIEW 4 SOURCES
// ─────────────────────────────────────────────
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
              child: Text('Source pour écran ${slot + 1}',
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
                title: const Text('Vider cet écran',
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
                // Vidéo ou placeholder
                if (source != null)
                  Positioned.fill(
                    child: NdiNativeView(
                      key: ValueKey("mv_slot_${index}_$source"),
                      sourceName: source,
                      quality: "Lowest", // ✅ On force la basse résolution en multiview
                      muted: true, // ✅ Et on coupe le son pour libérer le Wi-Fi
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
                        Text('Écran ${index + 1}',
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
                // Bouton plein écran (haut droite)
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

// ─────────────────────────────────────────────
// VUE NATIVE NDI (UIKitView iOS)
// ─────────────────────────────────────────────
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
    }
    return const Center(child: Text('Platform not supported'));
  }
}
