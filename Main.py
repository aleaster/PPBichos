from fastapi import FastAPI, UploadFile, File, Form, Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.middleware.cors import CORSMiddleware
from firebase_admin import auth, credentials
import firebase_admin
from motor.motor_asyncio import AsyncIOMotorClient
import asyncpg
from SPARQLWrapper import SPARQLWrapper, JSON
from ultralytics import YOLO
import cv2
import numpy as np
import uuid
import base64
from typing import Optional
from datetime import datetime
import traceback
from fastapi import BackgroundTasks

app = FastAPI(title="API Backend Bichos")

# --- CONFIGURACIÓN CORS ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Permite tráfico desde cualquier IP o dominio
    allow_credentials=True,
    allow_methods=["*"],  # Habilita todos los verbos HTTP (GET, POST, etc.)
    allow_headers=["*"],  # Habilita todas las cabeceras (vital para recibir el Authorization Bearer)
)
security = HTTPBearer()

# --- INICIALIZACIÓN DE SERVICIOS ---
# 1. Firebase Auth
cred = credentials.Certificate("claves/firebase-adminsdk.json")
firebase_admin.initialize_app(cred)

# 2. Modelo de Inteligencia Artificial
model = YOLO('ModeloIA/best_int8.tflite')

# 3. Apache Jena Fuseki
fuseki = SPARQLWrapper("http://localhost:3030/BDBichos/update")

# 4. Clientes de BD
mongo_client = None
pg_pool = None

@app.on_event("startup")
async def startup():
    global mongo_client, pg_pool
    
    # Conexión asíncrona a MongoDB Atlas
    URI_MONGO = "mongodb+srv://BDBichos:bdbichos2026@cluster0.7enzro3.mongodb.net/?appName=Cluster0"
    mongo_client = AsyncIOMotorClient(URI_MONGO)
    
    # Conexión asíncrona a PostgreSQL local
    URI_POSTGRES = "postgresql://postgres:25012004@localhost:5432/bichos_BD"
    pg_pool = await asyncpg.create_pool(URI_POSTGRES)
    
    print("Conexiones a MongoDB Atlas y PostgreSQL local establecidas correctamente.")

# --- MIDDLEWARE DE SEGURIDAD ---
def verificar_token(credenciales: HTTPAuthorizationCredentials = Depends(security)):
    try:
        usuario_decodificado = auth.verify_id_token(credenciales.credentials)
        return usuario_decodificado
    except auth.ExpiredIdTokenError:
        raise HTTPException(status_code=401, detail="El token ha expirado. El usuario debe iniciar sesión nuevamente.")
    except auth.InvalidIdTokenError:
        raise HTTPException(status_code=401, detail="El token de Firebase es inválido o está mal formado.")
    except Exception as e:
        raise HTTPException(status_code=401, detail=f"Error de autenticación: {str(e)}")

# --- ENDPOINTS DE USUARIO ---
@app.get("/api/perfil")
async def obtener_perfil(usuario: dict = Depends(verificar_token)):
    return {
        "mensaje": "Autenticación exitosa. Tu backend reconoce a este usuario.", 
        "uid": usuario.get("uid"), 
        "email": usuario.get("email")
    }

# --- ENDPOINTS DE BITÁCORAS ---
@app.post("/api/bitacoras")
async def crear_bitacora(
    nombre: str = Form(...),
    descripcion: Optional[str] = Form(""),
    usuario: dict = Depends(verificar_token)
):
    uid_usuario = usuario['uid']
    id_bitacora = f"bitacora_{str(uuid.uuid4())[:8]}"
    
    db_mongo = mongo_client.bichos_db
    nueva_bitacora = {
        "id_bitacora": id_bitacora,
        "uid_usuario": uid_usuario,
        "nombre": nombre,
        "descripcion": descripcion,
        "fecha_creacion": datetime.now().isoformat() # Genera la fecha exacta del sistema
    }
    
    await db_mongo.bitacoras.insert_one(nueva_bitacora)
    return {"exito": True, "id_bitacora": id_bitacora, "mensaje": "Bitácora creada"}

