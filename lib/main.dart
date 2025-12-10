import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// --- CONFIGURACIÓN DE LA BÁSCULA ---
const String TARGET_ADDRESS =
    "D0:3E:7D:27:D2:4F"; // Cambia por la MAC de tu báscula
const String WEIGHT_SCALE_SERVICE_UUID = "0000181b-0000-1000-8000-00805f9b34fb";

// --- CONSTANTES ---
const double KG_DIVISOR = 200.0;
const double LB_TO_KG_FACTOR = 0.453592;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Xiaomi Scale',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const MiScaleScreen(),
    );
  }
}

class MiScaleScreen extends StatefulWidget {
  const MiScaleScreen({super.key});

  @override
  State<MiScaleScreen> createState() => _MiScaleScreenState();
}

class _MiScaleScreenState extends State<MiScaleScreen> {
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  String _statusMessage = "Presiona el botón para medir tu peso";
  String _weightResult = "---";
  bool _isScanning = false;
  bool _isStable = false;
  String _lastWeight = "";
  int _countdown = 0;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _checkBluetoothSupport();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  // --- VERIFICAR SOPORTE BLUETOOTH ---
  Future<void> _checkBluetoothSupport() async {
    bool isSupported = await FlutterBluePlus.isSupported;
    if (!isSupported) {
      setState(() {
        _statusMessage = "Bluetooth no soportado en este dispositivo";
      });
    }
  }

  // --- SOLICITAR PERMISOS ---
  Future<bool> _requestPermissions() async {
    // Verificar si Bluetooth está encendido
    var bluetoothState = await FlutterBluePlus.adapterState.first;
    if (bluetoothState != BluetoothAdapterState.on) {
      setState(() {
        _statusMessage = "Por favor enciende el Bluetooth";
      });
      return false;
    }

    // Solicitar permisos
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    bool allGranted = statuses.values.every((status) => status.isGranted);

    if (!allGranted) {
      setState(() {
        _statusMessage = "Permisos de Bluetooth requeridos";
      });
      return false;
    }

    return true;
  }

  // --- FUNCIÓN DE DECODIFICACIÓN ---
  Map<String, dynamic> decodeXiaomiData(Uint8List data) {
    if (data.length < 13) {
      return {'weight': 'Error', 'isStable': false};
    }

    // --- EXTRACCIÓN DE DATOS ---
    int flags = data[0];
    Uint8List weightBytes = data.sublist(data.length - 2);
    int weightRaw = weightBytes[0] | (weightBytes[1] << 8);

    // --- BANDERAS ---
    bool isLb = (flags & 0x01) != 0;
    bool isStable = (flags & 0x20) != 0;

    // --- CÁLCULO DEL PESO ---
    double weightKg;

    if (isLb) {
      double divisor = 100.0;
      double weightLb = weightRaw / divisor;
      weightKg = weightLb * LB_TO_KG_FACTOR;
    } else {
      weightKg = weightRaw / KG_DIVISOR;
    }

    return {'weight': weightKg.toStringAsFixed(2), 'isStable': isStable};
  }

  // --- CONTADOR REGRESIVO ---
  void _startCountdown() {
    _countdown = 5;
    _countdownTimer?.cancel();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _countdown--;
        if (_countdown > 0) {
          _statusMessage = "Midiendo peso... $_countdown segundos";
        }
      });

      if (_countdown <= 0) {
        timer.cancel();
      }
    });
  }

  // --- INICIAR ESCANEO ---
  Future<void> startScanning() async {
    setState(() {
      _isScanning = true;
      _statusMessage = "Verificando permisos...";
      _weightResult = "---";
      _isStable = false;
    });

    // Solicitar permisos
    bool hasPermissions = await _requestPermissions();
    if (!hasPermissions) {
      setState(() => _isScanning = false);
      return;
    }

    setState(() {
      _statusMessage = "Súbete a la báscula ahora";
    });

    _startCountdown();

    try {
      // Iniciar escaneo
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 5),
        androidUsesFineLocation: true,
      );

      // Escuchar resultados del escaneo
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          String deviceMac = result.device.remoteId.str.toUpperCase();

          // Filtrar por dirección MAC
          if (deviceMac == TARGET_ADDRESS.toUpperCase()) {
            // Buscar el servicio de peso
            Guid serviceGuid = Guid(WEIGHT_SCALE_SERVICE_UUID);
            if (result.advertisementData.serviceData.containsKey(serviceGuid)) {
              List<int> rawData =
                  result.advertisementData.serviceData[serviceGuid]!;
              Uint8List payload = Uint8List.fromList(rawData);

              if (payload.length >= 13) {
                Map<String, dynamic> decoded = decodeXiaomiData(payload);

                setState(() {
                  _weightResult = decoded['weight'];
                  _lastWeight = decoded['weight'];
                  _isStable = decoded['isStable'];
                });

                // Si el peso es estable, detener el escaneo inmediatamente
                if (decoded['isStable']) {
                  stopScanning();
                  setState(() {
                    _statusMessage = "Peso registrado correctamente";
                  });
                }
              }
            }
          }
        }
      });

      // Timeout automático de 5 segundos
      Future.delayed(const Duration(seconds: 5), () {
        if (_isScanning) {
          stopScanning();
          if (_lastWeight.isNotEmpty && _lastWeight != "---") {
            setState(() {
              _statusMessage = "Peso registrado: ${_lastWeight} kg";
            });
          } else {
            setState(() {
              _statusMessage = "No se detectó peso. Intenta de nuevo.";
              _weightResult = "---";
            });
          }
        }
      });
    } catch (e) {
      setState(() {
        _statusMessage = "Error al conectar con la báscula";
        _isScanning = false;
      });
    }
  }

  // --- DETENER ESCANEO ---
  Future<void> stopScanning() async {
    _countdownTimer?.cancel();
    await _scanSubscription?.cancel();
    await FlutterBluePlus.stopScan();
    setState(() {
      _isScanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Mi Báscula Xiaomi'),
        centerTitle: true,
        elevation: 0,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icono de báscula
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.monitor_weight_outlined,
                  size: 60,
                  color: Colors.blue.shade700,
                ),
              ),

              const SizedBox(height: 40),

              // Resultado del peso
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      _weightResult,
                      style: TextStyle(
                        fontSize: 64,
                        fontWeight: FontWeight.bold,
                        color: _isStable
                            ? Colors.green.shade700
                            : Colors.blue.shade700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'kilogramos',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (_isStable) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_circle,
                              color: Colors.green.shade700,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Peso estable',
                              style: TextStyle(
                                color: Colors.green.shade700,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // Mensaje de estado
              Text(
                _statusMessage,
                style: TextStyle(fontSize: 16, color: Colors.grey.shade700),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 40),

              // Botón principal
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isScanning ? null : startScanning,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 2,
                  ),
                  child: _isScanning
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text(
                              _countdown > 0
                                  ? 'Midiendo... $_countdown s'
                                  : 'Midiendo...',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        )
                      : const Text(
                          'Medir Peso',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 60),

              // Info adicional
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Colors.blue.shade700,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Asegúrate de que la báscula esté encendida antes de medir',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.blue.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
