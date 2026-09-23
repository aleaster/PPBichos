import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';

class RegistrosUnitariosScreen extends StatefulWidget {
  const RegistrosUnitariosScreen({super.key});

  @override
  State<RegistrosUnitariosScreen> createState() => _RegistrosUnitariosScreenState();
}

class _RegistrosUnitariosScreenState extends State<RegistrosUnitariosScreen> {
  final String _baseUrl = 'http://74.208.174.232:8001/api';
  List<dynamic> _reportes = [];
  bool _cargando = true;
  final Map<String, Map<String, dynamic>> _cacheTaxonomia = {};

  @override
  void initState() {
    super.initState();
    _cargarUnitarios();
  }

  Future<void> _cargarUnitarios() async {
    try {
      String? token = await FirebaseAuth.instance.currentUser?.getIdToken();
      final response = await http.get(
        Uri.parse('$_baseUrl/reportes/unitarios'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _reportes = data['data'] ?? [];
          _cargando = false;
        });
      }
    } catch (e) {
      setState(() => _cargando = false);
    }
  }

  // Se movió esta función FUERA de _cargarUnitarios para que la interfaz pueda verla
  Future<void> _eliminarReporte(String idReporte) async {
    bool confirmar = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Eliminar Reporte"),
        content: const Text("¿Estás seguro? Esta acción no se puede deshacer."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancelar")),
          TextButton(
            onPressed: () => Navigator.pop(context, true), 
            child: const Text("Eliminar", style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    ) ?? false;

    if (!confirmar) return;

    try {
      String? token = await FirebaseAuth.instance.currentUser?.getIdToken();
      final response = await http.delete(
        Uri.parse('$_baseUrl/reportes/$idReporte'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Reporte eliminado")));
        if (mounted) setState(() { _cargando = true; });
        _cargarUnitarios(); 
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  // Método que consulta a Fuseki solo si el bicho fue identificado
 Future<Map<String, dynamic>> _obtenerFichaTaxonomica(String nombreBichoIa) async {
    // 1. Limpiamos guiones y eliminamos espacios accidentales al inicio o final
    String nombreLimpio = nombreBichoIa.replaceAll('-', ' ').replaceAll('_', ' ').trim();

    // 2. Filtro de caché: si ya consultamos este insecto, devolvemos el dato guardado
    if (_cacheTaxonomia.containsKey(nombreLimpio)) {
      return _cacheTaxonomia[nombreLimpio]!;
    }

    try {
      String? token = await FirebaseAuth.instance.currentUser?.getIdToken();
      
      // 3. Codificamos la URL (Uri.encodeComponent) para procesar los espacios correctamente
      final response = await http.get(
        Uri.parse('$_baseUrl/detalle-bicho/${Uri.encodeComponent(nombreLimpio)}'),
        headers: {'Authorization': 'Bearer $token'},
      );
      
      if (response.statusCode == 200) {
        var data = json.decode(utf8.decode(response.bodyBytes));
        _cacheTaxonomia[nombreLimpio] = data; // Guardamos en memoria
        return data;
      }
      return {'exito': false};
    } catch (e) {
      return {'exito': false};
    }
  }

void _mostrarBottomSheetEditarReporte(Map<String, dynamic> reporte) {
    final TextEditingController sitioController = TextEditingController(text: reporte['nombre_sitio']);
    final TextEditingController nombreComunController = TextEditingController(text: reporte['nombre_comun']);
    final TextEditingController descController = TextEditingController(text: reporte['descripcion']);
    final TextEditingController climaController = TextEditingController(text: reporte['clima']);
    bool procesando = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateSheet) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 20, right: 20, top: 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Editar Hallazgo", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    TextField(controller: sitioController, decoration: const InputDecoration(labelText: "Sitio", border: OutlineInputBorder(), isDense: true)),
                    const SizedBox(height: 12),
                    TextField(controller: nombreComunController, decoration: const InputDecoration(labelText: "Nombre Común", border: OutlineInputBorder(), isDense: true)),
                    const SizedBox(height: 12),
                    TextField(controller: descController, maxLines: 2, decoration: const InputDecoration(labelText: "Descripción", border: OutlineInputBorder(), isDense: true)),
                    const SizedBox(height: 16),
                    TextField(controller: climaController, decoration: const InputDecoration(labelText: "Clima", border: OutlineInputBorder(), isDense: true)),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: procesando ? null : () async {
                          setStateSheet(() => procesando = true);
                          try {
                            String? token = await FirebaseAuth.instance.currentUser?.getIdToken();
                            var request = http.MultipartRequest('PUT', Uri.parse('$_baseUrl/reportes/${reporte['id_reporte']}'));
                            request.headers['Authorization'] = 'Bearer $token'; 
                            request.fields['nombre_sitio'] = sitioController.text.trim();
                            request.fields['nombre_comun'] = nombreComunController.text.trim();
                            request.fields['descripcion'] = descController.text.trim();
                            request.fields['clima'] = climaController.text.trim();
                            // Mantenemos la bitácora actual
                            if (reporte['id_bitacora'] != null) {
                              request.fields['id_bitacora'] = reporte['id_bitacora'];
                            }

                            var response = await request.send();
                            if (response.statusCode == 200) {
                              Navigator.pop(context);
                              // Llama a _cargarUnitarios() o _cargarReportes() según el archivo
                              if (mounted) setState(() { _cargando = true; });
                              _cargarUnitarios(); // <-- Ajusta el nombre si estás en detalle_bitacora
                            }
                          } catch (e) {
                            print(e);
                          } finally {
                            if (mounted) setStateSheet(() => procesando = false);
                          }
                        },
                        icon: procesando ? const CircularProgressIndicator(color: Colors.white) : const Icon(Icons.save),
                        label: Text(procesando ? "Guardando..." : "Actualizar Datos"),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
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


  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_reportes.isEmpty) return const Center(child: Text("No hay registros unitarios."));

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _reportes.length,
      itemBuilder: (context, index) {
        var reporte = _reportes[index];
       return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (reporte['imagen_base64'] != null)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  child: Image.memory(
                    base64Decode(reporte['imagen_base64']),
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            "IA detectó: ${reporte['bicho_ia']}", 
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_note, color: Colors.blue),
                              onPressed: () => _mostrarBottomSheetEditarReporte(reporte),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              onPressed: () => _eliminarReporte(reporte['id_reporte']), // O _eliminarReporteBitacora
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                   Text("📍 Sitio: ${reporte['nombre_sitio'] ?? 'N/A'}"),
                    Text("📝 Descripción: ${reporte['descripcion'] ?? 'Sin descripción'}"),
                    if (reporte['clima'] != null && reporte['clima'].toString().isNotEmpty)
                      Text("☁️ Clima: ${reporte['clima']}"),
                      
                    // --- NUEVO: MOSTRAR COORDENADAS Y ALTURA ---
                    if (reporte['latitud'] != null && reporte['longitud'] != null)
                      Text("🌍 Coordenadas: ${reporte['latitud'].toStringAsFixed(5)}, ${reporte['longitud'].toStringAsFixed(5)}"),
                    if (reporte['altura'] != null)
                      Text("⛰️ Altura: ${reporte['altura'].toStringAsFixed(1)} msnm"),
                    
                    // --- NUEVO: SECCIÓN DE TAXONOMÍA (ONTOLOGÍA FUSEKI) ---
                    if (reporte['bicho_ia'] != null && reporte['bicho_ia'].toString().toLowerCase() != 'desconocido') ...[
                      const Divider(height: 30, thickness: 1),
                      FutureBuilder<Map<String, dynamic>>(
                        future: _obtenerFichaTaxonomica(reporte['bicho_ia']),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          if (snapshot.hasError || !snapshot.hasData || snapshot.data!['exito'] == false) {
                            return const Text("Ficha taxonómica no disponible en la base de conocimiento.", style: TextStyle(color: Colors.grey));
                          }
                          
                          var tax = snapshot.data!;
                          return Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.green.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text("📖 Ficha Taxonómica", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.green)),
                                const SizedBox(height: 8),
                                Text("• Reino: ${tax['reino']}"),
                                Text("• Filo: ${tax['filo']}"),
                                Text("• Clase: ${tax['clase']}"),
                                Text("• Orden: ${tax['orden']}"),
                                Text("• Familia: ${tax['familia']}"),
                                Text("• Género: ${tax['genero']}"),
                                Text("• Especie: ${tax['especie']}"),
                                
                                const Divider(height: 20, color: Colors.green),
                                
                                const Text("📊 Información Ecológica", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.green)),
                                const SizedBox(height: 8),
                                Text("🏷️ Nombre Común:\n${tax['nombre_comun']}", style: const TextStyle(fontStyle: FontStyle.italic)),
                                const SizedBox(height: 4),
                                Text("🌱 Importancia:\n${tax['importancia']}", style: const TextStyle(fontStyle: FontStyle.italic)),
                                const SizedBox(height: 4),
                                Text("🌍 Indicador de Suelo:\n${tax['indicador']}", style: const TextStyle(fontStyle: FontStyle.italic)),
                                const SizedBox(height: 4),
                                Text("🔍 Observación:\n${tax['observacion']}", style: const TextStyle(fontStyle: FontStyle.italic)),
                              ],
                            ),
                          );
                        }
                      ),
                    ],
                    // --------------------------------------------------------
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}