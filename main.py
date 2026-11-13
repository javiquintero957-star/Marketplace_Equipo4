"""API de catálogo, inventario y carrito del Marketplace USC."""
from __future__ import annotations

import logging
from decimal import Decimal
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4
from urllib.parse import urlparse

from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, UploadFile, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field, HttpUrl
from pydantic_settings import BaseSettings, SettingsConfigDict
from postgrest.exceptions import APIError
from supabase import Client, create_client


class Settings(BaseSettings):
    supabase_url: str
    supabase_key: str
    cors_origins: str = "http://localhost:3000"
    payment_webhook_secret: str | None = None
    # Ruta absoluta para que Uvicorn encuentre siempre el .env junto a este main.py,
    # incluso si se inicia desde otra carpeta.
    model_config = SettingsConfigDict(env_file=Path(__file__).resolve().parent / ".env", extra="ignore")


settings = Settings()
supabase: Client = create_client(settings.supabase_url, settings.supabase_key)
app = FastAPI(title="Servicio de Inventario y Carrito - Equipo 4", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.cors_origins.split(",") if o.strip()],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "X-Payment-Secret"],
)
bearer = HTTPBearer(auto_error=False)


def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> str:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(status_code=401, detail="Se requiere iniciar sesión")
    try:
        user = supabase.auth.get_user(credentials.credentials).user
        if user is None:
            raise ValueError("Token sin usuario")
        return str(user.id)
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Token inválido o vencido") from exc


class ProductoCreate(BaseModel):
    categoria_id: UUID | None = None
    sku: str = Field(min_length=1, max_length=60)
    nombre: str = Field(min_length=1, max_length=255)
    descripcion: str | None = None
    precio: Decimal = Field(gt=0, max_digits=14, decimal_places=2)
    imagen_url: HttpUrl | None = None
    stock: int = Field(ge=0)
    stock_minimo_alerta: int = Field(default=5, ge=0)


class ProductoUpdate(BaseModel):
    categoria_id: UUID | None = None
    sku: str | None = Field(default=None, min_length=1, max_length=60)
    nombre: str | None = Field(default=None, min_length=1, max_length=255)
    descripcion: str | None = None
    precio: Decimal | None = Field(default=None, gt=0, max_digits=14, decimal_places=2)
    imagen_url: HttpUrl | None = None
    stock: int | None = Field(default=None, ge=0)
    stock_minimo_alerta: int | None = Field(default=None, ge=0)
    activo: bool | None = None


class CarritoItem(BaseModel):
    producto_id: UUID
    cantidad: int = Field(gt=0)


class CambioCantidad(BaseModel):
    cantidad: int = Field(gt=0)


class Reserva(BaseModel):
    items: list[CarritoItem] = Field(min_length=1)
    referencia_id: str = Field(min_length=1, max_length=100)


def rows(query: Any) -> list[dict[str, Any]]:
    try:
        return query.execute().data or []
    except Exception as exc:
        # El detalle y traceback quedan solo en el log del servidor, no en la respuesta HTTP.
        logging.getLogger("uvicorn.error").exception("Error al consultar Supabase")
        raise HTTPException(status_code=400, detail="No se pudo completar la operación") from exc


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/debug/supabase")
def diagnosticar_supabase() -> dict[str, Any]:
    """Prueba temporal de PostgREST sin devolver URL, clave ni mensaje sensible."""
    config = {
        "SUPABASE_URL_cargada": bool(settings.supabase_url.strip()),
        "SUPABASE_KEY_cargada": bool(settings.supabase_key.strip()),
        "host_usado_por_cliente": urlparse(settings.supabase_url).hostname,
    }
    try:
        supabase.table("inv_categorias").select("id").limit(1).execute()
        return {"conexion": True, "configuracion": config, "error_tipo": None}
    except Exception as exc:
        error_message = None
        error_code = None
        if isinstance(exc, APIError):
            error_message = exc.message
            error_code = exc.code
            # Evita reflejar credenciales incluso si el servidor las incluyera en el mensaje.
            for secret in (settings.supabase_key, settings.payment_webhook_secret):
                if secret:
                    if error_message:
                        error_message = error_message.replace(secret, "[REDACTED]")
                    if error_code:
                        error_code = error_code.replace(secret, "[REDACTED]")
        # No imprimir la excepción completa: algunos clientes HTTP pueden incluir
        # cabeceras o credenciales dentro del texto de la excepción.
        logging.getLogger("uvicorn.error").error(
            "Diagnóstico temporal de Supabase falló (tipo=%s)", type(exc).__name__
        )
        return {
            "conexion": False,
            "configuracion": config,
            "error_tipo": type(exc).__name__,
            "error_message": error_message,
            "error_code": error_code,
        }