@app.get("/api/bitacoras")
async def listar_bitacoras(usuario: dict = Depends(verificar_token)):
    uid_usuario = usuario['uid']
    db_mongo = mongo_client.bichos_db
    
    cursor = db_mongo.bitacoras.find({"uid_usuario": uid_usuario})
    bitacoras = []
    async for doc in cursor:
        doc['_id'] = str(doc['_id'])
        bitacoras.append(doc)
        
    return {"exito": True, "data": bitacoras}

# --- ENDPOINTS DE REPORTES E IA ---

async def procesar_ia_segundo_plano(
    imagen_bytes: bytes,
    id_reporte: str,
    uid_limpio: str,
    id_bitacora: Optional[str],
    nombre_sitio: str,
    nombre_comun: str,
    descripcion: str
):
    try:
        # 1. INFERENCIA CON YOLOv8
        nparr = np.frombuffer(imagen_bytes, np.uint8)
        img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        resultados = model.predict(source=img, imgsz=416, conf=0.5)
        
        bicho_detectado = "Desconocido"
        if len(resultados[0].boxes) > 0:
            mejor_deteccion = max(resultados[0].boxes, key=lambda box: box.conf[0])
            nombre_crudo = model.names[int(mejor_deteccion.cls[0])]
            
            # DICCIONARIO DE TRADUCCIÓN: (Clase YOLO -> Nombre Exacto en Ontología)
            mapeo_taxonomico = {
                "Canton-Juvencus": "Canthon Juvencus",                # Corrección ortográfica
                "Grompas-Lemoinei": "Gromphas Lemoinei",              # Corrección ortográfica
                "Dichotomius-cf-Globulus": "Dichotomius Globulus",    # Limpieza de etiqueta 'cf'
                "Ontherus-cf-Appendiculatus": "Ontherus Appendiculatus", 
                "Ontherus-cf-Pubens": "Ontherus Pubens",
                "Onthophagus_Aff_Bidentatus": "Onthophagus Bidentatus" # Limpieza de etiqueta 'Aff'
            }
            
            # 1. Si el nombre de YOLO está en el diccionario de errores, lo reescribe al correcto
            if nombre_crudo in mapeo_taxonomico:
                bicho_detectado = mapeo_taxonomico[nombre_crudo]
            else:
                # 2. Si no está en el diccionario, limpia guiones por defecto (Ej: "Aphodino-sp1" -> "Aphodino sp1")
                bicho_detectado = nombre_crudo.replace('-', ' ').replace('_', ' ')
                
                # Regla especial para limpiar cadenas complejas de Phanaeus
                if "Phanaeus" in bicho_detectado and "Haroldi" in bicho_detectado:
                    bicho_detectado = "Phanaeus Haroldi"
            
        # 2. ACTUALIZAR MONGODB
        db_mongo = mongo_client.bichos_db
        await db_mongo.reportes.update_one(
            {"id_reporte": id_reporte},
            {"$set": {"bicho_ia": bicho_detectado}}
        )

        # 3. FUSEKI
        relacion_bitacora = f":{id_reporte} :pertenece_a_bitacora :{id_bitacora} ." if id_bitacora else ""
        desc_limpia = descripcion.replace('"', "'").replace('\n', ' ')
        sitio_limpio = nombre_sitio.replace('"', "'")
        comun_limpio = nombre_comun.replace('"', "'")
        bicho_formateado = bicho_detectado.replace(' ', '_')

        query_semantica = f"""
            PREFIX : <http://www.semanticweb.org/josed/ontologies/2026/7/untitled-ontology-6/>
            INSERT DATA {{
                :{uid_limpio} :Genera_Reportes :{id_reporte} .
                :{id_reporte} :se_le_asigna_a_un :Analisis_{bicho_formateado} ;
                              :Nombre_Sitio_Muestra "{sitio_limpio}" ;
                              :NombreComun "{comun_limpio}" ;
                              :Descripcion "{desc_limpia}" .
                {relacion_bitacora}
            }}
        """
        
        import urllib.request
        import urllib.parse
        url_fuseki = "http://localhost:3030/BDBichos/update"
        datos_post = urllib.parse.urlencode({'update': query_semantica}).encode('utf-8')
        req = urllib.request.Request(url_fuseki, data=datos_post)
        urllib.request.urlopen(req)
        
        print(f"IA finalizada en segundo plano. Bicho '{bicho_detectado}' procesado con éxito.")
    except Exception as e:
        print("--- ERROR EN TAREA DE SEGUNDO PLANO (IA/FUSEKI) ---")
        import traceback
        traceback.print_exc()


