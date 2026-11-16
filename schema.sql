CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS public.inv_categorias (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(), nombre VARCHAR(100) NOT NULL UNIQUE,
    slug VARCHAR(120) NOT NULL UNIQUE, descripcion TEXT, activo BOOLEAN DEFAULT TRUE,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.inv_productos (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(), vendedor_id UUID NOT NULL,
    categoria_id UUID REFERENCES public.inv_categorias(id) ON DELETE SET NULL,
    sku VARCHAR(60) NOT NULL UNIQUE, nombre VARCHAR(255) NOT NULL, descripcion TEXT,
    precio NUMERIC(14,2) NOT NULL CHECK (precio > 0), imagen_url TEXT,
    stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0), stock_minimo_alerta INTEGER NOT NULL DEFAULT 5 CHECK (stock_minimo_alerta >= 0),
    activo BOOLEAN DEFAULT TRUE, creado_en TIMESTAMPTZ NOT NULL DEFAULT now(), actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.inv_carrito_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(), usuario_id UUID NOT NULL,
    producto_id UUID NOT NULL REFERENCES public.inv_productos(id) ON DELETE CASCADE,
    cantidad INTEGER NOT NULL DEFAULT 1 CHECK (cantidad > 0), creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE (usuario_id, producto_id)
);
CREATE TABLE IF NOT EXISTS public.inv_movimientos_stock (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(), producto_id UUID NOT NULL REFERENCES public.inv_productos(id) ON DELETE CASCADE,
    tipo VARCHAR(30) NOT NULL CHECK (tipo IN ('ENTRADA','VENTA_RESERVA','VENTA_CONFIRMADA','DEVOLUCION','AJUSTE')),
    cantidad INTEGER NOT NULL, stock_anterior INTEGER NOT NULL, stock_resultante INTEGER NOT NULL,
    referencia_id VARCHAR(100), nota TEXT, creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.inv_reservas_stock (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(), referencia_id VARCHAR(100) NOT NULL,
    producto_id UUID NOT NULL REFERENCES public.inv_productos(id), cantidad INTEGER NOT NULL CHECK (cantidad > 0),
    expira_en TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '15 minutes'), confirmada BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (referencia_id, producto_id)
);
CREATE INDEX IF NOT EXISTS idx_inv_prod_vendedor ON public.inv_productos(vendedor_id);
CREATE INDEX IF NOT EXISTS idx_inv_prod_sku ON public.inv_productos(sku);
CREATE INDEX IF NOT EXISTS idx_inv_reservas_expira ON public.inv_reservas_stock(expira_en) WHERE NOT confirmada;

