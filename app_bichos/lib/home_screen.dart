import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'login_screen.dart';
import 'bitacoras_screen.dart';
import 'registros_unitarios_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final MapController _mapController = MapController();
  Position? _posicionActual;
  int _indiceNavegacion = 0;
  
  final ImagePicker _picker = ImagePicker();
  List<dynamic> _listaBitacoras = [];
  
  // IP para el Emulador de Android. Si usas un celular físico, cámbiala por tu IPv4 local (ej. 192.168.1.X)
  final String _baseUrl = 'http://74.208.174.232:8001/api';

  final List<Widget> _vistas = [
    const SizedBox(), 
    const BitacorasScreen(), 
    const RegistrosUnitariosScreen(), 
  ];

  List<dynamic> _registrosRealesMap = [];

  @override
  void initState() {
    super.initState();
    _cargarBitacorasParaSelector();
    
    // Esperar a que la UI esté lista antes de invocar la ventana nativa de permisos
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _obtenerUbicacion(centrarMapa: true);
    });
  }

  // --- LÓGICA DE UBICACIÓN ---
  Future<void> _obtenerUbicacion({bool centrarMapa = false}) async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // --- MODIFICACIÓN: Avisar al usuario sin romper la app ---
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("GPS desactivado. Modo de solo lectura activado."),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return; // Detenemos la ejecución de forma segura
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    
    Position posicion = await Geolocator.getCurrentPosition();
    setState(() {
      _posicionActual = posicion;
    });
  
    
    // Disparar la carga de pines reales basados en tu ubicación
    _cargarBichosEnMapa(posicion.latitude, posicion.longitude);

    if (centrarMapa) {
      _mapController.move(LatLng(posicion.latitude, posicion.longitude), 15.0);
    }
  }

  // --- OBTENER BITÁCORAS PARA EL DROPDOWN ---
  Future<void> _cargarBitacorasParaSelector() async {
    try {
      String? token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return;

      final response = await http.get(
        Uri.parse('$_baseUrl/bitacoras'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _listaBitacoras = data['data'] ?? [];
        });
      }
    } catch (e) {
      print("Error cargando bitácoras para selector: $e");
    }
  }

  // --- BOTTOM SHEET DE CAPTURA ---
  // --- BOTTOM SHEET DE CAPTURA ---
 void _mostrarBottomSheetCaptura() {
    if (_posicionActual == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Esperando señal GPS. Intenta de nuevo en unos segundos.")),
      );
      _obtenerUbicacion();
      return;
    }

    // 1. Variables movidas AFUERA del builder para que sobrevivan a los redibujados
    File? imagenSeleccionada;
    String? idBitacoraSeleccionada;
    bool procesando = false;
    
    final TextEditingController sitioController = TextEditingController();
    final TextEditingController nombreComunController = TextEditingController();
    final TextEditingController descController = TextEditingController();
    final TextEditingController climaController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) {
        // El builder ahora solo construye la interfaz, no reinicia las variables
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateSheet) {
            
            Future<void> obtenerImagen(ImageSource fuente) async {
              final XFile? foto = await _picker.pickImage(source: fuente);
              if (foto != null) {
                setStateSheet(() {
                  imagenSeleccionada = File(foto.path);
                });
              }
            }

            void mostrarOpcionesImagen() {
              showModalBottomSheet(
                context: context,
                builder: (BuildContext bc) {
                  return SafeArea(
                    child: Wrap(
                      children: <Widget>[
                        ListTile(
                          leading: const Icon(Icons.camera_alt),
                          title: const Text('Tomar foto'),
                          onTap: () {
                            Navigator.of(context).pop();
                            obtenerImagen(ImageSource.camera);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.photo_library),
                          title: const Text('Elegir de la galería'),
                          onTap: () {
                            Navigator.of(context).pop();
                            obtenerImagen(ImageSource.gallery);
                          },
                        ),
                      ],
                    ),
                  );
                }
              );
            }

            Future<void> enviarReporte() async {
              if (imagenSeleccionada == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Debes adjuntar una imagen")),
                );
                return;
              }
              
              setStateSheet(() => procesando = true);

              try {
                // --- NUEVO: CÁLCULO AUTOMÁTICO DE ALTITUD REAL ---
                double altitudFinal = _posicionActual!.altitude;
                
                // Si el GPS falla o el emulador da 0.0, consultamos Open-Meteo
                if (altitudFinal == 0.0) {
                  try {
                    final altResp = await http.get(Uri.parse(
                        'https://api.open-meteo.com/v1/elevation?latitude=${_posicionActual!.latitude}&longitude=${_posicionActual!.longitude}'));
                    
                    if (altResp.statusCode == 200) {
                      final altData = json.decode(altResp.body);
                      if (altData['elevation'] != null && altData['elevation'].isNotEmpty) {
                        altitudFinal = (altData['elevation'][0] as num).toDouble();
                      }
                    }
                  } catch (_) {
                    // Falla silenciosa si no hay internet
                  }
                }
                // --------------------------------------------------

                String? token = await FirebaseAuth.instance.currentUser?.getIdToken();
                var uri = Uri.parse('$_baseUrl/reportar');
                var request = http.MultipartRequest('POST', uri);

                // Autenticación y Coordenadas
                request.headers['Authorization'] = 'Bearer $token';
                request.fields['latitud'] = _posicionActual!.latitude.toString();
                request.fields['longitud'] = _posicionActual!.longitude.toString();
                
                // Enviamos la altitud procesada
                request.fields['altura'] = altitudFinal.toString(); 
                
                // Nuevos campos para ontología y reentrenamiento
                request.fields['nombre_sitio'] = sitioController.text.trim();
                request.fields['nombre_comun'] = nombreComunController.text.trim();
                request.fields['descripcion'] = descController.text.trim();
                request.fields['clima'] = climaController.text.trim();
                
                if (idBitacoraSeleccionada != null) {
                  request.fields['id_bitacora'] = idBitacoraSeleccionada!;
                }

                request.files.add(await http.MultipartFile.fromPath('imagen', imagenSeleccionada!.path));

                var response = await request.send();
                var responseData = await response.stream.bytesToString();
                
                if (response.statusCode == 200) {
                  var jsonResponse = json.decode(responseData);
                  Navigator.pop(context); // Cierra el modal principal
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("¡Éxito! Bicho detectado: ${jsonResponse['bicho']}"),
                      backgroundColor: Colors.green,
                    ),
                  );
                  _cargarBichosEnMapa(_posicionActual!.latitude, _posicionActual!.longitude);
                } else {
                  throw Exception("Error ${response.statusCode}: $responseData");
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Fallo en servidor: $e"), backgroundColor: Colors.red),
                );
              } finally {
                if (mounted) setStateSheet(() => procesando = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 20, right: 20, top: 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Nuevo Hallazgo", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    
                    GestureDetector(
                      onTap: mostrarOpcionesImagen,
                      child: Container(
                        height: 180,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey[400]!),
                        ),
                        child: imagenSeleccionada != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(imagenSeleccionada!, fit: BoxFit.cover),
                              )
                            : const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_a_photo, size: 40, color: Colors.grey),
                                  SizedBox(height: 8),
                                  Text("Tocar para agregar imagen", style: TextStyle(color: Colors.grey)),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    TextField(
                      controller: sitioController,
                      decoration: const InputDecoration(
                        labelText: "Nombre del Sitio de Muestra",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: nombreComunController,
                      decoration: const InputDecoration(
                        labelText: "Nombre Común (Identificación Preliminar)",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: descController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: "Descripción de la observación",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 16),

                    TextField(
                      controller: climaController,
                      decoration: const InputDecoration(
                        labelText: "Clima (Ej. Soleado, Lluvia ligera)",
                        border: OutlineInputBorder(),
                        isDense: true,
                        prefixIcon: Icon(Icons.cloud_queue),
                      ),
                    ),
                    const SizedBox(height: 16),

                    DropdownButtonFormField<String>(
                      decoration: const InputDecoration(
                        labelText: "Asignar a Bitácora (Opcional)",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      value: idBitacoraSeleccionada,
                      items: [
                        const DropdownMenuItem(value: null, child: Text("Registro Unitario (Sin bitácora)")),
                        ..._listaBitacoras.map((bitacora) {
                          return DropdownMenuItem<String>(
                            value: bitacora['id_bitacora'],
                            child: Text(bitacora['nombre']),
                          );
                        }),
                      ],
                      onChanged: (String? newValue) {
                        setStateSheet(() {
                          idBitacoraSeleccionada = newValue;
                        });
                      },
                    ),
                    const SizedBox(height: 24),

                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: (imagenSeleccionada == null || procesando) ? null : enviarReporte,
                        icon: procesando ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.cloud_upload),
                        label: Text(procesando ? "Guardando reporte..." : "Subir y Analizar"),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            );
          }
        );
      },
    );
  }

  // --- LÓGICA DE COLORES POR ESPECIE ---
  Color _obtenerColorPorBicho(String nombreBicho) {
    switch (nombreBicho.toLowerCase()) {
      case "abeja":
        return Colors.amber;
      case "escarabajo":
        return Colors.brown;
      case "mariposa":
        return Colors.blueAccent;
      default:
        return Colors.red;
    }
  }

  void _alCambiarPestana(int index) {
    setState(() {
      _indiceNavegacion = index;
    });
    
    // NUEVO: Si el usuario vuelve a la pestaña del Mapa (índice 0), 
    // recargamos los pines desde la base de datos para borrar los eliminados.
    if (index == 0 && _posicionActual != null) {
      _cargarBichosEnMapa(_posicionActual!.latitude, _posicionActual!.longitude);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Radar de Bichos"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (mounted) {
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const LoginScreen()));
              }
            },
          )
        ],
      ),
      
      body: _indiceNavegacion == 0 
        ? FlutterMap(
            options: MapOptions(
              // --- MODIFICACIÓN: Coordenada de respaldo (Florencia, Caquetá) ---
              initialCenter: _posicionActual != null 
                  ? LatLng(_posicionActual!.latitude, _posicionActual!.longitude)
                  : const LatLng(1.61438, -75.60623), 
              initialZoom: 14.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.bichos.app',
              ),
              MarkerLayer(
                markers: [
                  // 1. Tu marcador de ubicación actual (el punto azul)
                  if (_posicionActual != null && !_posicionActual!.latitude.isNaN)
                    Marker(
                      point: LatLng(_posicionActual!.latitude, _posicionActual!.longitude),
                      width: 50,
                      height: 50,
                      child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
                    ),
                    
                  // 2. Marcadores de la base de datos (Protegidos matemáticamente)
                  ..._registrosRealesMap.where((registro) {
                    if (registro['latitud'] == null || registro['longitud'] == null) return false;
                    
                    double lat = (registro['latitud'] is num) 
                        ? (registro['latitud'] as num).toDouble() 
                        : double.tryParse(registro['latitud'].toString()) ?? 0.0;
                        
                    double lon = (registro['longitud'] is num) 
                        ? (registro['longitud'] as num).toDouble() 
                        : double.tryParse(registro['longitud'].toString()) ?? 0.0;
                        
                    // --- FILTRO DE SEGURIDAD EXTREMA ---
                    // Evita que un cálculo infinito o NaN destruya el mapa
                    if (lat.isNaN || lon.isNaN || lat.isInfinite || lon.isInfinite) return false;
                    // Evita coordenadas que no existen en el planeta Tierra
                    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return false;
                    
                    return true; // Solo pasan los reportes 100% seguros
                  }).map((registro) {
                    
                    // Extraemos nuevamente las coordenadas ya validadas
                    double lat = (registro['latitud'] is num) ? (registro['latitud'] as num).toDouble() : double.tryParse(registro['latitud'].toString()) ?? 0.0;
                    double lon = (registro['longitud'] is num) ? (registro['longitud'] as num).toDouble() : double.tryParse(registro['longitud'].toString()) ?? 0.0;
                    String nombreBicho = registro['bicho_ia']?.toString() ?? registro['bicho']?.toString() ?? 'Desconocido';

                    return Marker(
                      point: LatLng(lat, lon),
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Insecto: $nombreBicho | ID: ${registro['id_reporte']}")),
                          );
                        },
                        child: Icon(
                          Icons.location_on, 
                          color: _obtenerColorPorBicho(nombreBicho), 
                          size: 40,
                        ),
                      ),
                    );
                  }).toList(),
                ],
              ),
            ],
          )
        : _vistas[_indiceNavegacion],

      floatingActionButton: _indiceNavegacion == 0 
        ? Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Botón 1: Centrar Ubicación (Blanco)
              FloatingActionButton(
                heroTag: "btn_loc",
                backgroundColor: Colors.white,
                onPressed: () => _obtenerUbicacion(centrarMapa: true),
                child: const Icon(Icons.my_location, color: Colors.blue),
              ),
              const SizedBox(height: 16),
              // Botón 2: Capturar Insecto (Verde)
              FloatingActionButton(
                heroTag: "btn_add",
                backgroundColor: Colors.green,
                onPressed: () async {
                  bool gpsActivo = await Geolocator.isLocationServiceEnabled();
                  
                  if (!gpsActivo) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("⚠️ Debes encender el GPS para registrar un insecto."),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return; 
                  }

                  if (_posicionActual == null) {
                    await _obtenerUbicacion();
                    if (_posicionActual == null) return; 
                  }

                  _mostrarBottomSheetCaptura();
                },
                child: const Icon(Icons.camera_alt, color: Colors.white),
              ),
            ],
          )
        : null,

      bottomNavigationBar: NavigationBar(
        selectedIndex: _indiceNavegacion,
        onDestinationSelected: _alCambiarPestana,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map),
            label: 'Mapa',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_books),
            label: 'Bitácoras',
          ),
          NavigationDestination(
            icon: Icon(Icons.format_list_bulleted),
            label: 'Registros',
          ),
        ],
      ),
    );
  }

  // --- CARGAR PUNTOS REALES DEL BACKEND ---
  Future<void> _cargarBichosEnMapa(double lat, double lon) async {
    try {
      String? token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return;

      // Consulta al endpoint espacial con un radio de 10 kilómetros (10000 metros)
      final response = await http.get(
        Uri.parse('$_baseUrl/bichos-cercanos?lat=$lat&lon=$lon&radio_metros=10000'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _registrosRealesMap = data['data'] ?? [];
        });
      }
    } catch (e) {
      print("Error cargando puntos del mapa: $e");
    }
  }
}