@app.post("/api/reportar")
async def reportar_bicho(
    background_tasks: BackgroundTasks,
    latitud: float = Form(...),
    longitud: float = Form(...),
    altura: float = Form(0.0),
    clima: str = Form(""),
    nombre_sitio: str = Form(""),
    nombre_comun: str = Form(""),
    descripcion: str = Form(""),
    imagen: UploadFile = File(...),
    id_bitacora: Optional[str] = Form(None),
    usuario: dict = Depends(verificar_token)
):
    uid_usuario = usuario['uid']
    uid_limpio = "".join(c for c in uid_usuario if c.isalnum())
    id_reporte = f"reporte_{str(uuid.uuid4())[:8]}"

    try:
        contents = await imagen.read()
        imagen_base64 = base64.b64encode(contents).decode('utf-8')
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error al procesar la imagen: {str(e)}")

    # 1. MONGODB (Se guarda inmediatamente con estado "Analizando...")
    db_mongo = mongo_client.bichos_db
    try:
        await db_mongo.reportes.insert_one({
            "id_reporte": id_reporte,
            "uid_usuario": uid_usuario,
            "id_bitacora": id_bitacora,
            "bicho_ia": "Analizando...", # Estado temporal
            "nombre_sitio": nombre_sitio,
            "nombre_comun": nombre_comun,
            "descripcion": descripcion,
            "imagen_base64": imagen_base64 
        })
    except Exception as e:
        print("--- ERROR EN FASE MONGODB ---")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Fallo Mongo: {str(e)}")

    # 2. POSTGIS
    try:
        async with pg_pool.acquire() as conn:
            await conn.execute('''
                INSERT INTO reportes_espaciales (id_reporte, uid_usuario, id_bitacora, altura, clima, geom)
                VALUES ($1, $2, $3, $4, $5, ST_SetSRID(ST_MakePoint($6, $7), 4326))
            ''', id_reporte, uid_usuario, id_bitacora, altura, clima, longitud, latitud)
    except Exception as e:
        print("--- ERROR EN FASE POSTGIS ---")
        import traceback
        traceback.print_exc()
        await db_mongo.reportes.delete_one({"id_reporte": id_reporte})
        raise HTTPException(status_code=500, detail=f"Fallo PostGIS: {str(e)}")

    # 3. ENVIAR A IA Y FUSEKI AL SEGUNDO PLANO
    background_tasks.add_task(
        procesar_ia_segundo_plano, 
        contents, 
        id_reporte, 
        uid_limpio, 
        id_bitacora, 
        nombre_sitio, 
        nombre_comun, 
        descripcion
    )

    # El celular recibe esta respuesta en milisegundos, sin esperar a YOLO
    return {"exito": True, "bicho": "En proceso de análisis", "id_reporte": id_reporte, "id_bitacora": id_bitacora}

@app.get("/api/bichos-cercanos")
async def obtener_bichos_cercanos(lat: float, lon: float, radio_metros: int = 10000, usuario: dict = Depends(verificar_token)):
    async with pg_pool.acquire() as conn:
        registros_pg = await conn.fetch("""
            SELECT id_reporte, ST_Y(geom) as lat, ST_X(geom) as lon 
            FROM reportes_espaciales 
            WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography, $3)
        """, lon, lat, radio_metros)
        
    resultados = []
    db_mongo = mongo_client.bichos_db
    
    for reg in registros_pg:
        doc_mongo = await db_mongo.reportes.find_one({"id_reporte": reg['id_reporte']})
        
        # Muestra el estado de la IA si aún no termina, o el bicho si ya fue procesado
        nombre_ia = doc_mongo.get('bicho_ia', 'Analizando...') if doc_mongo else 'Desconocido'
        
        resultados.append({
            "id_reporte": reg['id_reporte'],
            "latitud": reg['lat'],   # <-- CORRECCIÓN: Nombre restaurado para Flutter
            "longitud": reg['lon'],  # <-- CORRECCIÓN: Nombre restaurado para Flutter
            "bicho_ia": nombre_ia  
        })
        
    return {"exito": True, "data": resultados}

