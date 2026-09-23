import gradio as gr
from ultralytics import YOLO

# 1. Cargar tu modelo exportado
model = YOLO('ModeloIA/best_int8.tflite')

def analizar_bicho(ruta_imagen):
    # 2. Realizar la predicción recibiendo la ruta original del archivo
    # Esto asegura que YOLO cargue la imagen con los colores correctos (café, no azul)
    resultados = model.predict(source=ruta_imagen, imgsz=416)
    
    # 3. Extraer la imagen con las cajas dibujadas por YOLO
    # YOLO devuelve BGR, así que lo invertimos para que Gradio lo muestre bien en pantalla
    imagen_procesada = resultados[0].plot()[..., ::-1] 
    
    # 4. Formatear el texto con los porcentajes de similitud
    texto_resultados = "--- RESULTADOS DE SIMILITUD ---\n\n"
    encontro_bicho = False
    
    for box in resultados[0].boxes:
        encontro_bicho = True
        clase_id = int(box.cls[0])
        probabilidad = float(box.conf[0]) * 100
        nombre_bicho = model.names[clase_id]
        
        texto_resultados += f"✅ Insecto: {nombre_bicho}\n"
        texto_resultados += f"📊 Similitud: {probabilidad:.2f}%\n\n"
        
    if not encontro_bicho:
        texto_resultados += "❌ La IA no logró identificar ningún insecto entrenado."
        
    return imagen_procesada, texto_resultados

# 5. Construir la interfaz gráfica Drag & Drop
interfaz = gr.Interface(
    fn=analizar_bicho,
    # EL CAMBIO CLAVE ESTÁ AQUÍ: type="filepath" en lugar de type="numpy"
    inputs=gr.Image(type="filepath", label="Arrastra la foto del reporte aquí"),
    outputs=[
        gr.Image(type="numpy", label="Detección de la IA"),
        gr.Textbox(label="Análisis de Similitud", lines=5)
    ],
    title="🔬 Detector de Insectos IA",
    description="Arrastra una imagen para poner a prueba tu modelo YOLOv8 cuantizado."
)

# 6. Lanzar la aplicación
if __name__ == "__main__":
    interfaz.launch()