-- Reservar/descontar en una transacción para evitar vender unidades simultáneamente.
CREATE OR REPLACE FUNCTION public.inv_reservar_stock(p_items JSONB, p_referencia_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE item JSONB; pid UUID; qty INTEGER; actual INTEGER; nuevo INTEGER; disponibles INTEGER;
BEGIN
  IF EXISTS (SELECT 1 FROM inv_reservas_stock WHERE referencia_id=p_referencia_id) THEN
    RAISE EXCEPTION 'La referencia ya tiene reserva';
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    pid := (item->>'producto_id')::UUID; qty := (item->>'cantidad')::INTEGER;
    SELECT stock INTO actual FROM inv_productos WHERE id=pid AND activo FOR UPDATE;
    IF actual IS NULL OR qty <= 0 THEN RAISE EXCEPTION 'Producto inválido'; END IF;
    SELECT COALESCE(SUM(cantidad),0) INTO disponibles FROM inv_reservas_stock
      WHERE producto_id=pid AND NOT confirmada AND expira_en > now();
    IF actual - disponibles < qty THEN RAISE EXCEPTION 'Stock insuficiente para %', pid; END IF;
    INSERT INTO inv_reservas_stock(referencia_id,producto_id,cantidad) VALUES(p_referencia_id,pid,qty);
    INSERT INTO inv_movimientos_stock(producto_id,tipo,cantidad,stock_anterior,stock_resultante,referencia_id,nota)
      VALUES(pid,'VENTA_RESERVA',-qty,actual,actual,p_referencia_id,'Reserva temporal de 15 minutos');
  END LOOP;
  RETURN jsonb_build_object('referencia_id',p_referencia_id,'expira_en',now()+interval '15 minutes');
END $$;

CREATE OR REPLACE FUNCTION public.inv_confirmar_reserva(p_referencia_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD; actual INTEGER; nuevo INTEGER; total INTEGER := 0;
BEGIN
  FOR r IN SELECT * FROM inv_reservas_stock WHERE referencia_id=p_referencia_id AND NOT confirmada FOR UPDATE LOOP
    IF r.expira_en <= now() THEN RAISE EXCEPTION 'Reserva expirada'; END IF;
    SELECT stock INTO actual FROM inv_productos WHERE id=r.producto_id FOR UPDATE;
    IF actual < r.cantidad THEN RAISE EXCEPTION 'Stock insuficiente'; END IF;
    nuevo := actual-r.cantidad;
    UPDATE inv_productos SET stock=nuevo, actualizado_en=now() WHERE id=r.producto_id;
    UPDATE inv_reservas_stock SET confirmada=TRUE WHERE id=r.id;
    INSERT INTO inv_movimientos_stock(producto_id,tipo,cantidad,stock_anterior,stock_resultante,referencia_id)
      VALUES(r.producto_id,'VENTA_CONFIRMADA',-r.cantidad,actual,nuevo,p_referencia_id);
    total := total+1;
  END LOOP;
  IF total=0 THEN RAISE EXCEPTION 'No hay reservas vigentes'; END IF;
  RETURN jsonb_build_object('referencia_id',p_referencia_id,'productos_confirmados',total);
END $$;

ALTER TABLE inv_categorias ENABLE ROW LEVEL SECURITY;
ALTER TABLE inv_productos ENABLE ROW LEVEL SECURITY;
ALTER TABLE inv_carrito_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE inv_movimientos_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE inv_reservas_stock ENABLE ROW LEVEL SECURITY;
-- API pública de lectura; cambios privados solo para el propietario autenticado.
DROP POLICY IF EXISTS "policy_inv_cat" ON inv_categorias;
DROP POLICY IF EXISTS "policy_inv_prod" ON inv_productos;
DROP POLICY IF EXISTS "policy_inv_cart" ON inv_carrito_items;
DROP POLICY IF EXISTS "policy_inv_mov" ON inv_movimientos_stock;
DROP POLICY IF EXISTS "policy_inv_reservas" ON inv_reservas_stock;
CREATE POLICY "inv_cat_read" ON inv_categorias FOR SELECT TO anon, authenticated USING (activo);
CREATE POLICY "inv_prod_read" ON inv_productos FOR SELECT TO anon, authenticated USING (activo);
CREATE POLICY "inv_prod_insert_owner" ON inv_productos FOR INSERT TO authenticated WITH CHECK (vendedor_id = auth.uid());
CREATE POLICY "inv_prod_update_owner" ON inv_productos FOR UPDATE TO authenticated USING (vendedor_id = auth.uid()) WITH CHECK (vendedor_id = auth.uid());
CREATE POLICY "inv_cart_owner" ON inv_carrito_items FOR ALL TO authenticated USING (usuario_id = auth.uid()) WITH CHECK (usuario_id = auth.uid());
-- Auditoría y reservas se gestionan exclusivamente desde el backend con service_role.
REVOKE ALL ON inv_movimientos_stock, inv_reservas_stock FROM anon, authenticated;
REVOKE ALL ON FUNCTION inv_reservar_stock(JSONB, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION inv_confirmar_reserva(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION inv_reservar_stock(JSONB, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION inv_confirmar_reserva(TEXT) TO service_role;

-- Bucket público para leer imágenes, con carga restringida a carpeta del usuario.
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('productos','productos',TRUE,2097152,ARRAY['image/jpeg','image/png'])
ON CONFLICT (id) DO UPDATE SET public=TRUE, file_size_limit=2097152, allowed_mime_types=ARRAY['image/jpeg','image/png'];
DROP POLICY IF EXISTS "productos_public_read" ON storage.objects;
DROP POLICY IF EXISTS "productos_user_upload" ON storage.objects;
CREATE POLICY "productos_public_read" ON storage.objects FOR SELECT TO anon, authenticated USING (bucket_id='productos');
CREATE POLICY "productos_user_upload" ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id='productos' AND (storage.foldername(name))[1]=auth.uid()::text);

INSERT INTO inv_categorias(nombre,slug,descripcion) VALUES
('Tecnología & Computación','tecnologia','Laptops, tablets, periféricos y accesorios'),
('Libros & Material Académico','libros','Textos universitarios, guías y manuales'),
('Útiles & Papelería','utiles','Cuadernos, calculadoras y material'),
('Moda & Merchandising USC','merchandising','Prendas y accesorios institucionales')
ON CONFLICT(nombre) DO NOTHING;