@app.get("/api/reportes/bitacora/{id_bitacora}")
async def listar_reportes_por_bitacora(id_bitacora: str, usuario: dict = Depends(verificar_token)):
    uid_usuario = usuario['uid']
    db_mongo = mongo_client.bichos_db
    
    cursor = db_mongo.reportes.find({"uid_usuario": uid_usuario, "id_bitacora": id_bitacora})
    reportes = []
    async for doc in cursor:
        doc['_id'] = str(doc['_id'])
        
        # --- NUEVO: Extraer coordenadas y altura desde PostgreSQL ---
        async with pg_pool.acquire() as conn:
            pg_data = await conn.fetchrow(
                "SELECT ST_Y(geom) as lat, ST_X(geom) as lon, altura, clima FROM reportes_espaciales WHERE id_reporte = $1", 
                doc['id_reporte']
            )
            if pg_data:
                doc['latitud'] = pg_data['lat']
                doc['longitud'] = pg_data['lon']
                doc['altura'] = pg_data['altura']
                doc['clima'] = pg_data['clima']
        reportes.append(doc)
        
    return {"exito": True, "data": reportes}

@app.get("/api/reportes/unitarios")
async def listar_reportes_unitarios(usuario: dict = Depends(verificar_token)):
    uid_usuario = usuario['uid']
    db_mongo = mongo_client.bichos_db
    
    cursor = db_mongo.reportes.find({"uid_usuario": uid_usuario, "id_bitacora": None})
    reportes = []
    async for doc in cursor:
        doc['_id'] = str(doc['_id'])
        
        # --- NUEVO: Extraer coordenadas y altura desde PostgreSQL ---
        async with pg_pool.acquire() as conn:
            pg_data = await conn.fetchrow(
                "SELECT ST_Y(geom) as lat, ST_X(geom) as lon, altura, clima FROM reportes_espaciales WHERE id_reporte = $1", 
                doc['id_reporte']
            )
            if pg_data:
                doc['latitud'] = pg_data['lat']
                doc['longitud'] = pg_data['lon']
                doc['altura'] = pg_data['altura']
                doc['clima'] = pg_data['clima']
                
        reportes.append(doc)
        
    return {"exito": True, "data": reportes}

@app.get("/api/detalle-bicho/{nombre_cientifico}")
async def obtener_detalle_semantico(
    nombre_cientifico: str, 
    usuario: dict = Depends(verificar_token)
):
    # Limpiamos posibles espacios residuales
    nc_limpio = nombre_cientifico.strip()
    
    # SPARQL Blindado: Insensible a mayúsculas y tolerante a campos vacíos
    query_sparql = f"""
        PREFIX : <http://www.semanticweb.org/josed/ontologies/2026/7/untitled-ontology-6/>
        SELECT ?reino ?filo ?clase ?orden ?familia ?genero ?especie ?nombre_comun ?importancia ?indicador ?observacion
        WHERE {{
            ?bicho :Nombre_Cientifico ?nc .
            FILTER(lcase(str(?nc)) = lcase("{nc_limpio}"))
            
            OPTIONAL {{ ?bicho :Reino ?reino }}
            OPTIONAL {{ ?bicho :Filo ?filo }}
            OPTIONAL {{ ?bicho :Clase ?clase }}
            OPTIONAL {{ ?bicho :Orden ?orden }}
            OPTIONAL {{ ?bicho :Familia ?familia }}
            OPTIONAL {{ ?bicho :Genero ?genero }}
            OPTIONAL {{ ?bicho :Especie ?especie }}
            OPTIONAL {{ ?bicho :NombreBicho ?nombre_comun }}
            OPTIONAL {{ ?bicho :Importancia_Ecologica ?importancia }}
            OPTIONAL {{ ?bicho :Indicador_Suelos ?indicador }}
            OPTIONAL {{ ?bicho :Observacion_Suelos ?observacion }}
        }}
        LIMIT 1
    """
    
    from SPARQLWrapper import SPARQLWrapper, JSON
    fuseki_leer = SPARQLWrapper("http://localhost:3030/BDBichos/query")
    fuseki_leer.setQuery(query_sparql)
    fuseki_leer.setReturnFormat(JSON) 
    
    try:
        respuesta = fuseki_leer.query().convert()
        bindings = respuesta.get("results", {}).get("bindings", [])
        
        if bindings:
            datos = bindings[0]
            return {
                "exito": True,
                "nombre_cientifico": nombre_cientifico,
                "reino": datos.get("reino", {}).get("value", "Desconocido"),
                "filo": datos.get("filo", {}).get("value", "Desconocido"),
                "clase": datos.get("clase", {}).get("value", "Desconocida"),
                "orden": datos.get("orden", {}).get("value", "Desconocido"),
                "familia": datos.get("familia", {}).get("value", "Desconocida"),
                "genero": datos.get("genero", {}).get("value", "Desconocido"),
                "especie": datos.get("especie", {}).get("value", "Desconocida"),
                "nombre_comun": datos.get("nombre_comun", {}).get("value", "Desconocido"),
                "importancia": datos.get("importancia", {}).get("value", "Sin especificar"),
                "indicador": datos.get("indicador", {}).get("value", "Sin especificar"),
                "observacion": datos.get("observacion", {}).get("value", "Sin especificar")
            }
        else:
            return {"exito": False, "mensaje": "No hay ficha semántica para este insecto"}
            
    except Exception as e:
        print("--- ERROR EN FASE FUSEKI (LECTURA) ---")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Error consultando la ontología: {str(e)}")
    
