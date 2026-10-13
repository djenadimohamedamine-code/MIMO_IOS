import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'omt_protocol.dart';
import 'omt_service.dart';

/// Full OMT screen with send, discovery and receive capabilities.
/// Integrated as an independent item in MIMO_NDI's side drawer without
/// modifying any existing NDI indices.
class OMTScreen extends StatefulWidget {
  const OMTScreen({super.key});

  @override
  State<OMTScreen> createState() => _OMTScreenState();
}

class _OMTScreenState extends State<OMTScreen>
    with SingleTickerProviderStateMixin {
  final OMTService _omtService = OMTService();

  late TabController _tabController;
  final TextEditingController _nameController =
      TextEditingController(text: 'MIMO_NDI Camera');

  // Send tab state
  OMTConnectionState _connectionState = OMTConnectionState.idle;
  OMTResolution _selectedResolution = OMTResolution.hd1080p;
  OMTFrameRate _selectedFrameRate = OMTFrameRate.fps30;
  bool _useFrontCamera = false;
  bool _isTestPattern = false;
  Map<String, dynamic> _stats = {};

  // Discovery tab state
  List<OMTSource> _sources = [];
  bool _isDiscovering = false;
  Timer? _discoveryTimer;
  OMTSource? _selectedSource;

  // Subscriptions
  StreamSubscription<OMTConnectionState>? _stateSub;
  StreamSubscription<List<OMTSource>>? _sourcesSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<Map<String, dynamic>>? _statsSub;
  Timer? _statsTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initService();
  }

  Future<void> _initService() async {
    await _omtService.initialize();

    _stateSub = _omtService.stateStream.listen((state) {
      if (mounted) setState(() => _connectionState = state);
    });

    _sourcesSub = _omtService.sourcesStream.listen((sources) {
      if (mounted) setState(() => _sources = sources);
    });

    _errorSub = _omtService.errorStream.listen((error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('OMT: $error'),
            backgroundColor: Colors.red.shade900,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    });

    _statsSub = _omtService.statsStream.listen((stats) {
      if (mounted) setState(() => _stats = stats);
    });

    // Start discovery automatically
    _startDiscovery();

    // Start native camera preview for framing
    _omtService.startCameraPreview(
      resolution: _selectedResolution,
      frameRate: _selectedFrameRate,
      useFrontCamera: _useFrontCamera,
    );

    // Poll stats every 2 seconds when transmitting or receiving
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_connectionState == OMTConnectionState.transmitting ||
          _connectionState == OMTConnectionState.receiving) {
        final s = await _omtService.getStats();
        if (mounted) setState(() => _stats = s);
      }
    });
  }

  Future<void> _startDiscovery() async {
    if (_isDiscovering) return;
    setState(() => _isDiscovering = true);
    await _omtService.startDiscovery();

    // Refresh sources every 5s
    _discoveryTimer?.cancel();
    _discoveryTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      final sources = await _omtService.getSources();
      if (mounted) setState(() => _sources = sources);
    });
  }

  Future<void> _startSending() async {
    setState(() => _connectionState = OMTConnectionState.connecting);
    final sourceName = _nameController.text.trim().isEmpty
        ? 'MIMO_NDI Camera'
        : _nameController.text.trim();
    final success = await _omtService.startSending(
      sourceName: sourceName,
      resolution: _selectedResolution,
      frameRate: _selectedFrameRate,
      useFrontCamera: _useFrontCamera,
    );
    if (!success && mounted) {
      setState(() => _connectionState = OMTConnectionState.error);
    }
  }

  Future<void> _stopSending() async {
    setState(() => _connectionState = OMTConnectionState.disconnecting);
    await _omtService.stopSending();
    if (mounted) setState(() => _connectionState = OMTConnectionState.idle);
  }

  Future<void> _toggleTestPattern(bool val) async {
    setState(() => _isTestPattern = val);
    await _omtService.setTestPattern(val);
  }

  Future<void> _onCameraSwitch(bool val) async {
    setState(() => _useFrontCamera = val);
    await _omtService.switchCamera(useFrontCamera: val);
  }

  Future<void> _connectToSource(OMTSource source) async {
    setState(() {
      _selectedSource = source;
      _connectionState = OMTConnectionState.connecting;
    });
    final ok = await _omtService.connectToSource(source);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Impossible de se connecter à ${source.name}'),
          backgroundColor: Colors.red.shade900,
        ),
      );
      setState(() {
        _selectedSource = null;
        _connectionState = OMTConnectionState.idle;
      });
    }
  }

  Future<void> _disconnectReceiver() async {
    await _omtService.disconnect();
    if (mounted) {
      setState(() {
        _selectedSource = null;
        _connectionState = OMTConnectionState.idle;
      });
    }
  }

  @override
  void dispose() {
    _omtService.stopCameraPreview();
    if (_selectedSource != null) {
      _omtService.disconnect();
    }
    _tabController.dispose();
    _nameController.dispose();
    _stateSub?.cancel();
    _sourcesSub?.cancel();
    _errorSub?.cancel();
    _statsSub?.cancel();
    _discoveryTimer?.cancel();
    _statsTimer?.cancel();
    super.dispose();
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Status bar
        _buildStatusBar(),
        // Tab bar
        Container(
          color: Colors.black26,
          child: TabBar(
            controller: _tabController,
            indicatorColor: Colors.greenAccent,
            labelColor: Colors.greenAccent,
            unselectedLabelColor: Colors.white54,
            tabs: const [
              Tab(icon: Icon(Icons.videocam), text: 'Envoyer'),
              Tab(icon: Icon(Icons.search), text: 'Découverte'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildSendTab(),
              _buildDiscoveryTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    final Color stateColor;
    final String stateLabel;
    final IconData stateIcon;

    switch (_connectionState) {
      case OMTConnectionState.idle:
        stateColor = Colors.white38;
        stateLabel = 'Inactif';
        stateIcon = Icons.stop_circle_outlined;
        break;
      case OMTConnectionState.discovering:
        stateColor = Colors.blueAccent;
        stateLabel = 'Découverte réseau...';
        stateIcon = Icons.radar;
        break;
      case OMTConnectionState.listening:
        stateColor = Colors.amber;
        stateLabel = 'En écoute — En attente de vMix 29 (Port 6400)';
        stateIcon = Icons.wifi_tethering;
        break;
      case OMTConnectionState.connected:
        stateColor = Colors.lightBlueAccent;
        stateLabel = 'vMix 29 connecté — En attente d\'abonnement';
        stateIcon = Icons.link;
        break;
      case OMTConnectionState.connecting:
        stateColor = Colors.orangeAccent;
        stateLabel = 'Initialisation...';
        stateIcon = Icons.sync;
        break;
      case OMTConnectionState.transmitting:
        stateColor = Colors.greenAccent;
        stateLabel = 'En direct — Diffusion OMT active vers vMix 29';
        stateIcon = Icons.fiber_manual_record;
        break;
      case OMTConnectionState.receiving:
        stateColor = Colors.cyanAccent;
        stateLabel = 'Réception OMT ACTIVE';
        stateIcon = Icons.download_rounded;
        break;
      case OMTConnectionState.disconnecting:
        stateColor = Colors.orange;
        stateLabel = 'Arrêt en cours...';
        stateIcon = Icons.sync_disabled;
        break;
      case OMTConnectionState.error:
        stateColor = Colors.redAccent;
        stateLabel = 'ERREUR — vérifiez le réseau';
        stateIcon = Icons.error_outline;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: stateColor.withOpacity(0.12),
        border: Border(
          bottom: BorderSide(color: stateColor.withOpacity(0.3)),
        ),
      ),
      child: Row(
        children: [
          if (_connectionState == OMTConnectionState.connecting ||
              _connectionState == OMTConnectionState.disconnecting)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: stateColor,
              ),
            )
          else
            Icon(stateIcon, color: stateColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              stateLabel,
              style: TextStyle(
                color: stateColor,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
          ),
          // Live stats badge
          if (_connectionState == OMTConnectionState.transmitting &&
              _stats.isNotEmpty) ...[
            _buildStatsBadge(),
          ],
        ],
      ),
    );
  }

  Widget _buildStatsBadge() {
    final fps = _stats['fps']?.toString() ?? '—';
    final bitrate = _stats['bitrateKbps'];
    final bitrateStr = bitrate != null
        ? '${(bitrate as num).toInt()} Kbps'
        : '—';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.greenAccent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
      ),
      child: Text(
        '$fps fps  $bitrateStr',
        style: const TextStyle(
          color: Colors.greenAccent,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Future<void> _copyDiagnosticLogs() async {
    final logs = await _omtService.getDiagnosticLogs();
    final stats = await _omtService.getStats();
    final report = 'MIMO OMT Diagnostic\nState: ${_connectionState.name}\nStats: $stats\n\nTCP events:\n${logs.isEmpty ? 'No events captured yet' : logs}';
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostic OMT copié. Collez-le dans ChatGPT.')),
      );
    }
  }

  // ─── SEND TAB ─────────────────────────────────────────────────────────────

  Widget _buildSendTab() {
    final bool isSending = _connectionState == OMTConnectionState.transmitting ||
        _connectionState == OMTConnectionState.listening ||
        _connectionState == OMTConnectionState.connected;
    final bool isBusy = _connectionState == OMTConnectionState.connecting ||
        _connectionState == OMTConnectionState.disconnecting;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
              '📡 Open Media Transport', 'Transmission vers vMix 29'),

          const SizedBox(height: 16),

          // Camera preview box
          _buildCameraPreview(),

          const SizedBox(height: 20),

          // Source name
          _buildFormField(
            label: 'Nom de la source',
            child: TextField(
              controller: _nameController,
              enabled: !isSending,
              decoration: _inputDecoration(
                  hint: 'MIMO_NDI Camera', icon: Icons.label_outline),
              style: const TextStyle(color: Colors.white),
            ),
          ),

          const SizedBox(height: 16),

          // Resolution
          _buildFormField(
            label: 'Résolution',
            child: _buildDropdown<OMTResolution>(
              value: _selectedResolution,
              items: OMTResolution.values,
              label: (r) => r.label,
              enabled: !isSending,
              onChanged: (v) => setState(() => _selectedResolution = v!),
            ),
          ),

          const SizedBox(height: 16),

          // Frame rate
          _buildFormField(
            label: 'Fréquence d\'images',
            child: _buildDropdown<OMTFrameRate>(
              value: _selectedFrameRate,
              items: OMTFrameRate.values,
              label: (r) => r.label,
              enabled: !isSending,
              onChanged: (v) => setState(() => _selectedFrameRate = v!),
            ),
          ),

          const SizedBox(height: 16),

          // Camera toggle
          _buildFormField(
            label: 'Caméra',
            child: Row(
              children: [
                const Text('Arrière', style: TextStyle(color: Colors.white70)),
                Switch(
                  value: _useFrontCamera,
                  activeColor: Colors.greenAccent,
                  onChanged: (v) => _onCameraSwitch(v),
                ),
                const Text('Avant', style: TextStyle(color: Colors.white70)),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Diagnostic Test Pattern (SMPTE Color Bars)
          _buildFormField(
            label: 'Mire de diagnostic (vMix 29)',
            child: Row(
              children: [
                const Text('Caméra', style: TextStyle(color: Colors.white70)),
                Switch(
                  value: _isTestPattern,
                  activeColor: Colors.amberAccent,
                  onChanged: (v) => _toggleTestPattern(v),
                ),
                const Text('Mire SMPTE', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // Start/Stop button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: isBusy
                  ? null
                  : (isSending ? _stopSending : _startSending),
              icon: isBusy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Icon(isSending ? Icons.stop : Icons.play_arrow, size: 28),
              label: Text(
                isBusy
                    ? 'Veuillez patienter...'
                    : (isSending
                        ? 'Arrêter la transmission OMT'
                        : 'Démarrer la transmission OMT'),
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isSending ? Colors.red.shade800 : Colors.green.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Copy on-device TCP events without a Mac or USB cable.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _copyDiagnosticLogs,
              icon: const Icon(Icons.copy),
              label: const Text('Copier les logs OMT'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.amberAccent),
            ),
          ),

          // Info box
          _buildInfoBox(),

          // Stats when active
          if ((_connectionState == OMTConnectionState.transmitting ||
               _connectionState == OMTConnectionState.listening ||
               _connectionState == OMTConnectionState.connected) &&
              _stats.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildStatsPanel(),
          ],
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final isLive = _connectionState == OMTConnectionState.transmitting;
    final isListening = _connectionState == OMTConnectionState.listening ||
        _connectionState == OMTConnectionState.connected;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: Colors.black,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Native iOS Preview Layer
              Theme.of(context).platform == TargetPlatform.iOS
                  ? const UiKitView(
                      viewType: 'com.antigravity/omt_camera_preview',
                    )
                  : const Center(
                      child: Text(
                        'Aperçu Caméra OMT (iOS)',
                        style: TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    ),

              // Overlay if diagnostic test pattern is active
              if (_isTestPattern)
                Container(
                  color: Colors.black.withOpacity(0.85),
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.amber.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.amberAccent),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.tune, color: Colors.amberAccent, size: 16),
                              SizedBox(width: 6),
                              Text(
                                'MIRE SMPTE 75% ACTIVE',
                                style: TextStyle(
                                  color: Colors.amberAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Les barres de couleur SMPTE animées sont envoyées à vMix 29',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),

              // Top overlays: status badge and flip button
              Positioned(
                top: 10,
                left: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isLive
                          ? Colors.redAccent
                          : (isListening ? Colors.amberAccent : Colors.white24),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isLive
                              ? Colors.redAccent
                              : (isListening
                                  ? Colors.amberAccent
                                  : Colors.greenAccent),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isLive
                            ? 'EN DIRECT'
                            : (isListening ? 'EN ATTENTE VMIX' : 'APERÇU CADRAGE'),
                        style: TextStyle(
                          color: isLive
                              ? Colors.redAccent
                              : (isListening
                                  ? Colors.amberAccent
                                  : Colors.white),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${_selectedResolution.width}x${_selectedResolution.height}',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Flip camera button overlay in top-right
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: Colors.black.withOpacity(0.55),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _onCameraSwitch(!_useFrontCamera),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        _useFrontCamera
                            ? Icons.camera_front
                            : Icons.camera_rear,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoBox() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blueAccent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Row(
            children: [
              Icon(Icons.info_outline, color: Colors.blueAccent, size: 16),
              SizedBox(width: 8),
              Text('Comment recevoir dans vMix 29 ?',
                  style: TextStyle(
                      color: Colors.blueAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ],
          ),
          SizedBox(height: 8),
          Text(
            '1. Connectez l\'iPhone et vMix au même réseau local Wi-Fi\n'
            '2. Appuyez sur "Démarrer la transmission OMT"\n'
            '3. Dans vMix → Add Input → OMT\n'
            '4. Sélectionnez votre iPhone (annoncé automatiquement via Bonjour)\n'
            '5. La source communique via TCP sur le port 6400 en codec VMX1 natif',
            style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsPanel() {
    final isTest = _stats['testPatternActive'] == true || _isTestPattern;
    final isVmxActive = _stats['isVMX1'] == true;
    final w = _stats['actualWidth'] ?? 1920;
    final h = _stats['actualHeight'] ?? 1080;
    final encErr = _stats['encoderError'] ?? 'OK';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.greenAccent.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('📊 Diagnostic & Télémétrie OMT',
                  style: TextStyle(
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: isTest ? Colors.amber.withOpacity(0.2) : Colors.green.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isTest ? Colors.amberAccent : Colors.greenAccent),
                ),
                child: Text(
                  isTest ? 'MIRE SMPTE' : 'CAMÉRA',
                  style: TextStyle(
                      color: isTest ? Colors.amberAccent : Colors.greenAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_stats['localIP'] != null)
            _statsRow('IP locale & Port', '${_stats['localIP']}:${_stats['port'] ?? 6400}'),
          _statsRow('Résolution réelle', '${w}x$h'),
          _statsRow('Format / Codec', '${_stats['codec'] ?? 'VMX1 (vMix 29 Native)'}'),
          _statsRow('Moteur VMX1 (NEON)', isVmxActive ? 'ACTIF (Compressé)' : 'INACTIF (Fallback)'),
          if (encErr != 'OK')
            _statsRow('Diagnostic Erreur', encErr),
          _statsRow('FPS réel capturé', '${_stats['fps'] ?? '—'}'),
          _statsRow('Débit réseau réel', '${_stats['bitrateKbps'] ?? '0'} Kbps'),
          _statsRow('Trames encodées', '${_stats['framesEncoded'] ?? '0'}'),
          _statsRow('Trames transmises', '${_stats['framesSent'] ?? '0'}'),
          _statsRow('Trames abandonnées (drops)', '${_stats['framesDropped'] ?? '0'}'),
          _statsRow('Récepteurs connectés', '${_stats['activeConnections'] ?? '0'}'),
          _statsRow('Abonnés vidéo vMix', '${_stats['subscribedConnections'] ?? '0'}'),
        ],
      ),
    );
  }

  Widget _statsRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ─── DISCOVERY TAB ────────────────────────────────────────────────────────

  Widget _buildDiscoveryTab() {
    if (_selectedSource != null) {
      return _buildReceiverPlayer();
    }

    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_sources.length} source(s) OMT détectée(s)',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5),
                ),
              ),
              if (_isDiscovering)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.greenAccent),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.blueAccent),
                  tooltip: 'Actualiser',
                  onPressed: _startDiscovery,
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white10),

        Expanded(
          child: _sources.isEmpty
              ? _buildEmptyDiscovery()
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _sources.length,
                  itemBuilder: (ctx, i) => _buildSourceCard(_sources[i]),
                ),
        ),

        // Note about vMix
        Container(
          padding: const EdgeInsets.all(12),
          color: Colors.black26,
          child: const Row(
            children: [
              Icon(Icons.lightbulb_outline, color: Colors.amber, size: 14),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'La découverte utilise DNS-SD Bonjour (_omt._tcp). '
                  'vMix 29 apparaît ici automatiquement s\'il est actif sur le réseau local.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReceiverPlayer() {
    final source = _selectedSource!;
    final isReceiving = _connectionState == OMTConnectionState.receiving;
    final w = _stats['actualWidth'] ?? 0;
    final h = _stats['actualHeight'] ?? 0;
    final resStr = (w > 0 && h > 0) ? '${w}x$h' : 'Détection...';
    final codecStr = _stats['codec']?.toString() ?? 'VMX1';
    final fpsStr = _stats['fps']?.toString() ?? '0';
    final bitrate = _stats['bitrateKbps'];
    final bitrateStr = bitrate != null ? '$bitrate Kbps' : '0 Kbps';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with back button & status
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: _disconnectReceiver,
                tooltip: 'Retour à la liste',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${source.host}:${source.port}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isReceiving
                      ? Colors.cyanAccent.withOpacity(0.2)
                      : Colors.orangeAccent.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isReceiving ? Colors.cyanAccent : Colors.orangeAccent,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isReceiving ? Colors.cyanAccent : Colors.orangeAccent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isReceiving ? 'EN DIRECT' : 'CONNEXION...',
                      style: TextStyle(
                        color: isReceiving ? Colors.cyanAccent : Colors.orangeAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Video player container (16:9)
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              color: Colors.black,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Theme.of(context).platform == TargetPlatform.iOS
                        ? const UiKitView(
                            viewType: 'com.antigravity/omt_receiver_view',
                          )
                        : const Center(
                            child: Text(
                              'Récepteur Vidéo OMT (iOS)',
                              style: TextStyle(color: Colors.white38),
                            ),
                          ),

                    if (!isReceiving)
                      Container(
                        color: Colors.black.withOpacity(0.75),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(color: Colors.cyanAccent),
                              const SizedBox(height: 14),
                              Text(
                                'Connexion à ${source.name}...\nNégociation OMTSubscribe',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // Top overlay: resolution & codec badge
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Text(
                          '$resStr • $codecStr',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),

                    // Live FPS & Bitrate overlay
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.cyanAccent.withOpacity(0.4)),
                        ),
                        child: Text(
                          '$fpsStr fps  $bitrateStr',
                          style: const TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 11,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Stop reception button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _disconnectReceiver,
              icon: const Icon(Icons.stop),
              label: const Text(
                'Arrêter la réception OMT',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade800,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Receiver telemetry details
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.cyanAccent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.analytics_outlined, color: Colors.cyanAccent, size: 16),
                    SizedBox(width: 8),
                    Text(
                      'Télémétrie du récepteur OMT',
                      style: TextStyle(
                        color: Colors.cyanAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _statsRow('Source OMT', source.name),
                _statsRow('Adresse réseau', '${source.host}:${source.port}'),
                _statsRow('Codec vidéo', codecStr),
                _statsRow('Résolution décodée', resStr),
                _statsRow('Cadence (FPS)', '$fpsStr fps'),
                _statsRow('Débit binaire reçu', bitrateStr),
                _statsRow('Trames reçues', '${_stats['framesReceived'] ?? 0}'),
                _statsRow('Trames décodées', '${_stats['framesDecoded'] ?? 0}'),
                _statsRow('Trames perdues (drops)', '${_stats['framesDropped'] ?? 0}'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyDiscovery() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _isDiscovering ? Icons.radar : Icons.wifi_off,
            size: 64,
            color: Colors.white12,
          ),
          const SizedBox(height: 16),
          Text(
            _isDiscovering
                ? 'Recherche de sources OMT...'
                : 'Aucune source OMT détectée',
            style: const TextStyle(color: Colors.white38, fontSize: 14),
          ),
          const SizedBox(height: 8),
          const Text(
            'Assurez-vous que vMix 29 est actif\nsur le même réseau Wi-Fi',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white24, fontSize: 12),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _startDiscovery,
            icon: const Icon(Icons.search),
            label: const Text('Rechercher'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.greenAccent),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceCard(OMTSource source) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white.withOpacity(0.06),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withOpacity(0.1)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.cyanAccent.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.stream, color: Colors.cyanAccent, size: 22),
        ),
        title: Text(
          source.name,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: Text(
          '${source.host}:${source.port}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        trailing: ElevatedButton.icon(
          onPressed: () => _connectToSource(source),
          icon: const Icon(Icons.play_arrow, size: 16),
          label: const Text('Recevoir', style: TextStyle(fontSize: 12)),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.cyan.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        onTap: () => _showSourceOptions(source),
      ),
    );
  }

  void _showSourceOptions(OMTSource source) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2024),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(source.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            Text('${source.host}:${source.port}',
                style: const TextStyle(color: Colors.white54)),
            const SizedBox(height: 20),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.cyanAccent.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow, color: Colors.cyanAccent),
              ),
              title: const Text('Recevoir et afficher le flux en direct',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: const Text(
                  'Connexion TCP directe, décodage VMX1 temps réel',
                  style: TextStyle(color: Colors.white54, fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                _connectToSource(source);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────────

  Widget _buildSectionHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(subtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 13)),
      ],
    );
  }

  Widget _buildFormField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
            style: const TextStyle(
                color: Colors.white38,
                fontSize: 11,
                letterSpacing: 1,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  InputDecoration _inputDecoration({String? hint, IconData? icon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white24),
      prefixIcon: icon != null ? Icon(icon, color: Colors.white38) : null,
      filled: true,
      fillColor: Colors.white.withOpacity(0.06),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.greenAccent),
      ),
    );
  }

  Widget _buildDropdown<T>({
    required T value,
    required List<T> items,
    required String Function(T) label,
    required ValueChanged<T?> onChanged,
    bool enabled = true,
  }) {
    return DropdownButtonFormField<T>(
      value: value,
      dropdownColor: const Color(0xFF2A2D32),
      decoration: _inputDecoration(),
      style: const TextStyle(color: Colors.white),
      onChanged: enabled ? onChanged : null,
      items: items
          .map((item) => DropdownMenuItem<T>(
                value: item,
                child: Text(label(item)),
              ))
          .toList(),
    );
  }
}
