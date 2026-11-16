-- Migración incremental para identidad de reservas y movimientos atómicos.
-- Revisar y ejecutar manualmente en Supabase SQL Editor.
-- No elimina tablas ni modifica reservas existentes; usuario_id queda NULL en las históricas.

BEGIN;

DO $$
DECLARE superuser_actor BOOLEAN;
BEGIN
    SELECT rolsuper INTO superuser_actor FROM pg_catalog.pg_roles
     WHERE rolname = current_user;
    IF current_user <> 'postgres' AND NOT COALESCE(superuser_actor, FALSE) THEN
        RAISE EXCEPTION 'Run migration_checkout_inventory.sql as postgres or a superuser';
    END IF;
END;
$$;

ALTER TABLE public.inv_reservas_stock
    ADD COLUMN IF NOT EXISTS usuario_id UUID;

CREATE INDEX IF NOT EXISTS idx_inv_reservas_usuario
    ON public.inv_reservas_stock(usuario_id, referencia_id);

-- Crear producto y auditar el stock inicial dentro de una sola transacción.
CREATE OR REPLACE FUNCTION public.inv_crear_producto(p_producto JSONB, p_vendedor_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    producto public.inv_productos%ROWTYPE;
    stock_inicial INTEGER := COALESCE((p_producto->>'stock')::INTEGER, 0);
BEGIN
    IF stock_inicial < 0 THEN RAISE EXCEPTION 'El stock no puede ser negativo'; END IF;

    INSERT INTO public.inv_productos(categoria_id, vendedor_id, sku, nombre, descripcion,
                              precio, imagen_url, stock, stock_minimo_alerta)
    VALUES (NULLIF(p_producto->>'categoria_id', '')::UUID, p_vendedor_id,
            p_producto->>'sku', p_producto->>'nombre', p_producto->>'descripcion',
            (p_producto->>'precio')::NUMERIC, p_producto->>'imagen_url',
            stock_inicial, COALESCE((p_producto->>'stock_minimo_alerta')::INTEGER, 5))
    RETURNING * INTO producto;

    IF stock_inicial > 0 THEN
        INSERT INTO public.inv_movimientos_stock(producto_id, tipo, cantidad,
                                          stock_anterior, stock_resultante, nota)
        VALUES (producto.id, 'ENTRADA', stock_inicial, 0, stock_inicial, 'Stock inicial');
    END IF;
    RETURN to_jsonb(producto);
END;
$$;

REVOKE ALL ON FUNCTION public.inv_crear_producto(JSONB, UUID)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inv_crear_producto(JSONB, UUID) TO service_role;

-- Entradas y ajustes comparten el mismo bloqueo que usa la reserva por producto.
-- AJUSTE acepta diferencias positivas o negativas; no puede dejar stock bajo reservas activas.
CREATE OR REPLACE FUNCTION public.inv_ajustar_stock(
    p_producto_id UUID,
    p_vendedor_id UUID,
    p_tipo TEXT,
    p_cantidad INTEGER,
    p_nota TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    actual INTEGER;
    nuevo INTEGER;
    reservado INTEGER;
BEGIN
    IF p_tipo NOT IN ('ENTRADA', 'AJUSTE') OR p_cantidad = 0
       OR (p_tipo = 'ENTRADA' AND p_cantidad < 0) THEN
        RAISE EXCEPTION 'Movimiento inválido';
    END IF;

    SELECT stock INTO actual
      FROM public.inv_productos
     WHERE id = p_producto_id AND vendedor_id = p_vendedor_id AND activo
     FOR UPDATE;
    IF actual IS NULL THEN RAISE EXCEPTION 'Producto no encontrado'; END IF;

    nuevo := actual + p_cantidad;
    IF nuevo < 0 THEN RAISE EXCEPTION 'El stock no puede ser negativo'; END IF;

    SELECT COALESCE(SUM(cantidad), 0) INTO reservado
      FROM public.inv_reservas_stock
     WHERE producto_id = p_producto_id AND NOT confirmada AND expira_en > now();
    IF nuevo < reservado THEN
        RAISE EXCEPTION 'El nuevo stock es menor que las unidades reservadas';
    END IF;

    UPDATE public.inv_productos SET stock = nuevo, actualizado_en = now()
     WHERE id = p_producto_id;
    INSERT INTO public.inv_movimientos_stock(producto_id, tipo, cantidad, stock_anterior, stock_resultante, nota)
    VALUES (p_producto_id, p_tipo, p_cantidad, actual, nuevo, p_nota);

    RETURN jsonb_build_object('producto_id', p_producto_id, 'tipo', p_tipo,
                              'cantidad', p_cantidad, 'stock_anterior', actual,
                              'stock_resultante', nuevo);
END;
$$;

REVOKE ALL ON FUNCTION public.inv_ajustar_stock(UUID, UUID, TEXT, INTEGER, TEXT)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inv_ajustar_stock(UUID, UUID, TEXT, INTEGER, TEXT)
    TO service_role;

-- La reserva con identidad y comparaci?n exacta se crea en migration_inventory_hardening.sql.
-- Se revoca la funci?n legacy del schema original desde esta migraci?n.
REVOKE ALL ON FUNCTION public.inv_reservar_stock(JSONB, TEXT)
    FROM PUBLIC, anon, authenticated, service_role;

-- No hay integración con pasarela que valide el pago. Se revoca la confirmación
-- antigua hasta que se implemente un verificador confiable; no se descuenta stock
-- solo por conocer un secreto compartido.
REVOKE ALL ON FUNCTION public.inv_confirmar_reserva(TEXT)
    FROM PUBLIC, anon, authenticated, service_role;

ALTER FUNCTION public.inv_crear_producto(JSONB, UUID) OWNER TO postgres;
ALTER FUNCTION public.inv_ajustar_stock(UUID, UUID, TEXT, INTEGER, TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inv_crear_producto(JSONB, UUID)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inv_ajustar_stock(UUID, UUID, TEXT, INTEGER, TEXT)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inv_crear_producto(JSONB, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.inv_ajustar_stock(UUID, UUID, TEXT, INTEGER, TEXT) TO service_role;
COMMIT;