@app.delete("/api/reportes/{id_reporte}")
async def eliminar_reporte(id_reporte: str, usuario: dict = Depends(verificar_token)):
    uid_usuario = usuario['uid']
    db_mongo = mongo_client.bichos_db
    
    # 1. Eliminar de MongoDB
    resultado = await db_mongo.reportes.delete_one({"id_reporte": id_reporte, "uid_usuario": uid_usuario})
    if resultado.deleted_count == 0:
        raise HTTPException(status_code=404, detail="Reporte no encontrado o sin permisos")
        
    # 2. Eliminar de PostGIS
    async with pg_pool.acquire() as conn:
        await conn.execute("DELETE FROM reportes_espaciales WHERE id_reporte = $1", id_reporte)
        
    # 3. Eliminar de Fuseki (Borra cualquier relación donde el reporte sea sujeto u objeto)
    query_delete = f"""
        PREFIX : <http://www.semanticweb.org/josed/ontologies/2026/7/untitled-ontology-6/>
        DELETE WHERE {{ :{id_reporte} ?p ?o . }};
        DELETE WHERE {{ ?s ?p :{id_reporte} . }};
    """
    import urllib.request
    import urllib.parse
    url_fuseki = "http://localhost:3030/BDBichos/update"
    datos_post = urllib.parse.urlencode({'update': query_delete}).encode('utf-8')
    req = urllib.request.Request(url_fuseki, data=datos_post)
    urllib.request.urlopen(req)
    
    return {"exito": True, "mensaje": "Reporte eliminado de todas las bases de datos"}


@app.delete("/api/bitacoras/{id_bitacora}")
async def eliminar_bitacora(id_bitacora: str, usuario: dict = Depends(verificar_token)):
    uid_usuario = usuario['uid']
    db_mongo = mongo_client.bichos_db
    
    # 1. Eliminar bitácora de MongoDB
    resultado = await db_mongo.bitacoras.delete_one({"id_bitacora": id_bitacora, "uid_usuario": uid_usuario})
    if resultado.deleted_count == 0:
        raise HTTPException(status_code=404, detail="Bitácora no encontrada")
        
    # 2. Convertir reportes a unitarios en MongoDB
    await db_mongo.reportes.update_many(
        {"id_bitacora": id_bitacora}, 
        {"$set": {"id_bitacora": None}}
    )
    
    # 3. Convertir reportes a unitarios en PostGIS
    async with pg_pool.acquire() as conn:
        await conn.execute("UPDATE reportes_espaciales SET id_bitacora = NULL WHERE id_bitacora = $1", id_bitacora)
        
    # 4. Eliminar relación de bitácora en Fuseki
    query_delete = f"""
        PREFIX : <http://www.semanticweb.org/josed/ontologies/2026/7/untitled-ontology-6/>
        DELETE WHERE {{ ?reporte :pertenece_a_bitacora :{id_bitacora} . }}
    """
    import urllib.request
    import urllib.parse
    url_fuseki = "http://localhost:3030/BDBichos/update"
    datos_post = urllib.parse.urlencode({'update': query_delete}).encode('utf-8')
    req = urllib.request.Request(url_fuseki, data=datos_post)
    urllib.request.urlopen(req)
    
    return {"exito": True, "mensaje": "Bitácora eliminada. Los reportes ahora son unitarios."}