@app.get("/api/categorias")
def listar_categorias():
    return rows(supabase.table("inv_categorias").select("*").eq("activo", True).order("nombre"))


@app.get("/api/productos")
def listar_productos(vendedor_id: UUID | None = None, categoria_id: UUID | None = None):
    query = supabase.table("inv_productos").select("*, inv_categorias(nombre)").eq("activo", True)
    if vendedor_id:
        query = query.eq("vendedor_id", str(vendedor_id))
    if categoria_id:
        query = query.eq("categoria_id", str(categoria_id))
    return rows(query.order("creado_en", desc=True))


@app.get("/api/inventario/stock-bajo")
def productos_stock_bajo(vendedor: str = Depends(current_user)):
    productos = rows(supabase.table("inv_productos").select("id, sku, nombre, stock, stock_minimo_alerta").eq("vendedor_id", vendedor).eq("activo", True))
    return [p for p in productos if p["stock"] <= p["stock_minimo_alerta"]]


@app.get("/api/productos/{producto_id}")
def obtener_producto(producto_id: UUID):
    result = rows(supabase.table("inv_productos").select("*, inv_categorias(nombre)").eq("id", str(producto_id)).eq("activo", True))
    if not result:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return result[0]


@app.post("/api/productos", status_code=status.HTTP_201_CREATED)
def crear_producto(producto: ProductoCreate, vendedor_id: str = Depends(current_user)):
    data = producto.model_dump(mode="json")
    data["vendedor_id"] = vendedor_id
    result = rows(supabase.table("inv_productos").insert(data))
    if not result:
        raise HTTPException(status_code=400, detail="No se pudo crear el producto")
    if producto.stock:
        rows(supabase.table("inv_movimientos_stock").insert({"producto_id": result[0]["id"], "tipo": "ENTRADA", "cantidad": producto.stock, "stock_anterior": 0, "stock_resultante": producto.stock, "nota": "Stock inicial"}))
    return result[0]


@app.patch("/api/productos/{producto_id}")
def actualizar_producto(producto_id: UUID, cambios: ProductoUpdate, vendedor_id: str = Depends(current_user)):
    data = cambios.model_dump(mode="json", exclude_unset=True)
    actual = rows(supabase.table("inv_productos").select("id, stock").eq("id", str(producto_id)).eq("vendedor_id", vendedor_id))
    if not actual:
        raise HTTPException(status_code=404, detail="Producto no encontrado para este vendedor")
    if "stock" in data and data["stock"] != actual[0]["stock"]:
        anterior, nuevo = actual[0]["stock"], data["stock"]
        rows(supabase.table("inv_movimientos_stock").insert({"producto_id": str(producto_id), "tipo": "AJUSTE", "cantidad": nuevo - anterior, "stock_anterior": anterior, "stock_resultante": nuevo, "nota": "Ajuste manual"}))
    result = rows(supabase.table("inv_productos").update(data).eq("id", str(producto_id)).eq("vendedor_id", vendedor_id))
    return result[0] if result else {"message": "Actualizado"}


@app.delete("/api/productos/{producto_id}", status_code=status.HTTP_204_NO_CONTENT)
def eliminar_producto(producto_id: UUID, vendedor_id: str = Depends(current_user)):
    result = rows(supabase.table("inv_productos").update({"activo": False}).eq("id", str(producto_id)).eq("vendedor_id", vendedor_id))
    if not result:
        raise HTTPException(status_code=404, detail="Producto no encontrado para este vendedor")


@app.post("/api/productos/imagen")
async def subir_imagen(file: UploadFile = File(...), usuario_id: str = Depends(current_user)):
    tipos = {"image/jpeg": ("jpg", b"\xff\xd8\xff"), "image/png": ("png", b"\x89PNG\r\n\x1a\n")}
    if file.content_type not in tipos:
        raise HTTPException(status_code=415, detail="Solo se permiten imágenes JPG o PNG")
    contenido = await file.read(2 * 1024 * 1024 + 1)
    if len(contenido) > 2 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="La imagen debe pesar menos de 2 MB")
    extension, firma = tipos[file.content_type]
    if not contenido.startswith(firma):
        raise HTTPException(status_code=415, detail="El contenido no coincide con el formato declarado")
    ruta = f"{usuario_id}/{uuid4()}.{extension}"
    try:
        bucket = supabase.storage.from_("productos")
        bucket.upload(ruta, contenido, {"content-type": file.content_type, "upsert": "false"})
        return {"imagen_url": bucket.get_public_url(ruta)}
    except Exception as exc:
        raise HTTPException(status_code=502, detail="No se pudo subir la imagen; verifica el bucket 'productos'") from exc
    finally:
        await file.close()


