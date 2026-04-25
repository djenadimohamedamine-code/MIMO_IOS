import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ──────────────────────────────────────────────────────────
// PROTOCOLE NICOLAUDIE UDP (Port 2430)
// Paquet 4 octets: [Commande] [SceneX] [SceneY] [255]
// Commandes: 1=Play, 2=Stop, 3=Pause, 4=Resume, 5=Reset
// ──────────────────────────────────────────────────────────
class SunlightApi {
  final String ipAddress;
  final int port;

  SunlightApi({this.ipAddress = "192.168.1.65", this.port = 2430});

  Future<void> _sendUdp(List<int> bytes) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(bytes, InternetAddress(ipAddress), port);
      print("☀️ Sunlite UDP → $ipAddress:$port  [${bytes.join(', ')}]");
    } catch (e) {
      print("❌ Sunlite UDP Error: $e");
    } finally {
      socket?.close();
    }
  }

  /// Joue une scène par son numéro (0 à 499)
  Future<void> playScene(int sceneNumber) async {
    final x = sceneNumber % 256;
    final y = sceneNumber ~/ 256;
    await _sendUdp([1, x, y, 255]);
  }

  /// Arrête une scène
  Future<void> stopScene(int sceneNumber) async {
    final x = sceneNumber % 256;
    final y = sceneNumber ~/ 256;
    await _sendUdp([2, x, y, 255]);
  }

  /// Pause une scène
  Future<void> pauseScene(int sceneNumber) async {
    final x = sceneNumber % 256;
    final y = sceneNumber ~/ 256;
    await _sendUdp([3, x, y, 255]);
  }

  /// Reprendre une scène (après pause)
  Future<void> resumeScene(int sceneNumber) async {
    final x = sceneNumber % 256;
    final y = sceneNumber ~/ 256;
    await _sendUdp([4, x, y, 255]);
  }

  /// Reset (arrêt total)
  Future<void> resetAll() async {
    await _sendUdp([5, 0, 0, 255]);
  }
}

// ──────────────────────────────────────────────────────────
// MODÈLE DE SCÈNE
// ──────────────────────────────────────────────────────────
class SunliteScene {
  final String name;
  final String group;
  final int sceneNumber; // Numéro de scène dans Sunlite (commence à 0)
  final Color color;
  final IconData icon;

  const SunliteScene({
    required this.name,
    required this.group,
    required this.sceneNumber,
    required this.color,
    required this.icon,
  });
}

// ──────────────────────────────────────────────────────────
// SCÈNES — basées sur la console Sunlite (photos)
//
// ⚠️ NUMÉROS DE SCÈNE : dans Sunlite, va dans
//    Controller → Cycle pour voir l'ordre des scènes.
//    La 1ère scène = 0, la 2ème = 1, etc.
// ──────────────────────────────────────────────────────────
final List<SunliteScene> sunliteScenes = [

  // ── LED PAR PLATEAU (colonne gauche dans la console) ──
  SunliteScene(name: 'INIT',      group: 'LED PAR plateau', sceneNumber: 0, color: Colors.white54,     icon: Icons.power_settings_new),
  SunliteScene(name: 'entree',    group: 'LED PAR plateau', sceneNumber: 1, color: Colors.blueAccent,  icon: Icons.login),
  SunliteScene(name: 'emission',  group: 'LED PAR plateau', sceneNumber: 2, color: Colors.greenAccent, icon: Icons.fiber_manual_record),
  SunliteScene(name: 'all',       group: 'LED PAR plateau', sceneNumber: 3, color: Colors.white,       icon: Icons.wb_sunny),

  // ── LED PAR PUBLIC (colonne droite dans la console) ──
  SunliteScene(name: 'INIT',         group: 'LED PAR public', sceneNumber: 4, color: Colors.white54,      icon: Icons.power_settings_new),
  SunliteScene(name: 'face public',  group: 'LED PAR public', sceneNumber: 5, color: Colors.orangeAccent, icon: Icons.people),
  SunliteScene(name: 'entree',       group: 'LED PAR public', sceneNumber: 6, color: Colors.blueAccent,   icon: Icons.login),
  SunliteScene(name: 'Faces public', group: 'LED PAR public', sceneNumber: 7, color: Colors.orange,       icon: Icons.groups),

  // ── CARRE A LED ──
  SunliteScene(name: 'emission',   group: 'Carre a led', sceneNumber: 8,  color: Colors.greenAccent, icon: Icons.fiber_manual_record),

  // ── TRADS ──
  SunliteScene(name: 'Emission',   group: 'Trads', sceneNumber: 9,  color: Colors.greenAccent,  icon: Icons.fiber_manual_record),
  SunliteScene(name: 'entree',     group: 'Trads', sceneNumber: 10, color: Colors.blueAccent,   icon: Icons.login),
  SunliteScene(name: 'base public',group: 'Trads', sceneNumber: 11, color: Colors.deepOrange,   icon: Icons.people),
];

// ──────────────────────────────────────────────────────────
// ÉCRAN SUNLIGHT
// ──────────────────────────────────────────────────────────
class SunlightScreen extends StatefulWidget {
  const SunlightScreen({super.key});

  @override
  State<SunlightScreen> createState() => _SunlightScreenState();
}