@app.put("/api/bitacoras/{id_bitacora}")
async def actualizar_bitacora(
    id_bitacora: str,
    nombre: str = Form(...),
    descripcion: Optional[str] = Form(""),
    usuario: dict = Depends(verificar_token)
):
    uid_usuario = usuario['uid']
    db_mongo = mongo_client.bichos_db
    
    resultado = await db_mongo.bitacoras.update_one(
        {"id_bitacora": id_bitacora, "uid_usuario": uid_usuario},
        {"$set": {"nombre": nombre, "descripcion": descripcion}}
    )
    
    if resultado.matched_count == 0:
        raise HTTPException(status_code=404, detail="Bitácora no encontrada")
        
    return {"exito": True, "mensaje": "Bitácora actualizada"}

@app.put("/api/reportes/{id_reporte}")
async def actualizar_reporte(
    id_reporte: str,
    clima: str = Form(""),
    nombre_sitio: str = Form(""),
    nombre_comun: str = Form(""),
    descripcion: str = Form(""),
    id_bitacora: Optional[str] = Form(None),
    usuario: dict = Depends(verificar_token)
):
    uid_usuario = usuario['uid']
    db_mongo = mongo_client.bichos_db

    # 1. Actualizar MongoDB
    resultado = await db_mongo.reportes.update_one(
        {"id_reporte": id_reporte, "uid_usuario": uid_usuario},
        {"$set": {
            "nombre_sitio": nombre_sitio,
            "nombre_comun": nombre_comun,
            "descripcion": descripcion,
            "id_bitacora": id_bitacora,
            "clima": clima
        }}
    )
    if resultado.matched_count == 0:
        raise HTTPException(status_code=404, detail="Reporte no encontrado")

    # 2. Actualizar PostgreSQL
    async with pg_pool.acquire() as conn:
        await conn.execute('''
            UPDATE reportes_espaciales
            SET clima = $1, id_bitacora = $2
            WHERE id_reporte = $3
        ''', clima, id_bitacora, id_reporte)

    # 3. Actualizar Fuseki (Eliminar propiedades viejas e insertar nuevas)
    desc_limpia = descripcion.replace('"', "'").replace('\n', ' ')
    sitio_limpio = nombre_sitio.replace('"', "'")
    comun_limpio = nombre_comun.replace('"', "'")

    query_update = f"""
        PREFIX : <http://www.semanticweb.org/josed/ontologies/2026/7/untitled-ontology-6/>
        DELETE {{
            :{id_reporte} :Nombre_Sitio_Muestra ?sitio ;
                          :NombreComun ?comun ;
                          :Descripcion ?desc ;
                          :pertenece_a_bitacora ?bitacora .
        }}
        WHERE {{
            OPTIONAL {{ :{id_reporte} :Nombre_Sitio_Muestra ?sitio }}
            OPTIONAL {{ :{id_reporte} :NombreComun ?comun }}
            OPTIONAL {{ :{id_reporte} :Descripcion ?desc }}
            OPTIONAL {{ :{id_reporte} :pertenece_a_bitacora ?bitacora }}
        }};
        INSERT DATA {{
            :{id_reporte} :Nombre_Sitio_Muestra "{sitio_limpio}" ;
                          :NombreComun "{comun_limpio}" ;
                          :Descripcion "{desc_limpia}" .
            {f":{id_reporte} :pertenece_a_bitacora :{id_bitacora} ." if id_bitacora else ""}
        }}
    """
    
    import urllib.request
    import urllib.parse
    url_fuseki = "http://localhost:3030/BDBichos/update"
    datos_post = urllib.parse.urlencode({'update': query_update}).encode('utf-8')
    req = urllib.request.Request(url_fuseki, data=datos_post)
    urllib.request.urlopen(req)

    return {"exito": True, "mensaje": "Reporte actualizado"}