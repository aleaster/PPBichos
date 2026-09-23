import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'detalle_bitacora_screen.dart';

class BitacorasScreen extends StatefulWidget {
  const BitacorasScreen({super.key});

  @override
  State<BitacorasScreen> createState() => _BitacorasScreenState();
}

class _BitacorasScreenState extends State<BitacorasScreen> {
  List<dynamic> _bitacoras = [];
  bool _isLoading = true;
  
  // Cambia esta IP por la de tu backend
  final String _baseUrl = 'http://74.208.174.232:8001/api'; 

  @override
  void initState() {
    super.initState();
    _cargarBitacoras();
  }

  Future<void> _cargarBitacoras() async {
    setState(() => _isLoading = true);
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
          _bitacoras = data['data'] ?? [];
        });
      }
    } catch (e) {
      print("Error al cargar bitácoras: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  } // <-- Llave de cierre corregida. Aquí termina _cargarBitacoras.

  // Función extraída para que la interfaz pueda acceder a ella
  Future<void> _eliminarBitacora(String idBitacora) async {
    bool confirmar = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Eliminar Bitácora"),
        content: const Text("Tus registros internos no se borrarán, pasarán a ser 'Registros Unitarios'."),
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
        Uri.parse('$_baseUrl/bitacoras/$idBitacora'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        _cargarBitacoras();
      }
    } catch (e) {
      print(e);
    }
  }

Future<void> _mostrarDialogoEditarBitacora(Map<String, dynamic> bitacora) async {
    final TextEditingController nombreController = TextEditingController(text: bitacora['nombre']);
    final TextEditingController descController = TextEditingController(text: bitacora['descripcion']);
    bool guardando = false;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text("Editar Bitácora"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: nombreController, decoration: const InputDecoration(labelText: "Nombre")),
                  TextField(controller: descController, decoration: const InputDecoration(labelText: "Descripción"), maxLines: 2),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancelar")),
                ElevatedButton(
                  onPressed: guardando ? null : () async {
                    if (nombreController.text.trim().isEmpty) return;
                    setStateDialog(() => guardando = true);
                    
                    try {
                      String? token = await FirebaseAuth.instance.currentUser?.getIdToken();
                      var request = http.MultipartRequest('PUT', Uri.parse('$_baseUrl/bitacoras/${bitacora['id_bitacora']}'));
                      request.headers['Authorization'] = 'Bearer $token'; 
                      request.fields['nombre'] = nombreController.text.trim();
                      request.fields['descripcion'] = descController.text.trim();

                      var response = await request.send();
                      if (response.statusCode == 200) {
                        Navigator.pop(context);
                        _cargarBitacoras();
                      }
                    } catch (e) {
                      print(e);
                    } finally {
                      if (mounted) setStateDialog(() => guardando = false);
                    }
                  },
                  child: guardando ? const CircularProgressIndicator() : const Text("Actualizar"),
                ),
              ],
            );
          }
        );
      },
    );
  }


  Future<void> _mostrarDialogoNuevaBitacora() async {
    final TextEditingController nombreController = TextEditingController();
    final TextEditingController descController = TextEditingController();
    bool guardando = false;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text("Nueva Bitácora"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nombreController,
                    decoration: const InputDecoration(labelText: "Nombre (Ej: Salida Río Hacha)"),
                  ),
                  TextField(
                    controller: descController,
                    decoration: const InputDecoration(labelText: "Descripción (Opcional)"),
                    maxLines: 2,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancelar"),
                ),
                ElevatedButton(
                  onPressed: guardando ? null :() async {
                    if (nombreController.text.trim().isEmpty) return;
                    
                    setStateDialog(() => guardando = true);
                    
                    try {
                      String? token = await FirebaseAuth.instance.currentUser?.getIdToken();
                      var request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/bitacoras'));
                      request.headers['Authorization'] = 'Bearer $token'; 
                      request.fields['nombre'] = nombreController.text.trim();
                      request.fields['descripcion'] = descController.text.trim();

                      var response = await request.send();
                      if (response.statusCode == 200) {
                        Navigator.pop(context); // Cierra el modal
                        _cargarBitacoras(); // Recarga la lista
                      } else {
                        var errorData = await response.stream.bytesToString();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("Error del servidor: $errorData")),
                        );
                      }
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Error de conexión: $e")),
                      );
                    } finally {
                      // Esto asegura que el botón deje de girar sin importar lo que pase
                      if (mounted) {
                        setStateDialog(() => guardando = false);
                      }
                    }
                  },
                  child: guardando 
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text("Guardar"),
                ),
              ],
            );
          }
        );
      },
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _bitacoras.isEmpty
              ? const Center(child: Text("No tienes bitácoras aún. ¡Crea una!"))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _bitacoras.length,
                  itemBuilder: (context, index) {
                    final bitacora = _bitacoras[index];
                    // Formatear la fecha para que sea legible
                    DateTime fecha = DateTime.parse(bitacora['fecha_creacion']);
                    String fechaStr = "${fecha.day}/${fecha.month}/${fecha.year}";

                    return Card(
                      elevation: 2,
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.green,
                          child: Icon(Icons.library_books, color: Colors.white),
                        ),
                        title: Text(bitacora['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text("${bitacora['descripcion']}\nCreada: $fechaStr"),
                        isThreeLine: true,
                        
                        // --- BOTÓN DE ELIMINAR AGREGADO AQUÍ ---
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.blue),
                              onPressed: () => _mostrarDialogoEditarBitacora(bitacora),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.redAccent),
                              onPressed: () => _eliminarBitacora(bitacora['id_bitacora']),
                            ),
                          ],
                        ),
                        
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => DetalleBitacoraScreen(
                                idBitacora: bitacora['id_bitacora'],
                                nombreBitacora: bitacora['nombre'],
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: "btn_nueva_bitacora",
        onPressed: _mostrarDialogoNuevaBitacora,
        backgroundColor: Colors.green[700],
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text("Crear Bitácora", style: TextStyle(color: Colors.white)),
      ),
    );
  }
}