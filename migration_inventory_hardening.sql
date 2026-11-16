-- Endurece permisos, reserva y auditoría sobre schema.sql y
-- migration_checkout_inventory.sql. Ejecutar manualmente tras revisar.
-- No elimina filas ni tablas. Repetible en la estructura definida por ambas migraciones.
BEGIN;

-- Cierra primero las firmas antiguas que permiten omitir identidad o verificación.
REVOKE ALL ON FUNCTION public.inv_reservar_stock(JSONB, TEXT)
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.inv_confirmar_reserva(TEXT)
    FROM PUBLIC, anon, authenticated, service_role;

-- ALTER FUNCTION OWNER requires a trusted migration role; fail before DDL otherwise.
DO $$
DECLARE superuser_actor BOOLEAN;
BEGIN
    SELECT rolsuper INTO superuser_actor FROM pg_catalog.pg_roles
     WHERE rolname = current_user;
    IF current_user <> 'postgres' AND NOT COALESCE(superuser_actor, FALSE) THEN
        RAISE EXCEPTION 'Run migration_inventory_hardening.sql as postgres or a superuser';
    END IF;
END;
$$;

-- Recreate these two functions so already-installed versions also receive the
-- hardened path and qualified relations (CREATE OR REPLACE alone in the earlier
-- migration would not update installations that already ran its old contents).
CREATE OR REPLACE FUNCTION public.inv_crear_producto(p_producto JSONB, p_vendedor_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    producto public.inv_productos%ROWTYPE;
    stock_inicial INTEGER := COALESCE((p_producto->>'stock')::INTEGER, 0);
BEGIN
    IF stock_inicial < 0 THEN RAISE EXCEPTION 'El stock no puede ser negativo'; END IF;
    INSERT INTO public.inv_productos(categoria_id, vendedor_id, sku, nombre, descripcion,
                                     precio, imagen_url, stock, stock_minimo_alerta)
    VALUES (NULLIF(p_producto->>'categoria_id', '')::UUID, p_vendedor_id,
            p_producto->>'sku', p_producto->>'nombre', p_producto->>'descripcion',
            (p_producto->>'precio')::NUMERIC, p_producto->>'imagen_url', stock_inicial,
            COALESCE((p_producto->>'stock_minimo_alerta')::INTEGER, 5))
    RETURNING * INTO producto;
    IF stock_inicial > 0 THEN
        INSERT INTO public.inv_movimientos_stock(producto_id, tipo, cantidad,
                                                 stock_anterior, stock_resultante, nota)
        VALUES (producto.id, 'ENTRADA', stock_inicial, 0, stock_inicial, 'Stock inicial');
    END IF;
    RETURN pg_catalog.to_jsonb(producto);
END;
$$;

CREATE OR REPLACE FUNCTION public.inv_ajustar_stock(
    p_producto_id UUID, p_vendedor_id UUID, p_tipo TEXT,
    p_cantidad INTEGER, p_nota TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE actual INTEGER; nuevo INTEGER; reservado INTEGER;
BEGIN
    IF p_tipo NOT IN ('ENTRADA', 'AJUSTE') OR p_cantidad = 0
       OR (p_tipo = 'ENTRADA' AND p_cantidad < 0) THEN
        RAISE EXCEPTION 'Movimiento inválido';
    END IF;
    SELECT stock INTO actual FROM public.inv_productos
     WHERE id = p_producto_id AND vendedor_id = p_vendedor_id AND activo FOR UPDATE;
    IF actual IS NULL THEN RAISE EXCEPTION 'Producto no encontrado'; END IF;
    nuevo := actual + p_cantidad;
    IF nuevo < 0 THEN RAISE EXCEPTION 'El stock no puede ser negativo'; END IF;
    SELECT COALESCE(pg_catalog.sum(cantidad), 0) INTO reservado
      FROM public.inv_reservas_stock
     WHERE producto_id = p_producto_id AND NOT confirmada AND expira_en > pg_catalog.now();
    IF nuevo < reservado THEN RAISE EXCEPTION 'El nuevo stock es menor que las unidades reservadas'; END IF;
    UPDATE public.inv_productos SET stock = nuevo, actualizado_en = pg_catalog.now()
     WHERE id = p_producto_id;
    INSERT INTO public.inv_movimientos_stock(producto_id, tipo, cantidad,
                                             stock_anterior, stock_resultante, nota)
    VALUES (p_producto_id, p_tipo, p_cantidad, actual, nuevo, p_nota);
    RETURN pg_catalog.jsonb_build_object('producto_id', p_producto_id, 'tipo', p_tipo,
        'cantidad', p_cantidad, 'stock_anterior', actual, 'stock_resultante', nuevo);
END;
$$;

-- Solo lectura pública en productos. Los vendedores no escriben con JWT directo;
-- el backend obtiene su ID de supabase.auth.get_user y usa funciones con service_role.
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT ON TABLE public.inv_categorias TO anon, authenticated, service_role;
ALTER TABLE public.inv_productos ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE p RECORD;
BEGIN
    FOR p IN SELECT policyname FROM pg_policies
              WHERE schemaname = 'public' AND tablename = 'inv_productos'
    LOOP
        EXECUTE format('DROP POLICY %I ON public.inv_productos', p.policyname);
    END LOOP;
END;
$$;

CREATE POLICY inv_prod_read ON public.inv_productos
    FOR SELECT TO anon, authenticated USING (activo);

REVOKE ALL ON TABLE public.inv_productos FROM PUBLIC, anon, authenticated, service_role;
REVOKE INSERT (id, vendedor_id, categoria_id, sku, nombre, descripcion, precio,
               imagen_url, stock, stock_minimo_alerta, activo, creado_en, actualizado_en)
    ON TABLE public.inv_productos FROM PUBLIC, anon, authenticated, service_role;
REVOKE UPDATE (stock) ON TABLE public.inv_productos
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE DELETE ON TABLE public.inv_productos FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.inv_productos TO anon, authenticated, service_role;
-- PATCH conserva edición de metadatos y desactivación; stock queda fuera.
GRANT UPDATE (categoria_id, sku, nombre, descripcion, precio, imagen_url,
              stock_minimo_alerta, activo)
    ON TABLE public.inv_productos TO service_role;

-- Las escrituras de auditoría/reservas se ejecutan dentro de RPC SECURITY DEFINER.
-- service_role conserva SELECT para endpoints de auditoría y validación.
REVOKE ALL ON TABLE public.inv_movimientos_stock
    FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.inv_movimientos_stock TO service_role;
REVOKE ALL ON TABLE public.inv_reservas_stock
    FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.inv_reservas_stock TO service_role;
CREATE INDEX IF NOT EXISTS idx_inv_movimientos_producto_creado
    ON public.inv_movimientos_stock(producto_id, creado_en DESC);
CREATE INDEX IF NOT EXISTS idx_inv_reservas_producto_activa
    ON public.inv_reservas_stock(producto_id, expira_en) WHERE NOT confirmada;

-- Evita borrar el historial si un producto se elimina físicamente desde SQL.
DO $$
DECLARE fk RECORD;
        has_restrict BOOLEAN := FALSE;
BEGIN
    FOR fk IN SELECT conname, confdeltype FROM pg_constraint
               WHERE conrelid = 'public.inv_movimientos_stock'::regclass
                 AND confrelid = 'public.inv_productos'::regclass
                 AND contype = 'f'
    LOOP
        IF fk.confdeltype = 'r' THEN
            has_restrict := TRUE;
        ELSE
            EXECUTE format('ALTER TABLE public.inv_movimientos_stock DROP CONSTRAINT %I', fk.conname);
        END IF;
    END LOOP;
    IF NOT has_restrict THEN
        ALTER TABLE public.inv_movimientos_stock
            ADD CONSTRAINT inv_movimientos_stock_producto_restrict_fkey
            FOREIGN KEY (producto_id) REFERENCES public.inv_productos(id) ON DELETE RESTRICT;
    END IF;
END;
$$;

-- Las escrituras del carrito pasan por RPC para adquirir el lock de usuario
-- antes de leer o bloquear filas. Así la reserva no sufre carreras por nuevas filas.
REVOKE ALL ON TABLE public.inv_carrito_items
    FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.inv_carrito_items TO service_role;

CREATE OR REPLACE FUNCTION public.inv_carrito_agregar(
    p_usuario_id UUID, p_producto_id UUID, p_cantidad INTEGER
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE actual INTEGER; reservado INTEGER; en_carrito INTEGER; nuevo INTEGER; resultado JSONB;
BEGIN
    IF p_usuario_id IS NULL OR p_cantidad <= 0 THEN RAISE EXCEPTION 'Datos inválidos'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('cart:' || p_usuario_id::TEXT, 0));
    SELECT stock INTO actual FROM public.inv_productos
     WHERE id = p_producto_id AND activo FOR UPDATE;
    IF actual IS NULL THEN RAISE EXCEPTION 'Producto no disponible'; END IF;
    SELECT COALESCE(sum(cantidad), 0) INTO reservado FROM public.inv_reservas_stock
     WHERE producto_id = p_producto_id AND NOT confirmada AND expira_en > now();
    SELECT cantidad INTO en_carrito FROM public.inv_carrito_items
     WHERE usuario_id = p_usuario_id AND producto_id = p_producto_id;
    nuevo := COALESCE(en_carrito, 0) + p_cantidad;
    IF nuevo > actual - reservado THEN RAISE EXCEPTION 'Stock insuficiente'; END IF;
    INSERT INTO public.inv_carrito_items AS carrito(usuario_id, producto_id, cantidad)
    VALUES (p_usuario_id, p_producto_id, nuevo)
    ON CONFLICT (usuario_id, producto_id) DO UPDATE SET cantidad = EXCLUDED.cantidad,
        actualizado_en = now()
    RETURNING to_jsonb(carrito) INTO resultado;
    RETURN resultado;
END;
$$;

CREATE OR REPLACE FUNCTION public.inv_carrito_cambiar(
    p_usuario_id UUID, p_producto_id UUID, p_cantidad INTEGER
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE actual INTEGER; reservado INTEGER; resultado JSONB;
BEGIN
    IF p_usuario_id IS NULL OR p_cantidad <= 0 THEN RAISE EXCEPTION 'Datos inválidos'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('cart:' || p_usuario_id::TEXT, 0));
    SELECT stock INTO actual FROM public.inv_productos
     WHERE id = p_producto_id AND activo FOR UPDATE;
    IF actual IS NULL THEN RAISE EXCEPTION 'Producto no disponible'; END IF;
    SELECT COALESCE(sum(cantidad), 0) INTO reservado FROM public.inv_reservas_stock
     WHERE producto_id = p_producto_id AND NOT confirmada AND expira_en > now();
    IF p_cantidad > actual - reservado THEN RAISE EXCEPTION 'Stock insuficiente'; END IF;
    UPDATE public.inv_carrito_items AS carrito SET cantidad = p_cantidad, actualizado_en = now()
     WHERE usuario_id = p_usuario_id AND producto_id = p_producto_id
     RETURNING to_jsonb(carrito) INTO resultado;
    IF resultado IS NULL THEN RAISE EXCEPTION 'Ítem no encontrado'; END IF;
    RETURN resultado;
END;
$$;

CREATE OR REPLACE FUNCTION public.inv_carrito_quitar(p_usuario_id UUID, p_producto_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('cart:' || p_usuario_id::TEXT, 0));
    DELETE FROM public.inv_carrito_items WHERE usuario_id = p_usuario_id AND producto_id = p_producto_id;
    RETURN jsonb_build_object('eliminado', FOUND);
END;
$$;

CREATE OR REPLACE FUNCTION public.inv_carrito_vaciar(p_usuario_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE total INTEGER;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('cart:' || p_usuario_id::TEXT, 0));
    DELETE FROM public.inv_carrito_items WHERE usuario_id = p_usuario_id;
    GET DIAGNOSTICS total = ROW_COUNT;
    RETURN jsonb_build_object('eliminados', total);
END;
$$;

REVOKE ALL ON FUNCTION public.inv_carrito_agregar(UUID, UUID, INTEGER)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_carrito_cambiar(UUID, UUID, INTEGER)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_carrito_quitar(UUID, UUID)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_carrito_vaciar(UUID)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inv_carrito_agregar(UUID, UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_carrito_cambiar(UUID, UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_carrito_quitar(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_carrito_vaciar(UUID) TO service_role;

-- Idempotencia futura. No se concede acceso a la tabla ni a la RPC: solo se
-- habilitarán después de integrar una verificación real de pago.
CREATE TABLE IF NOT EXISTS public.inv_confirmaciones_pago (
    referencia_id VARCHAR(100) PRIMARY KEY,
    evento_pago_id VARCHAR(200) NOT NULL UNIQUE,
    usuario_id UUID NOT NULL,
    confirmado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    resultado JSONB NOT NULL
);
ALTER TABLE public.inv_confirmaciones_pago ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.inv_confirmaciones_pago
    FROM PUBLIC, anon, authenticated, service_role;

-- Reserva exacta del carrito completo. Orden global de locks:
-- referencia (advisory), carrito por producto_id, luego productos por id.
CREATE OR REPLACE FUNCTION public.inv_reservar_stock(
    p_items JSONB,
    p_referencia_id TEXT,
    p_usuario_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    item JSONB;
    pid UUID;
    qty INTEGER;
    cart_qty INTEGER;
    actual INTEGER;
    reservadas INTEGER;
    expiracion TIMESTAMPTZ := now() + interval '15 minutes';
    cantidad_items INTEGER;
    cantidad_carrito INTEGER;
BEGIN
    IF p_usuario_id IS NULL OR p_referencia_id IS NULL OR btrim(p_referencia_id) = '' THEN
        RAISE EXCEPTION 'Usuario o referencia inválidos';
    END IF;
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'La reserva requiere productos';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(p_referencia_id, 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('cart:' || p_usuario_id::TEXT, 0));
    IF EXISTS (SELECT 1 FROM public.inv_reservas_stock WHERE referencia_id = p_referencia_id) THEN
        RAISE EXCEPTION 'La referencia ya tiene reserva';
    END IF;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_items) AS e(value)
         GROUP BY (value->>'producto_id')::UUID
        HAVING count(*) > 1
    ) THEN RAISE EXCEPTION 'Producto repetido'; END IF;

    -- Bloquea todas las filas del carrito (incluidas las omitidas del payload).
    PERFORM 1 FROM public.inv_carrito_items
     WHERE usuario_id = p_usuario_id
     ORDER BY producto_id
     FOR UPDATE;

    SELECT count(*) INTO cantidad_items FROM jsonb_array_elements(p_items);
    SELECT count(*) INTO cantidad_carrito FROM public.inv_carrito_items WHERE usuario_id = p_usuario_id;
    IF cantidad_items <> cantidad_carrito
       OR EXISTS (
           SELECT (value->>'producto_id')::UUID AS producto_id,
                  (value->>'cantidad')::INTEGER AS cantidad
             FROM jsonb_array_elements(p_items) AS e(value)
           EXCEPT
           SELECT producto_id, cantidad FROM public.inv_carrito_items WHERE usuario_id = p_usuario_id
       )
       OR EXISTS (
           SELECT producto_id, cantidad FROM public.inv_carrito_items WHERE usuario_id = p_usuario_id
           EXCEPT
           SELECT (value->>'producto_id')::UUID,
                  (value->>'cantidad')::INTEGER
             FROM jsonb_array_elements(p_items) AS e(value)
       ) THEN
        RAISE EXCEPTION 'La reserva debe coincidir exactamente con todo el carrito';
    END IF;

    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS e(value)
                WHERE (value->>'cantidad')::INTEGER <= 0) THEN
        RAISE EXCEPTION 'Cantidad inválida';
    END IF;

    SELECT count(*) INTO cantidad_carrito
      FROM public.inv_productos p
      JOIN (SELECT (value->>'producto_id')::UUID AS id
              FROM jsonb_array_elements(p_items) AS e(value)) i ON i.id = p.id
     WHERE p.activo;
    IF cantidad_carrito <> cantidad_items THEN
        RAISE EXCEPTION 'Producto no disponible';
    END IF;

    -- Bloquea todo el conjunto en orden determinista antes de calcular disponibilidad.
    PERFORM p.id FROM public.inv_productos p
      JOIN (SELECT (value->>'producto_id')::UUID AS id
              FROM jsonb_array_elements(p_items) AS e(value)) i ON i.id = p.id
     ORDER BY p.id
     FOR UPDATE OF p;

    FOR item IN SELECT value FROM jsonb_array_elements(p_items) AS e(value)
                 ORDER BY (value->>'producto_id')::UUID
    LOOP
        pid := (item->>'producto_id')::UUID;
        qty := (item->>'cantidad')::INTEGER;
        SELECT cantidad INTO cart_qty FROM public.inv_carrito_items
         WHERE usuario_id = p_usuario_id AND producto_id = pid;
        SELECT stock INTO actual FROM public.inv_productos WHERE id = pid;
        SELECT COALESCE(sum(cantidad), 0) INTO reservadas
          FROM public.inv_reservas_stock
         WHERE producto_id = pid AND NOT confirmada AND expira_en > now();
        IF actual - reservadas < qty THEN
            RAISE EXCEPTION 'Stock insuficiente para %', pid;
        END IF;

        INSERT INTO public.inv_reservas_stock(referencia_id, producto_id, cantidad,
                                       expira_en, usuario_id)
        VALUES (p_referencia_id, pid, qty, expiracion, p_usuario_id);
        INSERT INTO public.inv_movimientos_stock(producto_id, tipo, cantidad, stock_anterior,
                                          stock_resultante, referencia_id, nota)
        VALUES (pid, 'VENTA_RESERVA', -qty, actual, actual, p_referencia_id,
                'Reserva temporal de 15 minutos');
    END LOOP;

    RETURN jsonb_build_object('referencia_id', p_referencia_id, 'expira_en', expiracion);
END;
$$;

REVOKE ALL ON FUNCTION public.inv_reservar_stock(JSONB, TEXT, UUID)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inv_reservar_stock(JSONB, TEXT, UUID) TO service_role;
-- Revoca el bypass del schema original y de la migración anterior.
REVOKE ALL ON FUNCTION public.inv_reservar_stock(JSONB, TEXT)
    FROM PUBLIC, anon, authenticated, service_role;

-- Confirmación futura: advisory lock de referencia y productos por UUID antes de
-- bloquear reservas. Ledger único por referencia y evento evita doble descuento.
-- Esta función NO valida pagos y permanece sin EXECUTE para todos los roles.
CREATE OR REPLACE FUNCTION public.inv_confirmar_reserva(
    p_referencia_id TEXT,
    p_usuario_id UUID,
    p_evento_pago_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    previo public.inv_confirmaciones_pago%ROWTYPE;
    reserva RECORD;
    actual INTEGER;
    total INTEGER := 0;
    respuesta JSONB;
BEGIN
    IF p_usuario_id IS NULL OR p_referencia_id IS NULL OR btrim(p_referencia_id) = ''
       OR p_evento_pago_id IS NULL OR btrim(p_evento_pago_id) = '' THEN
        RAISE EXCEPTION 'Datos de confirmación inválidos';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(p_referencia_id, 0));

    SELECT * INTO previo FROM public.inv_confirmaciones_pago
     WHERE referencia_id = p_referencia_id OR evento_pago_id = p_evento_pago_id
     LIMIT 1 FOR UPDATE;
    IF FOUND THEN
        IF previo.referencia_id = p_referencia_id
           AND previo.evento_pago_id = p_evento_pago_id
           AND previo.usuario_id = p_usuario_id THEN
            RETURN previo.resultado;
        END IF;
        RAISE EXCEPTION 'Referencia o evento de pago ya procesado';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.inv_reservas_stock
                    WHERE referencia_id = p_referencia_id AND usuario_id = p_usuario_id) THEN
        RAISE EXCEPTION 'Reserva no pertenece al usuario';
    END IF;
    IF EXISTS (SELECT 1 FROM public.inv_reservas_stock
                WHERE referencia_id = p_referencia_id
                  AND (usuario_id IS DISTINCT FROM p_usuario_id OR confirmada)) THEN
        RAISE EXCEPTION 'Reserva con propietario o estado inválido';
    END IF;
    IF EXISTS (SELECT 1 FROM public.inv_reservas_stock
                WHERE referencia_id = p_referencia_id AND expira_en <= now()) THEN
        RAISE EXCEPTION 'Reserva expirada';
    END IF;

    -- Serializa la actualización de existencias, siempre en el mismo orden.
    PERFORM p.id FROM public.inv_productos p
      JOIN (SELECT DISTINCT producto_id FROM public.inv_reservas_stock
             WHERE referencia_id = p_referencia_id) r ON r.producto_id = p.id
     ORDER BY p.id
     FOR UPDATE OF p;

    respuesta := jsonb_build_object('referencia_id', p_referencia_id,
                                    'evento_pago_id', p_evento_pago_id);
    INSERT INTO public.inv_confirmaciones_pago(referencia_id, evento_pago_id, usuario_id, resultado)
    VALUES (p_referencia_id, p_evento_pago_id, p_usuario_id, respuesta);

    FOR reserva IN SELECT * FROM public.inv_reservas_stock
                    WHERE referencia_id = p_referencia_id
                    ORDER BY producto_id FOR UPDATE
    LOOP
        SELECT stock INTO actual FROM public.inv_productos WHERE id = reserva.producto_id;
        IF actual < reserva.cantidad THEN RAISE EXCEPTION 'Stock insuficiente'; END IF;
        UPDATE public.inv_productos SET stock = actual - reserva.cantidad, actualizado_en = now()
         WHERE id = reserva.producto_id;
        UPDATE public.inv_reservas_stock SET confirmada = TRUE WHERE id = reserva.id;
        INSERT INTO public.inv_movimientos_stock(producto_id, tipo, cantidad, stock_anterior,
                                          stock_resultante, referencia_id)
        VALUES (reserva.producto_id, 'VENTA_CONFIRMADA', -reserva.cantidad,
                actual, actual - reserva.cantidad, p_referencia_id);
        total := total + 1;
    END LOOP;

    respuesta := respuesta || jsonb_build_object('productos_confirmados', total);
    UPDATE public.inv_confirmaciones_pago SET resultado = respuesta
     WHERE referencia_id = p_referencia_id;
    RETURN respuesta;
END;
$$;

REVOKE ALL ON FUNCTION public.inv_confirmar_reserva(TEXT, UUID, TEXT)
    FROM PUBLIC, anon, authenticated, service_role;
-- La RPC antigua del schema original permanece revocada; no se habilita un bypass.
REVOKE ALL ON FUNCTION public.inv_confirmar_reserva(TEXT)
    FROM PUBLIC, anon, authenticated, service_role;

-- El propietario de todas las funciones SECURITY DEFINER es el rol confiable postgres.
ALTER FUNCTION public.inv_crear_producto(JSONB, UUID) OWNER TO postgres;
ALTER FUNCTION public.inv_ajustar_stock(UUID, UUID, TEXT, INTEGER, TEXT) OWNER TO postgres;
ALTER FUNCTION public.inv_carrito_agregar(UUID, UUID, INTEGER) OWNER TO postgres;
ALTER FUNCTION public.inv_carrito_cambiar(UUID, UUID, INTEGER) OWNER TO postgres;
ALTER FUNCTION public.inv_carrito_quitar(UUID, UUID) OWNER TO postgres;
ALTER FUNCTION public.inv_carrito_vaciar(UUID) OWNER TO postgres;
ALTER FUNCTION public.inv_reservar_stock(JSONB, TEXT, UUID) OWNER TO postgres;
ALTER FUNCTION public.inv_confirmar_reserva(TEXT, UUID, TEXT) OWNER TO postgres;
-- Las firmas antiguas no se ejecutan, y también quedan fijadas a un path seguro.
ALTER FUNCTION public.inv_reservar_stock(JSONB, TEXT)
    SET search_path TO pg_catalog, public, pg_temp;
ALTER FUNCTION public.inv_reservar_stock(JSONB, TEXT) OWNER TO postgres;
ALTER FUNCTION public.inv_confirmar_reserva(TEXT)
    SET search_path TO pg_catalog, public, pg_temp;
ALTER FUNCTION public.inv_confirmar_reserva(TEXT) OWNER TO postgres;

-- Reafirma ACLs después del cambio de propietario. Solo service_role ejecuta las
-- RPC de aplicación; la función futura de confirmación no recibe GRANT.
REVOKE ALL ON FUNCTION public.inv_crear_producto(JSONB, UUID)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_ajustar_stock(UUID, UUID, TEXT, INTEGER, TEXT)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_carrito_agregar(UUID, UUID, INTEGER)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_carrito_cambiar(UUID, UUID, INTEGER)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_carrito_quitar(UUID, UUID)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_carrito_vaciar(UUID)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_reservar_stock(JSONB, TEXT, UUID)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inv_crear_producto(JSONB, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_ajustar_stock(UUID, UUID, TEXT, INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_carrito_agregar(UUID, UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_carrito_cambiar(UUID, UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_carrito_quitar(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_carrito_vaciar(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_reservar_stock(JSONB, TEXT, UUID) TO service_role;
REVOKE ALL ON FUNCTION public.inv_confirmar_reserva(TEXT, UUID, TEXT)
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.inv_confirmar_reserva(TEXT)
    FROM PUBLIC, anon, authenticated, service_role;
COMMIT;