@app.get("/api/carrito")
def ver_carrito(usuario_id: str = Depends(current_user)):
    items = rows(supabase.table("inv_carrito_items").select("cantidad, inv_productos(id, vendedor_id, nombre, precio, stock, imagen_url, activo)").eq("usuario_id", usuario_id))
    vendedores: dict[str, list[dict[str, Any]]] = {}
    for item in items:
        producto = item["inv_productos"]
        if not producto or not producto["activo"]:
            continue
        subtotal = Decimal(str(producto["precio"])) * item["cantidad"]
        vendedores.setdefault(producto["vendedor_id"], []).append({**producto, "cantidad": item["cantidad"], "subtotal": float(subtotal)})
    grupos = []
    for vendedor, lineas in vendedores.items():
        subtotal = sum((Decimal(str(linea["subtotal"])) for linea in lineas), Decimal(0))
        envio = Decimal(0) if subtotal > 200000 else Decimal(15000)
        iva = subtotal * Decimal("0.19")
        grupos.append({"vendedor_id": vendedor, "items": lineas, "subtotal": float(subtotal), "iva": float(iva), "envio": float(envio), "total": float(subtotal + iva + envio)})
    return {"grupos": grupos, "total": round(sum(g["total"] for g in grupos), 2)}


@app.post("/api/carrito/items", status_code=status.HTTP_201_CREATED)
def agregar_al_carrito(item: CarritoItem, usuario_id: str = Depends(current_user)):
    product = rows(supabase.table("inv_productos").select("id, stock, activo").eq("id", str(item.producto_id)))
    if not product or not product[0]["activo"]:
        raise HTTPException(status_code=404, detail="Producto no disponible")
    current = rows(supabase.table("inv_carrito_items").select("cantidad").eq("usuario_id", usuario_id).eq("producto_id", str(item.producto_id)))
    cantidad = item.cantidad + (current[0]["cantidad"] if current else 0)
    if cantidad > product[0]["stock"]:
        raise HTTPException(status_code=409, detail="La cantidad supera el stock disponible")
    payload = {"usuario_id": usuario_id, "producto_id": str(item.producto_id), "cantidad": cantidad}
    result = rows(supabase.table("inv_carrito_items").upsert(payload, on_conflict="usuario_id,producto_id"))
    return result[0] if result else payload


@app.patch("/api/carrito/items/{producto_id}")
def cambiar_cantidad(producto_id: UUID, cambio: CambioCantidad, usuario_id: str = Depends(current_user)):
    product = rows(supabase.table("inv_productos").select("stock, activo").eq("id", str(producto_id)))
    if not product or not product[0]["activo"] or cambio.cantidad > product[0]["stock"]:
        raise HTTPException(status_code=409, detail="Cantidad superior al stock disponible")
    result = rows(supabase.table("inv_carrito_items").update({"cantidad": cambio.cantidad}).eq("usuario_id", usuario_id).eq("producto_id", str(producto_id)))
    if not result:
        raise HTTPException(status_code=404, detail="Ítem no encontrado")
    return result[0]


@app.delete("/api/carrito/items/{producto_id}", status_code=status.HTTP_204_NO_CONTENT)
def quitar_del_carrito(producto_id: UUID, usuario_id: str = Depends(current_user)):
    rows(supabase.table("inv_carrito_items").delete().eq("usuario_id", usuario_id).eq("producto_id", str(producto_id)))


@app.post("/api/inventario/reservar")
def reservar_stock(reserva: Reserva, _: str = Depends(current_user)):
    # No permitir cantidades repetidas del mismo producto: SQL usa una clave única por reserva/producto.
    if len({item.producto_id for item in reserva.items}) != len(reserva.items):
        raise HTTPException(status_code=422, detail="Consolida cada producto en una sola línea")
    try:
        result = supabase.rpc("inv_reservar_stock", {"p_items": [i.model_dump(mode="json") for i in reserva.items], "p_referencia_id": reserva.referencia_id}).execute()
        return result.data
    except Exception as exc:
        raise HTTPException(status_code=409, detail="No hay stock suficiente o falló la reserva") from exc


@app.post("/api/inventario/confirmar/{referencia_id}")
def confirmar_reserva(referencia_id: str, x_payment_secret: str | None = Header(default=None)):
    if not settings.payment_webhook_secret or x_payment_secret != settings.payment_webhook_secret:
        raise HTTPException(status_code=401, detail="Webhook de pago no autorizado")
    try:
        return supabase.rpc("inv_confirmar_reserva", {"p_referencia_id": referencia_id}).execute().data
    except Exception as exc:
        raise HTTPException(status_code=409, detail="La reserva no existe o expiró") from exc
