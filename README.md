# Servicio de Inventario y Carrito — Equipo 4

Backend FastAPI para catálogo de productos, inventario y carrito persistente del Marketplace USC. Usa Supabase para Postgres, autenticación y almacenamiento de imágenes.

## Preparación de Supabase

1. Crea un proyecto Supabase y abre **SQL Editor**.
2. Ejecuta el contenido completo de `schema.sql`. Esto crea tablas, categorías, funciones transaccionales, políticas RLS y el bucket público `productos` (límite 2 MB, JPG/PNG).
3. En Supabase, copia **Project URL** y la clave **service_role**. La clave de servicio se usa solo en el backend y nunca en el frontend.
4. La identidad del vendedor se toma del `sub` del JWT de Supabase; por tanto `vendedor_id` de los productos coincide con el UUID del usuario vendedor autenticado. El carrito usa la identidad autenticada y no acepta un `usuario_id` arbitrario.

## Ejecución local

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
```

Completa `.env` con `SUPABASE_URL`, `SUPABASE_KEY` (service_role), `CORS_ORIGINS` y un secreto aleatorio para `PAYMENT_WEBHOOK_SECRET`. Luego inicia:

```powershell
uvicorn main:app --reload
```

Swagger: `http://127.0.0.1:8000/docs`; estado: `http://127.0.0.1:8000/health`.
Los endpoints privados requieren `Authorization: Bearer <access_token>` de Supabase Auth. El endpoint de confirmación de pago recibe `X-Payment-Secret` desde el servicio de pagos.

## Endpoints

| Método | Ruta | Uso |
|---|---|---|
| GET | `/api/categorias` | Categorías activas |
| GET | `/api/productos` | Catálogo; filtros opcionales `vendedor_id`, `categoria_id` |
| GET | `/api/productos/{producto_id}` | Detalle de producto activo |
| POST | `/api/productos` | Crear producto para el vendedor autenticado |
| PATCH/DELETE | `/api/productos/{producto_id}` | Actualizar / desactivar producto propio |
| POST | `/api/productos/imagen` | Cargar JPG/PNG menor a 2 MB; devuelve `imagen_url` |
| GET | `/api/inventario/stock-bajo` | Productos propios con stock menor o igual al mínimo |
| GET | `/api/carrito` | Carrito propio agrupado por vendedor, con totales |
| POST | `/api/carrito/items` | Añadir `{ "producto_id": "UUID", "cantidad": 1 }` |
| PATCH/DELETE | `/api/carrito/items/{producto_id}` | Cambiar cantidad / quitar ítem propio |
| POST | `/api/inventario/reservar` | Reservar `items` con `referencia_id` por 15 minutos |
| POST | `/api/inventario/confirmar/{referencia_id}` | Confirmar pago; requiere `X-Payment-Secret` |

Los totales se calculan por vendedor: IVA de 19% sobre productos y envío gratis cuando el subtotal supera COP 200.000; de lo contrario, COP 15.000. La reserva bloquea disponibilidad de forma transaccional y la confirmación descuenta el stock y registra la auditoría.

## Despliegue en Render

1. Sube este proyecto a un repositorio Git y crea un **Web Service** conectado a ese repositorio (o usa `render.yaml`).
2. Configura las variables `SUPABASE_URL`, `SUPABASE_KEY`, `CORS_ORIGINS` (dominio del frontend) y `PAYMENT_WEBHOOK_SECRET` en Render.
3. El comando de inicio es `uvicorn main:app --host 0.0.0.0 --port $PORT`; Render instala `requirements.txt`.
4. Al desplegar, verifica `/health` y `/docs`; configura en el servicio de pagos la URL `POST /api/inventario/confirmar/{referencia_id}` y el encabezado secreto acordado.

No se puede crear la instancia Supabase, configurar secretos reales ni publicar el servicio sin acceso a las cuentas del equipo. No compartas la clave service_role en el repositorio, frontend o capturas.