class _SunlightScreenState extends State<SunlightScreen> {
  late SunlightApi _api;
  bool _isLoading = true;
  int? _activeScene;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('sunlight_ip') ?? '192.168.1.65';
    setState(() {
      _api = SunlightApi(ipAddress: ip);
      _isLoading = false;
    });
  }

  void _playScene(SunliteScene scene) {
    setState(() => _activeScene = scene.sceneNumber);
    _api.playScene(scene.sceneNumber);
  }

  void _stopScene(SunliteScene scene) {
    setState(() {
      if (_activeScene == scene.sceneNumber) _activeScene = null;
    });
    _api.stopScene(scene.sceneNumber);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    // Grouper les scènes par groupe
    final Map<String, List<SunliteScene>> grouped = {};
    for (final s in sunliteScenes) {
      grouped.putIfAbsent(s.group, () => []).add(s);
    }

    return Container(
      color: const Color(0xFF0F1115),
      child: Column(
        children: [
          // ── Header ──
          Container(
            color: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.wb_sunny, color: Colors.amber, size: 18),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "SUNLITE SUITE 3",
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 2),
                    ),
                    Text(
                      "${_api.ipAddress}  ·  UDP Port ${_api.port}",
                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                  ],
                ),
                const Spacer(),
                // Bouton RESET global
                GestureDetector(
                  onTap: () {
                    setState(() => _activeScene = null);
                    _api.resetAll();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('☀️ RESET — Toutes les scènes arrêtées'),
                        backgroundColor: Colors.red,
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withOpacity(0.5)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.stop_circle_outlined, color: Colors.redAccent, size: 14),
                        SizedBox(width: 4),
                        Text('RESET', style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Scènes actives badge ──
          if (_activeScene != null)
            Container(
              color: const Color(0xFF1A1D24),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "SCÈNE ${_activeScene! + 1} ACTIVE — Appui long pour arrêter",
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 10, letterSpacing: 1),
                  ),
                ],
              ),
            ),

          // ── Corps scrollable ──
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ...grouped.entries.map((entry) => _buildGroup(entry.key, entry.value)),
                const SizedBox(height: 16),
                _buildMacroBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Groupe de scènes ──
  Widget _buildGroup(String title, List<SunliteScene> scenes) {
    final Map<String, String> groupTitles = {
      'LED PAR plateau': 'LED PAR PLATEAU',
      'LED PAR public': 'LED PAR PUBLIC',
      'Carre a led': 'CARRÉ À LED',
      'Trads': 'TRADS',
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF16191F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titre du groupe
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Container(width: 3, height: 14, decoration: BoxDecoration(color: Colors.amber, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
                Text(
                  groupTitles[title] ?? title.toUpperCase(),
                  style: const TextStyle(color: Colors.amber, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                ),
              ],
            ),
          ),

          // Grille de boutons
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: scenes.map((scene) => _buildSceneButton(scene)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ── Bouton d'une scène ──
  Widget _buildSceneButton(SunliteScene scene) {
    final bool isActive = _activeScene == scene.sceneNumber;

    return GestureDetector(
      onTap: () => _playScene(scene),
      onLongPress: () => _stopScene(scene),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isActive ? scene.color.withOpacity(0.25) : scene.color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive ? scene.color : scene.color.withOpacity(0.25),
            width: isActive ? 1.5 : 1,
          ),
          boxShadow: isActive
              ? [BoxShadow(color: scene.color.withOpacity(0.3), blurRadius: 10)]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Indicateur ON/OFF
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 6, height: 6,
              decoration: BoxDecoration(
                color: isActive ? scene.color : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: scene.color.withOpacity(0.5)),
              ),
            ),
            const SizedBox(width: 8),
            Icon(scene.icon, color: isActive ? scene.color : scene.color.withOpacity(0.5), size: 14),
            const SizedBox(width: 6),
            Text(
              scene.name,
              style: TextStyle(
                color: isActive ? scene.color : scene.color.withOpacity(0.7),
                fontSize: 12,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                letterSpacing: 0.5,
              ),
            ),
            if (isActive) ...[
              const SizedBox(width: 6),
              Icon(Icons.stop, color: scene.color.withOpacity(0.5), size: 10),
            ],
          ],
        ),
      ),
    );
  }

  // ── Barre de macros rapides ──
  Widget _buildMacroBar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF16191F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.bolt, color: Colors.amberAccent, size: 14),
              SizedBox(width: 6),
              Text('MACROS RAPIDES', style: TextStyle(color: Colors.amberAccent, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildMacroButton('TOUT STOP', Icons.power_off, Colors.red, () {
                setState(() => _activeScene = null);
                _api.resetAll();
              })),
              const SizedBox(width: 10),
              Expanded(child: _buildMacroButton('EMISSION FULL', Icons.fiber_manual_record, Colors.green, () {
                // Joue toutes les scènes EMISSION (scènes 2, 7, 8)
                _api.playScene(2);
                _api.playScene(7);
                _api.playScene(8);
                setState(() => _activeScene = 2);
              })),
              const SizedBox(width: 10),
              Expanded(child: _buildMacroButton('ENTREE FULL', Icons.login, Colors.blue, () {
                // Joue toutes les scènes ENTREE (scènes 1, 5, 9)
                _api.playScene(1);
                _api.playScene(5);
                _api.playScene(9);
                setState(() => _activeScene = 1);
              })),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '💡 Appui simple = Play   •   Appui long = Stop',
              style: TextStyle(color: Colors.white24, fontSize: 10),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMacroButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
