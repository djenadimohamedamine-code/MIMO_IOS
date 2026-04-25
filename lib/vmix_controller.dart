import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class VMixApi {
  final String baseUrl;

  VMixApi({this.baseUrl = "https://mimondi.tail81be1c.ts.net"});

  Future<void> sendShortcut(String guid) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/?shortcut=$guid'));
      if (response.statusCode == 200) {
        print("vMix Shortcut Sent: $guid");
      } else {
        print("vMix Shortcut Error: ${response.statusCode}");
      }
    } catch (e) {
      print("vMix Connection Error: $e");
    }
  }
}

class VMixScreen extends StatefulWidget {
  const VMixScreen({super.key});

  @override
  State<VMixScreen> createState() => _VMixScreenState();
}

class _VMixScreenState extends State<VMixScreen> {
  late VMixApi _api;
  bool _isLoading = true;

  final List<Map<String, String>> _shortcuts = [
    {'label': 'F1', 'action': 'ActiveInput 1', 'guid': 'cf4f6764-97d7-4cf1-b21d-328b1a0c3bd4'},
    {'label': 'F2', 'action': 'ActiveInput 2', 'guid': '46dc9756-d7fb-477b-ad59-d15149bf0164'},
    {'label': 'F3', 'action': 'ActiveInput 3', 'guid': 'd7748459-fc89-48b1-91a7-3f28820731f9'},
    {'label': 'F4', 'action': 'ActiveInput 4', 'guid': '6adfe52a-4a50-4650-ab97-62a67bfb2fe4'},
    {'label': 'F6', 'action': 'ActiveInput 6', 'guid': '4be5b96b-fbcd-412b-985f-0e433d6405f0'},
    {'label': 'NP1', 'action': 'Preview 1', 'guid': 'c384fd68-156e-43ff-bc99-0a872adf6c7d'},
    {'label': 'NP2', 'action': 'Preview 2', 'guid': 'e3587b0b-b07e-4836-a7c5-14a2fed15bac'},
    {'label': 'NP3', 'action': 'Preview 3', 'guid': '6ad97253-f859-4782-9612-f6587b7a3f92'},
    {'label': 'NP4', 'action': 'Preview 4', 'guid': '6690d07d-0dbe-4f69-9065-a0acc1554379'},
    {'label': 'NP5', 'action': 'Preview 5', 'guid': 'f44c6b27-5507-4259-9708-0ecd4276931c'},
    {'label': 'NP6', 'action': 'Preview 6', 'guid': '46a1a740-871d-4a4f-a178-26fc4cb55ff5'},
    {'label': 'NP0', 'action': 'Preview 1', 'guid': '847a097c-368e-4f87-95bf-b1641f0f9c4b'},
    {'label': 'ENTER', 'action': 'FADE', 'guid': 'ede880a8-aa4b-46e3-9ae1-a9e5d6739473'},
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('vmix_url') ?? 'https://mimondi.tail81be1c.ts.net';
    setState(() {
      _api = VMixApi(baseUrl: url);
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Container(
      color: const Color(0xFF15181E),
      child: Column(
        children: [
          // Header
          Container(
            color: const Color(0xFF111318),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.circle, size: 10, color: Colors.blueAccent),
                const SizedBox(width: 8),
                Text(
                  'vMix Remote — ${_api.baseUrl}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1.2),
                ),
                const Spacer(),
                const Text(
                  'HTTP API',
                  style: TextStyle(color: Colors.blueAccent, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                ),
              ],
            ),
          ),
          
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 1.3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _shortcuts.length,
              itemBuilder: (context, index) {
                final s = _shortcuts[index];
                final bool isProgram = s['action']!.contains('Active');
                final bool isFade = s['label'] == 'ENTER';
                
                return _buildShortcutButton(
                  s['label']!,
                  s['action']!,
                  s['guid']!,
                  isProgram ? Colors.redAccent : (isFade ? Colors.orangeAccent : Colors.greenAccent),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutButton(String label, String action, String guid, Color color) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _api.sendShortcut(guid),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.4), width: 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 4),
              Text(
                action,
                style: TextStyle(color: color.withOpacity(0.7), fontSize: 10),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
