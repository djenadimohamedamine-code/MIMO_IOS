import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Midas M32 (et Behringer X32) utiliser le protocole OSC (Open Sound Control)
/// via UDP sur le port 10023 (ce n'est pas du HTTP REST comme le TriCaster).
class MidasM32Api {
  final String ipAddress;
  final int port;

  MidasM32Api({this.ipAddress = "192.168.1.200", this.port = 10023});


  /// Envoie un message brut OSC en UDP
  Future<void> _sendOscMessage(String address, {double? floatValue, int? intValue, String? stringValue}) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      List<int> bytes = [];

      // 1. Ajouter l'adresse OSC (ex: /ch/01/mix/fader)
      bytes.addAll(_encodeOscString(address));

      // 2. Ajouter les Type Tags (ex: ,f pour Float, ,i pour Int, ,s pour String)
      String typeTags = ",";
      if (floatValue != null) typeTags += "f";
      if (intValue != null) typeTags += "i";
      if (stringValue != null) typeTags += "s";
      bytes.addAll(_encodeOscString(typeTags));

      // 3. Ajouter les arguments
      if (floatValue != null) {
        ByteData bd = ByteData(4);
        bd.setFloat32(0, floatValue, Endian.big);
        bytes.addAll(bd.buffer.asUint8List());
      }
      if (intValue != null) {
        ByteData bd = ByteData(4);
        bd.setInt32(0, intValue, Endian.big);
        bytes.addAll(bd.buffer.asUint8List());
      }
      if (stringValue != null) {
        bytes.addAll(_encodeOscString(stringValue));
      }

      // Envoi du paquet UDP à la Midas
      socket.send(bytes, InternetAddress(ipAddress), port);
      print("OSC Envoyé: $address -> Midas M32 ($ipAddress:$port)");
    } catch (e) {
      print("Erreur d'envoi OSC Midas: $e");
    } finally {
      socket?.close();
    }
  }

  /// Encode une String au format OSC (Null-terminated et multiple de 4 octets)
  List<int> _encodeOscString(String s) {
    List<int> sBytes = s.codeUnits.toList();
    sBytes.add(0); // Null byte de fin
    while (sBytes.length % 4 != 0) {
      sBytes.add(0); // Remplir de zéros jusqu'au multiple de 4
    }
    return sBytes;
  }


  // ==========================================
  // EXEMPLES DE COMMANDES MIDAS M32
  // ==========================================

  /// Mute ou Unmute une piste (chIndex: de 1 à 32)
  /// val = true (ON / Unmute), false (OFF / Mute)
  Future<void> setChannelOn(int chIndex, bool isOn) async {
    String ch = chIndex.toString().padLeft(2, '0');
    // Dans la M32, 'on' à 1.0 (float) veut dire dé-muté (actif), 0.0 est muté.
    await _sendOscMessage('/ch/$ch/mix/on', floatValue: isOn ? 1.0 : 0.0);
  }

  /// Régler le Fader d'une piste (chIndex: 1 à 32)
  /// level: de 0.0 (silence total) à 1.0 (+10 dB max)
  Future<void> setChannelFader(int chIndex, double level) async {
    String ch = chIndex.toString().padLeft(2, '0');
    await _sendOscMessage('/ch/$ch/mix/fader', floatValue: level);
  }

  /// Régler le Volume Master LR (Main Stereo)
  /// level: de 0.0 à 1.0
  Future<void> setMasterVolume(double level) async {
    await _sendOscMessage('/main/st/mix/fader', floatValue: level);
  }

  /// Mute ou Unmute le Master LR
  Future<void> setMasterOn(bool isOn) async {
    await _sendOscMessage('/main/st/mix/on', floatValue: isOn ? 1.0 : 0.0);
  }

  // ==========================================
  // ROUTING & AUXILIAIRES (OMNI OUTS)
  // ==========================================

  /// Assigner un MixBus (Aux) à une sortie physique (Omni / Analog Out)
  /// outIndex: de 1 à 16 (Numéro de la sortie XLR physique derrière la console)
  /// mixBus: de 1 à 16 (Numéro du MixBus / Aux)
  Future<void> assignMixBusToOutput(int outIndex, int mixBus) async {
    String outPad = outIndex.toString().padLeft(2, '0');
    
    // Dans la M32/X32, l'entier source correspond à une liste d'affectation :
    // 0 = Off
    // 1 à 32 = Input 1 à 32
    // 33 à 40 = Aux In 1 à 8
    // 41 à 48 = FX Returns
    // 49 à 64 = MixBus 1 à 16  <- C'EST CEUX-LÀ QUI NOUS INTÉRESSENT !
    int sourceValue = 48 + mixBus; // mixBus 1 = 49, mixBus 16 = 64
    
    await _sendOscMessage('/outputs/main/$outPad/src', intValue: sourceValue);
  }

  /// Envoyer le son d'une piste vers un Auxiliaire (MixBus)
  /// chIndex: de 1 à 32 (Piste d'entrée)
  /// mixBus: de 1 à 16 (L'auxiliaire de destination)
  /// level: de 0.0 à 1.0 (-oo à +10dB)
  Future<void> setChannelSendToMixBus(int chIndex, int mixBus, double level) async {
    String ch = chIndex.toString().padLeft(2, '0');
    String bus = mixBus.toString().padLeft(2, '0');
    
    // /ch/01/mix/01/level
    await _sendOscMessage('/ch/$ch/mix/$bus/level', floatValue: level);
  }

  /// Mute ou Unmute l'envoi d'une piste vers un Auxiliaire (MixBus)
  Future<void> setChannelSendToMixBusOn(int chIndex, int mixBus, bool isOn) async {
    String ch = chIndex.toString().padLeft(2, '0');
    String bus = mixBus.toString().padLeft(2, '0');
    
    await _sendOscMessage('/ch/$ch/mix/$bus/on', floatValue: isOn ? 1.0 : 0.0);
  }

  // ==========================================
  // PREAMP GAIN & EQUALISATION (EQ)
  // ==========================================

  /// Régler le Gain (Préampli / Trim numérique) d'une piste
  /// chIndex: de 1 à 32
  /// gainLevel: de 0.0 à 1.0 (correspond généralement de -18dB à +60dB sur la console)
  Future<void> setChannelGain(int chIndex, double gainLevel) async {
    String ch = chIndex.toString().padLeft(2, '0');
    await _sendOscMessage('/ch/$ch/preamp/trim', floatValue: gainLevel);
  }

  /// Activer ou désactiver l'Égaliseur (EQ) complet d'une piste
  Future<void> setChannelEqOn(int chIndex, bool isOn) async {
    String ch = chIndex.toString().padLeft(2, '0');
    await _sendOscMessage('/ch/$ch/eq/on', floatValue: isOn ? 1.0 : 0.0);
  }

  /// Régler un paramètre spécifique d'une bande d'EQ pour une piste
  /// chIndex: 1 à 32
  /// bandIndex: 1 (Low), 2 (Low-Mid), 3 (Hi-Mid), 4 (High)
  /// paramType: 'f' (Fréquence), 'g' (Gain de l'EQ), 'q' (Largeur de bande / Q)
  /// value: 0.0 à 1.0
  Future<void> setChannelEqBand(int chIndex, int bandIndex, String paramType, double value) async {
    String ch = chIndex.toString().padLeft(2, '0');
    // Le paramètre doit être 'f', 'g', ou 'q'. ex: /ch/01/eq/1/g
    await _sendOscMessage('/ch/$ch/eq/$bandIndex/$paramType', floatValue: value);
  }

  /// Exemple de raccourci : Régler directement le gain de l'EQ (boost/cut) d'une bande
  /// gainValue: 0.0 (-15dB) -> 0.5 (0dB) -> 1.0 (+15dB)
  Future<void> setChannelEqBandGain(int chIndex, int bandIndex, double gainValue) async {
    await setChannelEqBand(chIndex, bandIndex, 'g', gainValue);
  }
}


// ─────────────────────────────────────────────────────────────
// ÉCRAN DE CONTRÔLE MIDAS M32
// ─────────────────────────────────────────────────────────────

class MidasM32Screen extends StatefulWidget {
  const MidasM32Screen({super.key});

  @override
  State<MidasM32Screen> createState() => _MidasM32ScreenState();
}

class _MidasM32ScreenState extends State<MidasM32Screen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late MidasM32Api _api;

  // État local : faders (0.0–1.0) et mute pour 32 canaux + master
  final List<double> _faders = List.filled(33, 0.75); // index 0 = master, 1-32 = canaux
  final List<bool> _muted = List.filled(33, false);   // index 0 = master, 1-32 = canaux

  // Noms personnalisés des canaux
  final List<String> _names = [
    'MASTER',
    'Micro 1', 'Micro 2', 'Micro 3', 'Micro 4',
    'Micro 5', 'Micro 6', 'Micro 7', 'Micro 8',
    'DI L',    'DI R',    'CH 11',   'CH 12',
    'CH 13',   'CH 14',   'CH 15',   'CH 16',
    'CH 17',   'CH 18',   'CH 19',   'CH 20',
    'CH 21',   'CH 22',   'CH 23',   'CH 24',
    'CH 25',   'CH 26',   'CH 27',   'CH 28',
    'CH 29',   'CH 30',   'CH 31',   'CH 32',
  ];

  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _api = MidasM32Api(); // IP par défaut, on la remplace via prefs
    _loadApiSettings();
  }

  Future<void> _loadApiSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('midas_ip') ?? '192.168.1.200';
    if (mounted) {
      setState(() {
        _api = MidasM32Api(ipAddress: ip);
        _isConnected = true; // UDP = pas de connexion persistante
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── Convertit la valeur fader (0.0–1.0) en label dB ──
  String _faderToDb(double val) {
    if (val <= 0.0) return '-∞';
    if (val >= 1.0) return '+10';
    // Approximation linéaire : 0.75 ≈ 0 dB
    final db = (val - 0.75) * 80;
    return '${db.toStringAsFixed(0)} dB';
  }

  void _onFaderChanged(int index, double val) {
    setState(() => _faders[index] = val);
    if (index == 0) {
      _api.setMasterVolume(val);
    } else {
      _api.setChannelFader(index, val);
    }
  }

  void _onMuteToggle(int index) {
    final newMute = !_muted[index];
    setState(() => _muted[index] = newMute);
    if (index == 0) {
      _api.setMasterOn(!newMute); // On = actif = non muté
    } else {
      _api.setChannelOn(index, !newMute);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Header status IP ──
        Container(
          color: const Color(0xFF111318),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.circle,
                size: 10,
                color: _isConnected ? Colors.orangeAccent : Colors.red,
              ),
              const SizedBox(width: 8),
              Text(
                _isConnected
                    ? 'MIDAS M32 — ${_api.ipAddress}:${_api.port}'
                    : 'Chargement...',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              const Text(
                'OSC/UDP',
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
        ),

        // ── TabBar ──
        Container(
          color: const Color(0xFF1A1D24),
          child: TabBar(
            controller: _tabController,
            indicatorColor: Colors.orangeAccent,
            labelColor: Colors.orangeAccent,
            unselectedLabelColor: Colors.white38,
            labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2),
            tabs: const [
              Tab(text: 'CH 01 – 16'),
              Tab(text: 'CH 17 – 32'),
              Tab(text: 'MASTER'),
            ],
          ),
        ),

        // ── Corps ──
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildChannelGrid(1, 16),
              _buildChannelGrid(17, 32),
              _buildMasterPanel(),
            ],
          ),
        ),
      ],
    );
  }

  // ── Grille de canaux ──
  Widget _buildChannelGrid(int from, int to) {
    return Container(
      color: const Color(0xFF15181E),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(to - from + 1, (i) {
            final chIndex = from + i;
            return _buildChannelStrip(chIndex);
          }),
        ),
      ),
    );
  }

  // ── Strip d'un canal ──
  Widget _buildChannelStrip(int index) {
    final isMuted = _muted[index];
    final faderVal = _faders[index];
    final name = _names[index];
    final stripColor = isMuted ? Colors.red.shade900 : const Color(0xFF1E2330);

    return Container(
      width: 68,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: stripColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isMuted ? Colors.red.withOpacity(0.6) : Colors.white10,
          width: 1,
        ),
        boxShadow: isMuted
            ? [BoxShadow(color: Colors.red.withOpacity(0.2), blurRadius: 8)]
            : null,
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),

          // ── Numéro du canal ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black38,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              index.toString().padLeft(2, '0'),
              style: TextStyle(
                color: isMuted ? Colors.red.shade300 : Colors.orangeAccent,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFamily: 'Courier',
              ),
            ),
          ),

          const SizedBox(height: 6),

          // ── Valeur dB ──
          Text(
            _faderToDb(faderVal),
            style: TextStyle(
              color: isMuted ? Colors.red.shade200 : Colors.white70,
              fontSize: 9,
              fontFamily: 'Courier',
            ),
          ),

          const SizedBox(height: 8),

          // ── Fader vertical ──
          SizedBox(
            height: 180,
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  activeTrackColor: isMuted ? Colors.red.shade400 : Colors.orangeAccent,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: isMuted ? Colors.red : Colors.orange,
                  overlayColor: Colors.orangeAccent.withOpacity(0.15),
                ),
                child: Slider(
                  min: 0.0,
                  max: 1.0,
                  value: faderVal,
                  onChanged: isMuted ? null : (v) => _onFaderChanged(index, v),
                ),
              ),
            ),
          ),

          const SizedBox(height: 6),

          // ── Indicateur de niveau visuel ──
          _buildLevelBar(faderVal, isMuted),

          const SizedBox(height: 8),

          // ── Bouton MUTE ──
          GestureDetector(
            onTap: () => _onMuteToggle(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: isMuted ? Colors.red : Colors.white10,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isMuted ? Colors.red.shade300 : Colors.white24,
                ),
              ),
              child: Text(
                'MUTE',
                style: TextStyle(
                  color: isMuted ? Colors.white : Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // ── Nom du canal ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isMuted ? Colors.red.shade300 : Colors.white54,
                fontSize: 9,
                letterSpacing: 0.5,
              ),
            ),
          ),

          const SizedBox(height: 6),
        ],
      ),
    );
  }

  // ── Mini barre de niveau ──
  Widget _buildLevelBar(double val, bool muted) {
    return SizedBox(
      height: 40,
      width: 28,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: List.generate(8, (i) {
          final threshold = (7 - i) / 8.0;
          final isActive = val > threshold && !muted;
          Color segColor;
          if (threshold > 0.85) {
            segColor = Colors.red;
          } else if (threshold > 0.65) {
            segColor = Colors.yellowAccent;
          } else {
            segColor = Colors.greenAccent;
          }
          return AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            height: 4,
            margin: const EdgeInsets.only(bottom: 1),
            decoration: BoxDecoration(
              color: isActive ? segColor : Colors.white10,
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }

  // ── Panneau MASTER ──
  Widget _buildMasterPanel() {
    final isMuted = _muted[0];
    final faderVal = _faders[0];

    return Container(
      color: const Color(0xFF12141A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Label ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orangeAccent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orangeAccent.withOpacity(0.4)),
              ),
              child: const Text(
                'MAIN L-R',
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3,
                ),
              ),
            ),

            const SizedBox(height: 24),

            // ── Valeur dB ──
            Text(
              _faderToDb(faderVal),
              style: TextStyle(
                color: isMuted ? Colors.red : Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                fontFamily: 'Courier',
              ),
            ),

            const SizedBox(height: 16),

            // ── Fader horizontal large ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 8,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 14),
                  activeTrackColor: isMuted ? Colors.red.shade600 : Colors.orangeAccent,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: isMuted ? Colors.red : Colors.deepOrange,
                  overlayColor: Colors.orangeAccent.withOpacity(0.2),
                ),
                child: Slider(
                  min: 0.0,
                  max: 1.0,
                  value: faderVal,
                  onChanged: isMuted ? null : (v) => _onFaderChanged(0, v),
                ),
              ),
            ),

            const SizedBox(height: 8),

            // ── Indicateur de niveau horizontal ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Row(
                children: List.generate(16, (i) {
                  final threshold = i / 16.0;
                  final isActive = faderVal > threshold && !isMuted;
                  Color segColor;
                  if (i >= 13) {
                    segColor = Colors.red;
                  } else if (i >= 10) {
                    segColor = Colors.yellowAccent;
                  } else {
                    segColor = Colors.greenAccent;
                  }
                  return Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      height: 10,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: isActive ? segColor : Colors.white10,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
            ),

            const SizedBox(height: 32),

            // ── Bouton MUTE MASTER ──
            GestureDetector(
              onTap: () => _onMuteToggle(0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 14),
                decoration: BoxDecoration(
                  color: isMuted ? Colors.red : Colors.white10,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isMuted ? Colors.red.shade300 : Colors.white24,
                    width: 2,
                  ),
                  boxShadow: isMuted
                      ? [BoxShadow(color: Colors.red.withOpacity(0.4), blurRadius: 20)]
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isMuted ? Icons.volume_off : Icons.volume_up,
                      color: isMuted ? Colors.white : Colors.white54,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      isMuted ? 'MUTE ACTIF' : 'MUTE MASTER',
                      style: TextStyle(
                        color: isMuted ? Colors.white : Colors.white54,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 28),

            // ── Info réseau ──
            Text(
              '${_api.ipAddress}  ·  Port ${_api.port}  ·  OSC/UDP',
              style: const TextStyle(color: Colors.white24, fontSize: 11, letterSpacing: 1),
            ),
          ],
        ),
      ),
    );
  }
}
