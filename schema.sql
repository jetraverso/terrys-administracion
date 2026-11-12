-- Terry's Administración — tablas y seguridad para Supabase
-- Pegá TODO este archivo en Supabase → SQL Editor → Run.
-- Se puede correr las veces que haga falta: no borra datos.

-- ---------------------------------------------------------------
-- 1. Quién puede entrar
-- ---------------------------------------------------------------
-- Además de tener usuario y contraseña (Supabase → Authentication),
-- el email tiene que estar en esta lista. Si no está, no ve ni toca nada.
create table if not exists public.admin_usuarios (
  email  text primary key,
  nombre text not null default '',
  creado timestamptz not null default now()
);

-- La lista no se carga desde este archivo (el repositorio es público):
-- después de correrlo, agregá tu email a mano en el SQL Editor:
--   insert into public.admin_usuarios (email, nombre) values ('tu@mail.com', 'Tu nombre');
--
-- Para darle acceso a otra persona más adelante:
--   1) Authentication → Users → Add user (email + contraseña)
--   2) insert into public.admin_usuarios (email, nombre) values ('persona@mail.com', 'Nombre');
-- Para quitárselo:
--   delete from public.admin_usuarios where email = 'persona@mail.com';

-- en_lista(): el email de la sesión está en admin_usuarios. La página lo usa
-- apenas se pone la contraseña, para rechazar a quien no está en la lista.
create or replace function public.en_lista()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admin_usuarios u
    where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- es_admin(): está en la lista Y pasó la verificación en dos pasos (sesión aal2).
-- Es la que usan todas las políticas: con la contraseña sola, sin el código
-- del celular, no se lee ni se escribe nada.
create or replace function public.es_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.en_lista() and coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;

revoke all on function public.en_lista() from public, anon;
grant execute on function public.en_lista() to authenticated;
revoke all on function public.es_admin() from public, anon;
grant execute on function public.es_admin() to authenticated;

alter table public.admin_usuarios enable row level security;
revoke all on public.admin_usuarios from anon, authenticated;
grant select on public.admin_usuarios to authenticated;

drop policy if exists admin_usuarios_ver on public.admin_usuarios;
create policy admin_usuarios_ver on public.admin_usuarios
  for select to authenticated
  using (public.es_admin());

-- ---------------------------------------------------------------
-- 2. Movimientos (ingresos, egresos, facturas a proveedores)
-- ---------------------------------------------------------------
-- "empresa" identifica la solapa. Hoy hay una sola: terrys-burgers-sl.
create table if not exists public.movimientos (
  id              bigint generated always as identity primary key,
  empresa         text not null default 'terrys-burgers-sl',
  fecha           date not null,
  ingreso         numeric(12,2),
  egreso          numeric(12,2),
  detalle         text not null default '',
  tipo            text not null default '',
  desde           text not null default '',
  hacia           text not null default '',
  estado          text not null default '',
  informacion     text not null default '',
  factura         text not null default '',
  pagado          boolean not null default false,
  clara           boolean not null default false,
  comentarios     text not null default '',
  creado          timestamptz not null default now(),
  creado_por      text default (auth.jwt() ->> 'email'),
  actualizado     timestamptz not null default now(),
  actualizado_por text
);

create index if not exists movimientos_empresa_fecha on public.movimientos (empresa, fecha, id);

alter table public.movimientos enable row level security;
revoke all on public.movimientos from anon, authenticated;
grant select, insert, update, delete on public.movimientos to authenticated;

-- (las políticas de acceso están en la sección 5)

-- ---------------------------------------------------------------
-- 3. Registro de cambios (red de seguridad)
-- ---------------------------------------------------------------
-- Cada alta, edición o borrado queda guardado con el antes y el después.
-- Si se borra algo por error se puede recuperar desde acá (Table Editor).
create table if not exists public.movimientos_log (
  id      bigint generated always as identity primary key,
  mov_id  bigint,
  accion  text not null,
  quien   text,
  cuando  timestamptz not null default now(),
  antes   jsonb,
  despues jsonb
);

alter table public.movimientos_log enable row level security;
revoke all on public.movimientos_log from anon, authenticated;
grant select on public.movimientos_log to authenticated;

drop policy if exists movimientos_log_ver on public.movimientos_log;
create policy movimientos_log_ver on public.movimientos_log
  for select to authenticated
  using (public.es_admin());

create or replace function public.movimientos_auditar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  quien text := auth.jwt() ->> 'email';
begin
  if tg_op = 'UPDATE' then
    new.actualizado := now();
    new.actualizado_por := coalesce(quien, new.actualizado_por);
    insert into public.movimientos_log (mov_id, accion, quien, antes, despues)
    values (old.id, 'editar', new.actualizado_por, to_jsonb(old), to_jsonb(new));
    return new;
  elsif tg_op = 'DELETE' then
    insert into public.movimientos_log (mov_id, accion, quien, antes)
    values (old.id, 'borrar', quien, to_jsonb(old));
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.movimientos_auditar_alta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.movimientos_log (mov_id, accion, quien, despues)
  values (new.id, 'crear', coalesce(auth.jwt() ->> 'email', new.creado_por), to_jsonb(new));
  return new;
end;
$$;

drop trigger if exists movimientos_auditar_tg on public.movimientos;
create trigger movimientos_auditar_tg
  before update or delete on public.movimientos
  for each row execute function public.movimientos_auditar();

drop trigger if exists movimientos_auditar_alta_tg on public.movimientos;
create trigger movimientos_auditar_alta_tg
  after insert on public.movimientos
  for each row execute function public.movimientos_auditar_alta();

-- ---------------------------------------------------------------
-- 4. Ventas diarias (Ágora POS)
-- ---------------------------------------------------------------
-- Un script en la computadora del TPV (agora/subir-ventas.ps1) le pide a Ágora
-- las ventas de cada día y las manda acá con la función subir_ventas(), que se
-- autentica con un token propio (tabla integraciones), sin usuario ni 2FA.
-- Se guarda el JSON tal cual lo devuelve Ágora ("bruto"); la página arma sola
-- un resumen compacto ("resumen") la primera vez que lo necesita.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.integraciones (
  nombre      text primary key,
  token_hash  text not null,
  creado      timestamptz not null default now(),
  ultimo_uso  timestamptz
);
alter table public.integraciones enable row level security;
revoke all on public.integraciones from anon, authenticated;
-- (nadie la lee desde la página; solo la usa subir_ventas)

-- Para dar de alta el token del script (elegí uno largo y al azar; el mismo va en agora/config.json):
--   insert into public.integraciones (nombre, token_hash)
--   values ('agora', encode(extensions.digest('EL-TOKEN', 'sha256'), 'hex'))
--   on conflict (nombre) do update set token_hash = excluded.token_hash;

create table if not exists public.ventas_dias (
  id         bigint generated always as identity primary key,
  empresa    text not null default 'terrys-burgers-sl',
  dia        date not null,
  origen     text not null default 'agora',
  bruto      jsonb not null,
  resumen    jsonb,
  resumen_v  int not null default 0,
  subido     timestamptz not null default now(),
  unique (empresa, dia, origen)
);
alter table public.ventas_dias enable row level security;
revoke all on public.ventas_dias from anon, authenticated;
grant select, update on public.ventas_dias to authenticated;

drop policy if exists ventas_dias_ver on public.ventas_dias;
create policy ventas_dias_ver on public.ventas_dias
  for select to authenticated using (public.es_admin());
drop policy if exists ventas_dias_resumir on public.ventas_dias;
create policy ventas_dias_resumir on public.ventas_dias
  for update to authenticated using (public.es_admin()) with check (public.es_admin());

create or replace function public.subir_ventas(p_token text, p_dia date, p_datos jsonb, p_empresa text default 'terrys-burgers-sl', p_origen text default 'agora')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  ok boolean;
begin
  select true into ok from public.integraciones
   where nombre = p_origen and token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
  if not coalesce(ok, false) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then
    raise exception 'datos inválidos: se esperaba el JSON de Ágora' using errcode = '22023';
  end if;
  insert into public.ventas_dias (empresa, dia, origen, bruto, resumen, resumen_v, subido)
  values (p_empresa, p_dia, p_origen, p_datos, null, 0, now())
  on conflict (empresa, dia, origen) do update
    set bruto = excluded.bruto, resumen = null, resumen_v = 0, subido = now();
  update public.integraciones set ultimo_uso = now() where nombre = p_origen;
  return jsonb_build_object('ok', true, 'dia', p_dia, 'tickets', coalesce(jsonb_array_length(p_datos -> 'Invoices'), 0));
end;
$$;
revoke all on function public.subir_ventas(text, date, jsonb, text, text) from public;
grant execute on function public.subir_ventas(text, date, jsonb, text, text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 5. Ventas del día en Compras
-- ---------------------------------------------------------------
-- Cada día que sube el script de Ágora se convierte también en una fila de
-- ingresos en la planilla de Compras (una por día, total cobrado con IVA, y en
-- Detalle la cantidad de tickets y el desglose por forma de pago). Esas filas llevan origen='agora'
-- y desde la página no se editan ni se borran: se actualizan solas si el día
-- se vuelve a subir.
alter table public.movimientos add column if not exists origen text;
alter table public.movimientos add column if not exists ref text;
create unique index if not exists movimientos_origen_ref on public.movimientos (empresa, origen, ref) where origen is not null;

create or replace function public.sincronizar_venta_compra(p_empresa text, p_dia date, p_datos jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  total   numeric(12,2);
  tickets int;
  desglose text;
begin
  select coalesce(sum((i -> 'Totals' ->> 'GrossAmount')::numeric), 0),
         count(*) filter (where (i -> 'Totals' ->> 'GrossAmount')::numeric > 0)
    into total, tickets
    from jsonb_array_elements(coalesce(p_datos -> 'Invoices', '[]'::jsonb)) i;

  if total <= 0 then
    delete from public.movimientos where empresa = p_empresa and origen = 'agora' and ref = p_dia::text;
    return;
  end if;

  select string_agg(m || ' ' || replace(to_char(s, 'FM999999990.00'), '.', ','), ' · ' order by s desc)
    into desglose
    from (
      select regexp_replace(coalesce(p ->> 'MethodName', '—'), ' de (crédito|débito)$', '', 'i') m, sum((p ->> 'Amount')::numeric) s
        from jsonb_array_elements(coalesce(p_datos -> 'Invoices', '[]'::jsonb)) i,
             jsonb_array_elements(coalesce(i -> 'Payments', '[]'::jsonb)) p
       group by 1
    ) x;

  insert into public.movimientos (empresa, fecha, ingreso, egreso, detalle, tipo, desde, hacia, estado, informacion, factura, pagado, clara, comentarios, origen, ref, creado_por)
  values (p_empresa, p_dia, total, null, 'Ventas del día: ' || tickets || ' tickets · ' || coalesce(desglose, ''), 'Ventas', 'Ágora', 'Terrys', 'Terminado',
          '', '', true, false, '', 'agora', p_dia::text, 'agora')
  on conflict (empresa, origen, ref) where origen is not null do update
    set fecha = excluded.fecha, ingreso = excluded.ingreso, detalle = excluded.detalle, informacion = excluded.informacion, actualizado_por = 'agora';
end;
$$;
revoke all on function public.sincronizar_venta_compra(text, date, jsonb) from public, anon, authenticated;

-- subir_ventas() ahora también crea/actualiza la fila de Compras
create or replace function public.subir_ventas(p_token text, p_dia date, p_datos jsonb, p_empresa text default 'terrys-burgers-sl', p_origen text default 'agora')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  ok boolean;
begin
  select true into ok from public.integraciones
   where nombre = p_origen and token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
  if not coalesce(ok, false) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then
    raise exception 'datos inválidos: se esperaba el JSON de Ágora' using errcode = '22023';
  end if;
  insert into public.ventas_dias (empresa, dia, origen, bruto, resumen, resumen_v, subido)
  values (p_empresa, p_dia, p_origen, p_datos, null, 0, now())
  on conflict (empresa, dia, origen) do update
    set bruto = excluded.bruto, resumen = null, resumen_v = 0, subido = now();
  update public.integraciones set ultimo_uso = now() where nombre = p_origen;
  if p_origen = 'agora' then perform public.sincronizar_venta_compra(p_empresa, p_dia, p_datos); end if;
  return jsonb_build_object('ok', true, 'dia', p_dia, 'tickets', coalesce(jsonb_array_length(p_datos -> 'Invoices'), 0));
end;
$$;

-- Las filas automáticas no se tocan desde la página (solo se leen).
drop policy if exists movimientos_admin on public.movimientos;
drop policy if exists movimientos_ver on public.movimientos;
drop policy if exists movimientos_crear on public.movimientos;
drop policy if exists movimientos_editar on public.movimientos;
drop policy if exists movimientos_borrar on public.movimientos;
create policy movimientos_ver on public.movimientos for select to authenticated using (public.es_admin());
create policy movimientos_crear on public.movimientos for insert to authenticated with check (public.es_admin() and origen is null);
create policy movimientos_editar on public.movimientos for update to authenticated using (public.es_admin() and origen is null) with check (public.es_admin() and origen is null);
create policy movimientos_borrar on public.movimientos for delete to authenticated using (public.es_admin() and origen is null);

-- Los días que ya estaban subidos se pasan a Compras ahora (se puede repetir sin problema).
select public.sincronizar_venta_compra(empresa, dia, bruto) from public.ventas_dias where origen = 'agora';

-- ---------------------------------------------------------------
-- 6. Facturas leídas desde Drive (bandeja "por revisar")
-- ---------------------------------------------------------------
-- Claude lee las facturas de la carpeta de Drive y las manda con subir_factura()
-- (token propio 'facturas' en integraciones). Cada archivo se identifica por su
-- id de Drive ("archivo") y entra una sola vez:
--   · si ya hay una fila cargada a mano con el mismo importe y fecha cercana,
--     se VINCULA a esa fila (se le pone el link y se tilda Facturas);
--   · si no, se crea una fila nueva marcada "revisar", editable como cualquier
--     otra, que se aprueba desde la página.
alter table public.movimientos add column if not exists archivo text;
alter table public.movimientos add column if not exists revisar boolean not null default false;
create unique index if not exists movimientos_archivo on public.movimientos (empresa, archivo) where archivo is not null;

-- Alta del token (el mismo va en facturas/config.json, que no se sube al repositorio):
--   insert into public.integraciones (nombre, token_hash)
--   values ('facturas', encode(extensions.digest('EL-TOKEN', 'sha256'), 'hex'))
--   on conflict (nombre) do update set token_hash = excluded.token_hash;

create or replace function public._token_valido(p_nombre text, p_token text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.integraciones
                  where nombre = p_nombre and token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex'));
$$;
revoke all on function public._token_valido(text, text) from public, anon, authenticated;

-- ¿Cuáles de estos archivos ya están cargados?  → {"idDeDrive": {id, fecha, egreso, detalle, revisar} | null, ...}
create or replace function public.facturas_estado(p_token text, p_archivos text[], p_empresa text default 'terrys-burgers-sl')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._token_valido('facturas', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  return coalesce((
    select jsonb_object_agg(a, coalesce(
             (select jsonb_build_object('id', m.id, 'fecha', m.fecha, 'egreso', m.egreso, 'ingreso', m.ingreso, 'detalle', m.detalle, 'revisar', m.revisar)
                from public.movimientos m where m.empresa = p_empresa and m.archivo = a),
             (select jsonb_build_object('descartada', true, 'cuando', max(l.cuando))
                from public.movimientos_log l where l.accion = 'borrar' and l.antes ->> 'archivo' = a having count(*) > 0)))
      from unnest(p_archivos) a), '{}'::jsonb);
end;
$$;
revoke all on function public.facturas_estado(text, text[], text) from public;
grant execute on function public.facturas_estado(text, text[], text) to anon, authenticated;

create or replace function public._sin_acentos(t text)
returns text language sql immutable as $$
  select translate(lower(coalesce(t, '')), 'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc');
$$;

-- p_datos: {archivo, link, fecha, total, proveedor, detalle, nota}  y opcionales:
--   ingreso: true      el documento es plata que entra (abono, liquidación): va a Ingresos
--   tipo, desde, hacia para fijarlos en vez de copiarlos de la última fila del proveedor
--   reemplazar: true   corrige una fila que subió Claude y que todavía nadie aprobó
--   forzar: true       vuelve a subir un archivo cuya fila alguien borró (si no, se respeta el borrado)
create or replace function public.subir_factura(p_token text, p_datos jsonb, p_empresa text default 'terrys-burgers-sl')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_archivo text := nullif(btrim(p_datos ->> 'archivo'), '');
  v_link    text := nullif(btrim(p_datos ->> 'link'), '');
  v_fecha   date := (p_datos ->> 'fecha')::date;
  v_total   numeric(12,2) := (p_datos ->> 'total')::numeric;
  v_prov    text := btrim(coalesce(p_datos ->> 'proveedor', ''));
  v_det     text := btrim(coalesce(p_datos ->> 'detalle', ''));
  v_nota    text := btrim(coalesce(p_datos ->> 'nota', ''));
  v_ing     boolean := coalesce((p_datos ->> 'ingreso')::boolean, false);
  v_reemp   boolean := coalesce((p_datos ->> 'reemplazar')::boolean, false);
  v_tipo    text := nullif(btrim(p_datos ->> 'tipo'), '');
  v_desde   text := nullif(btrim(p_datos ->> 'desde'), '');
  v_hacia   text := nullif(btrim(p_datos ->> 'hacia'), '');
  v_pal     text := public._sin_acentos(split_part(v_prov, ' ', 1));
  v_id      bigint;
  v_n       int;
  r         public.movimientos%rowtype;
  ex        public.movimientos%rowtype;
begin
  if not public._token_valido('facturas', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  if v_archivo is null or v_fecha is null or v_total is null or v_total <= 0 or v_link is null or v_link !~ '^https://' then
    raise exception 'datos inválidos: hacen falta archivo, link, fecha y total' using errcode = '22023';
  end if;

  -- Tipo, Desde y Hacia: los que vengan indicados; si no, para un egreso se copian de la
  -- última fila del mismo proveedor (sin distinguir acentos), y para un ingreso van
  -- Tipo "Ingreso", Desde el proveedor y Hacia "CAIXA".
  if v_ing then
    v_tipo := coalesce(v_tipo, 'Ingreso'); v_desde := coalesce(v_desde, v_prov); v_hacia := coalesce(v_hacia, 'CAIXA');
  else
    select * into r from public.movimientos
     where empresa = p_empresa and origen is null and coalesce(egreso, 0) > 0 and v_pal <> '' and not revisar
       and (public._sin_acentos(hacia) = public._sin_acentos(v_prov) or public._sin_acentos(hacia) like v_pal || '%')
     order by (public._sin_acentos(hacia) = public._sin_acentos(v_prov)) desc, fecha desc, id desc
     limit 1;
    v_tipo := coalesce(v_tipo, r.tipo, ''); v_desde := coalesce(v_desde, r.desde, ''); v_hacia := coalesce(v_hacia, nullif(r.hacia, ''), v_prov);
  end if;

  -- 1) ¿ese archivo ya está?
  select * into ex from public.movimientos where empresa = p_empresa and archivo = v_archivo;
  if ex.id is not null then
    if v_reemp and ex.revisar and ex.creado_por = 'claude' then
      update public.movimientos
         set fecha = v_fecha,
             ingreso = case when v_ing then v_total else null end,
             egreso  = case when v_ing then null else v_total end,
             detalle = coalesce(nullif(v_det, ''), detalle),
             tipo = v_tipo, desde = v_desde, hacia = v_hacia,
             comentarios = coalesce(nullif(v_nota, ''), comentarios),
             actualizado_por = 'claude'
       where id = ex.id;
      return jsonb_build_object('estado', 'corregida', 'id', ex.id, 'tipo', v_tipo, 'desde', v_desde, 'hacia', v_hacia);
    end if;
    return jsonb_build_object('estado', 'ya_cargada', 'id', ex.id, 'revisar', ex.revisar);
  end if;

  -- 1b) si alguien borró la fila de este archivo (por duplicada o porque no corresponde), no se vuelve a crear
  if not coalesce((p_datos ->> 'forzar')::boolean, false)
     and exists (select 1 from public.movimientos_log l where l.accion = 'borrar' and l.antes ->> 'archivo' = v_archivo) then
    return jsonb_build_object('estado', 'descartada');
  end if;

  -- 2) ¿hay una fila cargada a mano que sea este documento? (mismo importe, fecha a ±5 días, sin archivo)
  select count(*) into v_n from public.movimientos
   where empresa = p_empresa and origen is null and archivo is null
     and (case when v_ing then ingreso else egreso end) = v_total and fecha between v_fecha - 5 and v_fecha + 5;
  if v_n >= 1 then
    select * into r from public.movimientos
     where empresa = p_empresa and origen is null and archivo is null
       and (case when v_ing then ingreso else egreso end) = v_total and fecha between v_fecha - 5 and v_fecha + 5
     order by (v_pal <> '' and public._sin_acentos(case when v_ing then desde else hacia end) like v_pal || '%') desc, abs(fecha - v_fecha), id
     limit 1;
    if v_n = 1 or (v_pal <> '' and public._sin_acentos(case when v_ing then r.desde else r.hacia end) like v_pal || '%') then
      update public.movimientos
         set archivo = v_archivo,
             factura = 'Sí',
             informacion = case
               when informacion ~ '^\[[^\]]*\]\(https?://' or informacion ~ '^https?://' then informacion        -- ya tenía link: no se toca
               else '[' || coalesce(nullif(replace(replace(btrim(informacion), '[', ''), ']', ''), ''), 'Factura') || '](' || v_link || ')'
             end,
             actualizado_por = 'claude'
       where id = r.id;
      return jsonb_build_object('estado', 'vinculada', 'id', r.id, 'fecha', r.fecha, 'detalle', r.detalle, 'hacia', r.hacia, 'desde', r.desde);
    end if;
  end if;

  -- 3) fila nueva "por revisar"
  insert into public.movimientos (empresa, fecha, ingreso, egreso, detalle, tipo, desde, hacia, estado, informacion, factura, pagado, clara, comentarios, archivo, revisar, creado_por)
  values (p_empresa, v_fecha, case when v_ing then v_total end, case when v_ing then null else v_total end, v_det, v_tipo, v_desde, v_hacia, 'Pendiente',
          '[Factura](' || v_link || ')', 'Sí', false, false, v_nota, v_archivo, true, 'claude')
  returning id into v_id;
  return jsonb_build_object('estado', 'nueva', 'id', v_id, 'tipo', v_tipo, 'desde', v_desde, 'hacia', v_hacia, 'posible_duplicado', v_n > 0);
end;
$$;
revoke all on function public.subir_factura(text, jsonb, text) from public;
grant execute on function public.subir_factura(text, jsonb, text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 7. Pedidos de actualización de facturas (botón "Actualizar facturas")
-- ---------------------------------------------------------------
-- El botón de Finanzas deja un pedido ("revisá la carpeta de octubre"). Una
-- tarea programada en la Mac de Juan lo atiende: lee las facturas nuevas de
-- Drive, las sube con subir_factura() y marca el pedido como listo.
create table if not exists public.pedidos (
  id          bigint generated always as identity primary key,
  empresa     text not null default 'terrys-burgers-sl',
  tipo        text not null default 'facturas',
  periodo     text not null,                       -- '2026-10' (un mes) o '2026' (todo el año)
  estado      text not null default 'pendiente',   -- pendiente · en curso · listo · error
  resultado   jsonb,
  pedido_por  text default (auth.jwt() ->> 'email'),
  creado      timestamptz not null default now(),
  actualizado timestamptz not null default now()
);
alter table public.pedidos enable row level security;
revoke all on public.pedidos from anon, authenticated;
grant select, insert on public.pedidos to authenticated;
drop policy if exists pedidos_ver on public.pedidos;
create policy pedidos_ver on public.pedidos for select to authenticated using (public.es_admin());
drop policy if exists pedidos_crear on public.pedidos;
create policy pedidos_crear on public.pedidos for insert to authenticated with check (public.es_admin() and estado = 'pendiente');

-- Lo que usa la tarea de la Mac (token 'facturas'):
create or replace function public.pedidos_pendientes(p_token text, p_empresa text default 'terrys-burgers-sl')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._token_valido('facturas', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  -- un pedido "en curso" desde hace más de 30 minutos se considera caído y se vuelve a atender
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'periodo', periodo, 'estado', estado, 'creado', creado, 'pedido_por', pedido_por) order by id)
                     from public.pedidos
                    where empresa = p_empresa and tipo = 'facturas'
                      and (estado = 'pendiente' or (estado = 'en curso' and actualizado < now() - interval '30 minutes'))), '[]'::jsonb);
end;
$$;
revoke all on function public.pedidos_pendientes(text, text) from public;
grant execute on function public.pedidos_pendientes(text, text) to anon, authenticated;

create or replace function public.pedido_estado(p_token text, p_id bigint, p_estado text, p_resultado jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._token_valido('facturas', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  if p_estado not in ('pendiente', 'en curso', 'listo', 'error') then
    raise exception 'estado inválido' using errcode = '22023';
  end if;
  update public.pedidos set estado = p_estado, resultado = coalesce(p_resultado, resultado), actualizado = now() where id = p_id;
  return jsonb_build_object('ok', found, 'id', p_id, 'estado', p_estado);
end;
$$;
revoke all on function public.pedido_estado(text, bigint, text, jsonb) from public;
grant execute on function public.pedido_estado(text, bigint, text, jsonb) to anon, authenticated;

create or replace function public.pedido_crear(p_token text, p_periodo text, p_empresa text default 'terrys-burgers-sl')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id bigint;
begin
  if not public._token_valido('facturas', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  insert into public.pedidos (empresa, periodo, pedido_por) values (p_empresa, p_periodo, 'claude') returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;
revoke all on function public.pedido_crear(text, text, text) from public;
grant execute on function public.pedido_crear(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 9. Web pública (terrysburgers.com): reservas, consultas de eventos y agenda
-- ---------------------------------------------------------------
-- La web pública NO lee ni escribe estas tablas directo: solo llama a
-- web_reservar() / web_consulta_evento() (que validan y guardan) y lee la
-- agenda publicada. Todo lo demás lo ve y lo cambia solo un admin (es_admin()).

create table if not exists public.reservas (
  id          bigint generated always as identity primary key,
  creada      timestamptz not null default now(),
  fecha       date not null,
  hora        time not null,
  personas    int  not null check (personas between 1 and 30),
  nombre      text not null check (char_length(nombre) between 2 and 80),
  telefono    text not null check (char_length(telefono) between 6 and 30),
  email       text check (email is null or char_length(email) <= 120),
  comentario  text check (comentario is null or char_length(comentario) <= 500),
  estado      text not null default 'pendiente'
              check (estado in ('pendiente', 'confirmada', 'rechazada', 'cancelada')),
  nota        text,
  actualizada timestamptz not null default now()
);
create index if not exists reservas_fecha on public.reservas (fecha, hora);

create table if not exists public.eventos_consultas (
  id          bigint generated always as identity primary key,
  creada      timestamptz not null default now(),
  tipo        text not null check (tipo in ('privado', 'catering', 'otro')),
  nombre      text not null check (char_length(nombre) between 2 and 80),
  telefono    text not null check (char_length(telefono) between 6 and 30),
  email       text check (email is null or char_length(email) <= 120),
  fecha       date,
  personas    int check (personas is null or personas between 1 and 1000),
  mensaje     text check (mensaje is null or char_length(mensaje) <= 1500),
  estado      text not null default 'nueva' check (estado in ('nueva', 'respondida', 'cerrada')),
  nota        text,
  actualizada timestamptz not null default now()
);

create table if not exists public.agenda (
  id          bigint generated always as identity primary key,
  fecha       date not null,
  hora        text check (hora is null or char_length(hora) <= 40),
  titulo      text not null check (char_length(titulo) between 2 and 120),
  descripcion text check (descripcion is null or char_length(descripcion) <= 600),
  imagen_url  text check (imagen_url is null or imagen_url ~ '^https://'),
  publicado   boolean not null default true,
  creado      timestamptz not null default now()
);

alter table public.reservas          enable row level security;
alter table public.eventos_consultas enable row level security;
alter table public.agenda            enable row level security;
revoke all on public.reservas, public.eventos_consultas, public.agenda from anon, authenticated;
grant select, update, delete on public.reservas, public.eventos_consultas to authenticated;
grant select, insert, update, delete on public.agenda to authenticated;
grant select on public.agenda to anon;

drop policy if exists reservas_admin on public.reservas;
create policy reservas_admin on public.reservas for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
drop policy if exists eventos_consultas_admin on public.eventos_consultas;
create policy eventos_consultas_admin on public.eventos_consultas for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
drop policy if exists agenda_publica on public.agenda;
create policy agenda_publica on public.agenda for select to anon, authenticated
  using (publicado and fecha >= (now() at time zone 'Europe/Madrid')::date - 1);
drop policy if exists agenda_admin on public.agenda;
create policy agenda_admin on public.agenda for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- Texto vacío → null, recortado.
create or replace function public._txt(t text, maxlen int)
returns text language sql immutable as $$
  select nullif(left(btrim(coalesce(t, '')), maxlen), '');
$$;

-- Reserva desde la web. Horarios con reserva: 13:00–15:00 y 20:00–22:30
-- (cada 15 min), hasta 90 días adelante, de 1 a 30 personas (más → eventos).
-- Freno anti-abuso: 3 por teléfono por día y 200 en total por día.
create or replace function public.web_reservar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoy   date := (now() at time zone 'Europe/Madrid')::date;
  v_ahora time := (now() at time zone 'Europe/Madrid')::time;
  v_fecha date;
  v_hora  time;
  v_pers  int;
  v_tel   text := public._txt(p ->> 'telefono', 30);
  v_id    bigint;
begin
  if public._txt(p ->> 'web', 200) is not null then          -- campo trampa para bots
    return jsonb_build_object('ok', true);
  end if;
  begin
    v_fecha := (p ->> 'fecha')::date;
    v_hora  := (p ->> 'hora')::time;
    v_pers  := (p ->> 'personas')::int;
  exception when others then
    raise exception 'datos inválidos' using errcode = '22023';
  end;
  if v_fecha is null or v_fecha < v_hoy or v_fecha > v_hoy + 90 then
    raise exception 'fecha fuera de rango' using errcode = '22023';
  end if;
  if v_hora is null or extract(minute from v_hora)::int % 15 <> 0
     or not (v_hora between time '13:00' and time '15:00' or v_hora between time '20:00' and time '22:30') then
    raise exception 'horario sin reserva' using errcode = '22023';
  end if;
  if v_fecha = v_hoy and v_hora <= v_ahora + interval '30 minutes' then
    raise exception 'horario pasado' using errcode = '22023';
  end if;
  if v_pers is null or v_pers not between 1 and 30 then
    raise exception 'personas fuera de rango' using errcode = '22023';
  end if;
  if v_tel is null or v_tel !~ '^[0-9 +().-]{6,30}$' then
    raise exception 'teléfono inválido' using errcode = '22023';
  end if;
  if (select count(*) from public.reservas where telefono = v_tel and creada > now() - interval '1 day') >= 3
     or (select count(*) from public.reservas where creada > now() - interval '1 day') >= 200 then
    raise exception 'demasiadas reservas, llamanos' using errcode = '54000';
  end if;
  insert into public.reservas (fecha, hora, personas, nombre, telefono, email, comentario)
  values (v_fecha, v_hora, v_pers, public._txt(p ->> 'nombre', 80), v_tel,
          public._txt(p ->> 'email', 120), public._txt(p ->> 'comentario', 500))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;
revoke all on function public.web_reservar(jsonb) from public;
grant execute on function public.web_reservar(jsonb) to anon, authenticated;

-- Consulta de evento privado / catering desde la web.
create or replace function public.web_consulta_evento(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tel  text := public._txt(p ->> 'telefono', 30);
  v_fecha date;
  v_pers int;
  v_id   bigint;
begin
  if public._txt(p ->> 'web', 200) is not null then
    return jsonb_build_object('ok', true);
  end if;
  begin
    v_fecha := nullif(p ->> 'fecha', '')::date;
    v_pers  := nullif(p ->> 'personas', '')::int;
  exception when others then
    raise exception 'datos inválidos' using errcode = '22023';
  end;
  if v_tel is null or v_tel !~ '^[0-9 +().-]{6,30}$' then
    raise exception 'teléfono inválido' using errcode = '22023';
  end if;
  if (select count(*) from public.eventos_consultas where telefono = v_tel and creada > now() - interval '1 day') >= 3
     or (select count(*) from public.eventos_consultas where creada > now() - interval '1 day') >= 100 then
    raise exception 'demasiadas consultas, llamanos' using errcode = '54000';
  end if;
  insert into public.eventos_consultas (tipo, nombre, telefono, email, fecha, personas, mensaje)
  values (coalesce(nullif(p ->> 'tipo', ''), 'otro'), public._txt(p ->> 'nombre', 80), v_tel,
          public._txt(p ->> 'email', 120), v_fecha, v_pers, public._txt(p ->> 'mensaje', 1500))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;
revoke all on function public.web_consulta_evento(jsonb) from public;
grant execute on function public.web_consulta_evento(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------
-- 10. Aviso al celular cuando entra una reserva o una consulta de la web
-- ---------------------------------------------------------------
-- Manda una notificación push con ntfy (app gratis para iPhone/Android, sin
-- cuenta). El "tema" es como una contraseña: se genera y se guarda desde la
-- solapa Web del admin (nunca en este archivo, que es público). El aviso NO
-- lleva nombre ni teléfono del cliente: solo día, hora, personas y un link al admin.
-- Si el aviso falla, la reserva se guarda igual.

create extension if not exists pg_net with schema extensions;

create table if not exists public.web_avisos (
  id          int primary key default 1 check (id = 1),
  ntfy_tema   text check (ntfy_tema is null or ntfy_tema ~ '^[A-Za-z0-9_-]{12,64}$'),
  reservas    boolean not null default true,
  consultas   boolean not null default true,
  actualizado timestamptz not null default now()
);
insert into public.web_avisos (id) values (1) on conflict (id) do nothing;

alter table public.web_avisos enable row level security;
revoke all on public.web_avisos from anon, authenticated;
grant select, update on public.web_avisos to authenticated;
drop policy if exists web_avisos_admin on public.web_avisos;
create policy web_avisos_admin on public.web_avisos for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- "mié 11 nov" sin depender del idioma del servidor.
create or replace function public._dia_corto(d date)
returns text language sql immutable as $$
  select (array['dom','lun','mar','mié','jue','vie','sáb'])[extract(dow from d)::int + 1] || ' ' ||
         extract(day from d)::int || ' ' ||
         (array['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'])[extract(month from d)::int];
$$;

create or replace function public._aviso_ntfy(p_tema text, p_titulo text, p_mensaje text, p_tag text, p_prioridad int default 3)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_tema is null then return; end if;
  perform net.http_post(
    url  := 'https://ntfy.sh/',
    body := jsonb_build_object(
      'topic', p_tema, 'title', p_titulo, 'message', p_mensaje,
      'tags', jsonb_build_array(p_tag), 'priority', p_prioridad,
      'click', 'https://admin.terrysburgers.com/'));
exception when others then
  raise warning 'aviso ntfy no enviado: %', sqlerrm;   -- nunca frena la reserva
end;
$$;
revoke all on function public._aviso_ntfy(text, text, text, text, int) from public, anon, authenticated;

create or replace function public.web_avisar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.web_avisos;
  v_hoy date := (now() at time zone 'Europe/Madrid')::date;
begin
  select * into a from public.web_avisos where id = 1;
  if a.ntfy_tema is null then return new; end if;
  if tg_table_name = 'reservas' and a.reservas then
    perform public._aviso_ntfy(a.ntfy_tema,
      case when new.fecha = v_hoy then 'Reserva nueva para HOY' else 'Reserva nueva' end,
      public._dia_corto(new.fecha) || ' · ' || to_char(new.hora, 'HH24:MI') || ' · ' ||
        new.personas || case when new.personas = 1 then ' persona' else ' personas' end,
      'hamburger', case when new.fecha = v_hoy then 5 else 4 end);
  elsif tg_table_name = 'eventos_consultas' and a.consultas then
    perform public._aviso_ntfy(a.ntfy_tema, 'Consulta de evento',
      case new.tipo when 'privado' then 'Evento privado' when 'catering' then 'Catering' else 'Otra consulta' end ||
        coalesce(' · ' || public._dia_corto(new.fecha), '') ||
        coalesce(' · ' || new.personas || ' personas', ''),
      'tada', 4);
  end if;
  return new;
end;
$$;
revoke all on function public.web_avisar() from public, anon, authenticated;

drop trigger if exists reservas_avisar on public.reservas;
create trigger reservas_avisar after insert on public.reservas
  for each row execute function public.web_avisar();
drop trigger if exists eventos_consultas_avisar on public.eventos_consultas;
create trigger eventos_consultas_avisar after insert on public.eventos_consultas
  for each row execute function public.web_avisar();

-- Botón "Probar aviso" del admin.
create or replace function public.web_probar_aviso()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_tema text;
begin
  if not public.es_admin() then raise exception 'sin permiso' using errcode = '42501'; end if;
  select ntfy_tema into v_tema from public.web_avisos where id = 1;
  if v_tema is null then raise exception 'falta el tema de ntfy' using errcode = '22023'; end if;
  perform public._aviso_ntfy(v_tema, 'Prueba de Terry''s',
    'Si ves esto, los avisos de reservas funcionan 🍔', 'white_check_mark', 3);
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.web_probar_aviso() from public, anon;
grant execute on function public.web_probar_aviso() to authenticated;

-- ---------------------------------------------------------------
-- 11. Reservas online de hasta 30 personas
-- ---------------------------------------------------------------
-- Para bases creadas antes: cambia el límite de la tabla. La función
-- web_reservar() de la parte 9 ya acepta hasta 30.
alter table public.reservas drop constraint if exists reservas_personas_check;
alter table public.reservas add constraint reservas_personas_check check (personas between 1 and 30);

-- ---------------------------------------------------------------
-- 12. Pedidos take away desde la web (terrysburgers.com/pedido/)
-- ---------------------------------------------------------------
-- Igual que las reservas: la web solo llama a web_pedir() (parte 13), que valida
-- el horario, arma las líneas y calcula el total con los precios de la tabla
-- productos (no confía en lo que manda el navegador).
-- Por ahora se paga en el local al retirar.

create table if not exists public.pedidos_take (
  id          bigint generated always as identity primary key,
  creado      timestamptz not null default now(),
  dia         date not null,
  hora        time not null,
  nombre      text not null check (char_length(nombre) between 2 and 80),
  telefono    text not null check (char_length(telefono) between 6 and 30),
  comentario  text check (comentario is null or char_length(comentario) <= 500),
  items       jsonb not null,           -- [{id, nombre, extra, cant, precio}]
  unidades    int not null check (unidades between 1 and 200),
  total       numeric(8,2) not null check (total >= 0),
  estado      text not null default 'nuevo'
              check (estado in ('nuevo', 'preparando', 'listo', 'entregado', 'cancelado')),
  nota        text,
  actualizado timestamptz not null default now()
);
create index if not exists pedidos_take_dia on public.pedidos_take (dia, hora);

alter table public.pedidos_take enable row level security;
revoke all on public.pedidos_take from anon, authenticated;
grant select, update, delete on public.pedidos_take to authenticated;
drop policy if exists pedidos_take_admin on public.pedidos_take;
create policy pedidos_take_admin on public.pedidos_take for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- web_pedir(): está en la parte 13 (cobra con los precios de la tabla productos).

-- Aviso al celular también para los pedidos (reemplaza la web_avisar() de la parte 10).
alter table public.web_avisos add column if not exists pedidos boolean not null default true;

create or replace function public.web_avisar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.web_avisos;
  v_hoy date := (now() at time zone 'Europe/Madrid')::date;
begin
  select * into a from public.web_avisos where id = 1;
  if a.ntfy_tema is null then return new; end if;
  if tg_table_name = 'reservas' and a.reservas then
    perform public._aviso_ntfy(a.ntfy_tema,
      case when new.fecha = v_hoy then 'Reserva nueva para HOY' else 'Reserva nueva' end,
      public._dia_corto(new.fecha) || ' · ' || to_char(new.hora, 'HH24:MI') || ' · ' ||
        new.personas || case when new.personas = 1 then ' persona' else ' personas' end,
      'hamburger', case when new.fecha = v_hoy then 5 else 4 end);
  elsif tg_table_name = 'eventos_consultas' and a.consultas then
    perform public._aviso_ntfy(a.ntfy_tema, 'Consulta de evento',
      case new.tipo when 'privado' then 'Evento privado' when 'catering' then 'Catering' else 'Otra consulta' end ||
        coalesce(' · ' || public._dia_corto(new.fecha), '') ||
        coalesce(' · ' || new.personas || ' personas', ''),
      'tada', 4);
  elsif tg_table_name = 'pedidos_take' and a.pedidos then
    perform public._aviso_ntfy(a.ntfy_tema,
      case when new.dia = v_hoy then 'Pedido take away para HOY' else 'Pedido take away' end,
      public._dia_corto(new.dia) || ' · retira ' || to_char(new.hora, 'HH24:MI') || ' · ' ||
        new.unidades || case when new.unidades = 1 then ' producto' else ' productos' end || ' · ' ||
        replace(to_char(new.total, 'FM9990.00'), '.', ',') || ' €',
      'takeout_box', 5);
  end if;
  return new;
end;
$$;
revoke all on function public.web_avisar() from public, anon, authenticated;

drop trigger if exists pedidos_take_avisar on public.pedidos_take;
create trigger pedidos_take_avisar after insert on public.pedidos_take
  for each row execute function public.web_avisar();

-- ---------------------------------------------------------------
-- 13. Productos (carta de la página de pedidos) editables desde el admin
-- ---------------------------------------------------------------
-- La solapa Pedidos del admin carga, edita y saca productos; la página
-- terrysburgers.com/pedido/ los lee de acá (solo los activos y marcados para
-- take away) y web_pedir() cobra con estos precios. "terraza" queda marcado
-- para cuando se pueda pedir desde la mesa.
-- Las fotos se suben al bucket público "productos" de Supabase Storage.

create table if not exists public.productos (
  id           text primary key check (id ~ '^[a-z0-9-]{2,40}$'),
  categoria    text not null check (categoria in ('burgers', 'picar', 'bebidas', 'postres')),
  nombre       text not null check (char_length(nombre) between 2 and 60),
  descripcion  text check (descripcion is null or char_length(descripcion) <= 200),
  precio       numeric(6,2) not null check (precio >= 0),          -- simple / único
  precio_doble numeric(6,2) check (precio_doble is null or precio_doble >= 0),
  salsas       text[],                                             -- si tiene, hay que elegir una
  foto_url     text check (foto_url is null or foto_url ~ '^https://'),
  take_away    boolean not null default true,
  terraza      boolean not null default true,
  activo       boolean not null default true,
  orden        int not null default 100,
  actualizado  timestamptz not null default now()
);

alter table public.productos enable row level security;
revoke all on public.productos from anon, authenticated;
grant select on public.productos to anon;
grant select, insert, update, delete on public.productos to authenticated;
drop policy if exists productos_publicos on public.productos;
create policy productos_publicos on public.productos for select to anon, authenticated
  using (activo);
drop policy if exists productos_admin on public.productos;
create policy productos_admin on public.productos for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- Carta 2026 de arranque (si ya existen, no se pisan).
insert into public.productos (id, categoria, nombre, descripcion, precio, precio_doble, salsas, foto_url, orden) values
  ('terry',  'burgers', 'Terry',  'Con doble cheddar',                              7.90,  9.90, null, 'https://terrysburgers.com/assets/img/burgers/terry.jpg',  10),
  ('torch',  'burgers', 'Torch',  'Con doble cheddar y bacon',                      9.50, 11.50, null, 'https://terrysburgers.com/assets/img/burgers/torch.jpg',  20),
  ('russel', 'burgers', 'Russel', 'Con cheddar, lechuga, tomate y salsa mil islas', 9.00, 11.00, null, 'https://terrysburgers.com/assets/img/burgers/russel.jpg', 30),
  ('zulma',  'burgers', 'Zulma',  'Con cheddar, ketchup, mostaza y cebolla picada', 9.00, 11.00, null, 'https://terrysburgers.com/assets/img/burgers/zulma.jpg',  40),
  ('rumpi',  'burgers', 'Rumpi',  'Con cheddar y cebolla smasheada',                9.00, 11.00, null, 'https://terrysburgers.com/assets/img/burgers/rumpy.jpg',  50),
  ('buba',   'burgers', 'Buba',   'Con muzzarellitas, cheddar y barbacoa',          9.50, 11.50, null, 'https://terrysburgers.com/assets/img/burgers/buba.jpg',   60),
  ('patatas',        'picar', 'Patatas fritas',  null,                                   4.00, null, null, null, 10),
  ('patatas-russel', 'picar', 'Patatas Russel',  'Con salsa mil islas y bacon crocante', 6.00, null, null, null, 20),
  ('patatas-torch',  'picar', 'Patatas Torch',   'Con cheddar y bacon crocante',         6.00, null, null, null, 30),
  ('boniatos',       'picar', 'Boniatos',        null,                                   6.00, null, null, null, 40),
  ('muzzarellitas',  'picar', 'Muzzarellitas',   '8 unidades · elegí la salsa', 8.50, null, array['Barbacoa','Cheddar','Alioli'], null, 50),
  ('nuggets',        'picar', 'Nuggets',         '8 unidades · elegí la salsa', 8.50, null, array['Barbacoa','Cheddar','Alioli'], null, 60),
  ('aros',           'picar', 'Aros de cebolla', '8 unidades · elegí la salsa', 8.50, null, array['Barbacoa','Cheddar','Alioli'], null, 70),
  ('agua',       'bebidas', 'Agua mineral',      null, 2.20, null, null, null, 10),
  ('aquarius',   'bebidas', 'Aquarius',          null, 2.50, null, null, null, 20),
  ('cocacola',   'bebidas', 'Bebidas Coca-Cola', null, 2.50, null, null, null, 30),
  ('estrella',   'bebidas', 'Estrella Damm',     null, 2.90, null, null, null, 40),
  ('estrella00', 'bebidas', 'Estrella Damm 0,0', null, 2.90, null, null, null, 50),
  ('turia',      'bebidas', 'Turia',             null, 3.50, null, null, null, 60),
  ('damm-lemon', 'bebidas', 'Damm Lemon',        null, 3.20, null, null, null, 70),
  ('quilmes',    'bebidas', 'Quilmes Argentina', null, 3.70, null, null, null, 80),
  ('vino',       'bebidas', 'Copa de vino',      null, 3.20, null, null, null, 90),
  ('franui',     'postres', 'Franui', 'Frambuesas frescas bañadas en doble chocolate', 5.50, null, null, null, 10)
on conflict (id) do nothing;

-- Fotos: bucket público (cualquiera puede ver la foto), solo un admin sube o borra.
insert into storage.buckets (id, name, public) values ('productos', 'productos', true)
on conflict (id) do nothing;
drop policy if exists productos_fotos_admin_ins on storage.objects;
create policy productos_fotos_admin_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'productos' and public.es_admin());
drop policy if exists productos_fotos_admin_upd on storage.objects;
create policy productos_fotos_admin_upd on storage.objects for update to authenticated
  using (bucket_id = 'productos' and public.es_admin());
drop policy if exists productos_fotos_admin_del on storage.objects;
create policy productos_fotos_admin_del on storage.objects for delete to authenticated
  using (bucket_id = 'productos' and public.es_admin());

-- Pedido take away: cobra con los precios de la tabla productos.
-- items: [{id, variante: 'simple'|'doble'|null, salsa: text|null, cant}]
create or replace function public.web_pedir(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoy   date := (now() at time zone 'Europe/Madrid')::date;
  v_ahora time := (now() at time zone 'Europe/Madrid')::time;
  v_dia   date;
  v_hora  time;
  v_tel   text := public._txt(p ->> 'telefono', 30);
  v_it    jsonb;
  v_pr    public.productos;
  v_var   text;
  v_salsa text;
  v_cant  int;
  v_precio numeric(6,2);
  v_lineas jsonb := '[]';
  v_unid  int := 0;
  v_total numeric(8,2) := 0;
  v_pid   bigint;
begin
  if public._txt(p ->> 'web', 200) is not null then          -- campo trampa para bots
    return jsonb_build_object('ok', true);
  end if;
  begin
    v_dia  := (p ->> 'dia')::date;
    v_hora := (p ->> 'hora')::time;
  exception when others then
    raise exception 'datos inválidos' using errcode = '22023';
  end;
  if v_dia is null or v_dia < v_hoy or v_dia > v_hoy + 1 then
    raise exception 'día fuera de rango' using errcode = '22023';
  end if;
  -- se recoge desde 15 min después de abrir hasta el cierre, cada 15 min
  if v_hora is null or extract(minute from v_hora)::int % 15 <> 0
     or not (v_hora between time '13:15' and time '15:30' or v_hora between time '20:15' and time '23:00') then
    raise exception 'horario sin pedidos' using errcode = '22023';
  end if;
  if v_dia = v_hoy and v_hora < v_ahora + interval '30 minutes' then
    raise exception 'horario pasado' using errcode = '22023';
  end if;
  if v_tel is null or v_tel !~ '^[0-9 +().-]{6,30}$' then
    raise exception 'teléfono inválido' using errcode = '22023';
  end if;
  if public._txt(p ->> 'nombre', 80) is null or char_length(public._txt(p ->> 'nombre', 80)) < 2 then
    raise exception 'falta el nombre' using errcode = '22023';
  end if;
  if jsonb_typeof(p -> 'items') <> 'array' or jsonb_array_length(p -> 'items') not between 1 and 60 then
    raise exception 'pedido vacío' using errcode = '22023';
  end if;

  for v_it in select * from jsonb_array_elements(p -> 'items') loop
    select * into v_pr from public.productos
      where id = left(coalesce(v_it ->> 'id', ''), 40) and activo and take_away;
    v_var   := nullif(v_it ->> 'variante', '');
    v_salsa := nullif(v_it ->> 'salsa', '');
    begin v_cant := (v_it ->> 'cant')::int; exception when others then v_cant := null; end;
    if v_pr.id is null or v_cant is null or v_cant not between 1 and 50 then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    -- con precio doble hay que elegir simple o doble; sin precio doble, nada
    if v_pr.precio_doble is not null then
      if v_var is null or v_var not in ('simple', 'doble') then raise exception 'producto inválido' using errcode = '22023'; end if;
    elsif v_var is not null then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    -- con salsas hay que elegir una de la lista; sin salsas, ninguna
    if coalesce(cardinality(v_pr.salsas), 0) > 0 then
      if v_salsa is null or not (v_salsa = any(v_pr.salsas)) then raise exception 'producto inválido' using errcode = '22023'; end if;
    elsif v_salsa is not null then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    v_precio := case when v_var = 'doble' then v_pr.precio_doble else v_pr.precio end;
    v_lineas := v_lineas || jsonb_build_object(
      'id', v_pr.id, 'nombre', v_pr.nombre,
      'extra', case when v_var is not null then initcap(v_var) when v_salsa is not null then 'Salsa ' || lower(v_salsa) end,
      'cant', v_cant, 'precio', v_precio);
    v_unid  := v_unid + v_cant;
    v_total := v_total + v_cant * v_precio;
  end loop;
  if v_unid > 200 then raise exception 'pedido demasiado grande' using errcode = '22023'; end if;

  if (select count(*) from public.pedidos_take where telefono = v_tel and creado > now() - interval '1 day') >= 5
     or (select count(*) from public.pedidos_take where creado > now() - interval '1 day') >= 300 then
    raise exception 'demasiados pedidos, llamanos' using errcode = '54000';
  end if;

  insert into public.pedidos_take (dia, hora, nombre, telefono, comentario, items, unidades, total)
  values (v_dia, v_hora, public._txt(p ->> 'nombre', 80), v_tel, public._txt(p ->> 'comentario', 500),
          v_lineas, v_unid, v_total)
  returning id into v_pid;
  return jsonb_build_object('ok', true, 'id', v_pid, 'total', v_total);
end;
$$;
revoke all on function public.web_pedir(jsonb) from public;
grant execute on function public.web_pedir(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------
-- 14. Pedidos take away → Ágora (programa enviar-pedidos.ps1 en el TPV)
-- ---------------------------------------------------------------
-- El TPV pregunta cada 15 s por los pedidos nuevos (agora_pendientes) y los carga
-- en Ágora en la serie WEB; después avisa cómo le fue (agora_marcar). Usa el mismo
-- token 'agora' que subir-ventas.ps1. Cada producto de la web dice qué producto de
-- Ágora es (agora_id, y agora_id_doble para la versión doble) y, si tiene salsas,
-- qué producto de Ágora es cada salsa (agora_salsas: {"Barbacoa": 2167, ...}).

alter table public.productos add column if not exists agora_id int;
alter table public.productos add column if not exists agora_id_doble int;
alter table public.productos add column if not exists agora_salsas jsonb;

alter table public.pedidos_take add column if not exists agora_estado text
  check (agora_estado is null or agora_estado in ('enviado', 'error'));
alter table public.pedidos_take add column if not exists agora_numero int;
alter table public.pedidos_take add column if not exists agora_error text;
alter table public.pedidos_take add column if not exists agora_enviado timestamptz;
alter table public.pedidos_take add column if not exists agora_intentos int not null default 0;

-- Códigos de Ágora de la carta 2026 (versiones TAKE AWAY). Se pueden cambiar en la solapa Pedidos.
update public.productos p set agora_id = v.a, agora_id_doble = v.d, agora_salsas = v.s
from (values
  ('terry', 3194, 3197, null::jsonb), ('torch', 3198, 3199, null), ('russel', 3204, 3205, null),
  ('zulma', 3200, 3201, null), ('rumpi', 3202, 3203, null), ('buba', 3206, 3207, null),
  ('patatas', 3190, null, null), ('patatas-russel', 3196, null, null), ('patatas-torch', 3195, null, null),
  ('boniatos', 3215, null, null),
  ('muzzarellitas', 3191, null, '{"Barbacoa": 2167, "Cheddar": 2166, "Alioli": 2165}'),
  ('nuggets',       3192, null, '{"Barbacoa": 2167, "Cheddar": 2166, "Alioli": 2165}'),
  ('aros',          3193, null, '{"Barbacoa": 2167, "Cheddar": 2166, "Alioli": 2165}'),
  ('agua', 3217, null, null), ('aquarius', 3208, null, null), ('cocacola', 3187, null, null),
  ('estrella', 2159, null, null), ('estrella00', 2158, null, null), ('turia', 2051, null, null),
  ('damm-lemon', 3225, null, null), ('quilmes', 3216, null, null), ('vino', 3264, null, null),
  ('franui', 2053, null, null)
) as v(id, a, d, s)
where p.id = v.id and p.agora_id is null;

-- Los pedidos que ya existían (pruebas) no se mandan.
update public.pedidos_take set agora_estado = 'error', agora_intentos = 5,
       agora_error = 'Anterior a la conexión con Ágora (no se manda)'
 where agora_estado is null;

-- Pedidos para mandar a Ágora: los que no se mandaron (o fallaron menos de 5 veces),
-- no cancelados y para hoy o mañana. Cada línea trae el código de Ágora ya resuelto.
create or replace function public.agora_pendientes(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoy date := (now() at time zone 'Europe/Madrid')::date;
  r public.pedidos_take;
  l jsonb;
  pr public.productos;
  v_extra text; v_var text; v_salsa text; v_agora int; v_addin int;
  v_lineas jsonb;
  v_out jsonb := '[]';
begin
  if not public._token_valido('agora', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  update public.integraciones set ultimo_uso = now() where nombre = 'agora';
  for r in select * from public.pedidos_take
            where estado <> 'cancelado' and dia >= v_hoy
              and (agora_estado is null or (agora_estado = 'error' and agora_intentos < 5))
            order by creado limit 20 loop
    v_lineas := '[]';
    for l in select * from jsonb_array_elements(r.items) loop
      select * into pr from public.productos where id = l ->> 'id';
      v_extra := coalesce(l ->> 'extra', '');
      v_var   := case when lower(v_extra) in ('simple', 'doble') then lower(v_extra) end;
      v_salsa := case when v_extra ilike 'Salsa %' then substr(v_extra, 7) end;
      v_agora := case when v_var = 'doble' then pr.agora_id_doble else pr.agora_id end;
      v_addin := null;
      if v_salsa is not null and pr.agora_salsas is not null then
        select value::int into v_addin from jsonb_each_text(pr.agora_salsas) where lower(key) = lower(v_salsa) limit 1;
      end if;
      v_lineas := v_lineas || jsonb_build_object(
        'id', l ->> 'id', 'nombre', l ->> 'nombre', 'extra', nullif(v_extra, ''),
        'cant', (l ->> 'cant')::int, 'precio', (l ->> 'precio')::numeric,
        'agora_id', v_agora, 'agora_salsa', v_addin, 'salsa', v_salsa);
    end loop;
    v_out := v_out || jsonb_build_object(
      'id', r.id, 'creado', r.creado, 'dia', r.dia, 'hora', to_char(r.hora, 'HH24:MI'),
      'nombre', r.nombre, 'telefono', r.telefono, 'comentario', r.comentario,
      'total', r.total, 'pagado', false, 'lineas', v_lineas, 'intentos', r.agora_intentos);
  end loop;
  return v_out;
end;
$$;
revoke all on function public.agora_pendientes(text) from public;
grant execute on function public.agora_pendientes(text) to anon, authenticated;

-- El TPV avisa cómo le fue: ok → 'enviado' con el número de Ágora; si no, 'error' con el motivo.
create or replace function public.agora_marcar(p_token text, p_id bigint, p_ok boolean, p_numero int default null, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._token_valido('agora', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  update public.pedidos_take set
    agora_estado   = case when p_ok then 'enviado' else 'error' end,
    agora_numero   = case when p_ok then p_numero else agora_numero end,
    agora_error    = case when p_ok then null else left(p_error, 500) end,
    agora_enviado  = case when p_ok then now() else agora_enviado end,
    agora_intentos = agora_intentos + case when p_ok then 0 else 1 end
  where id = p_id;
end;
$$;
revoke all on function public.agora_marcar(text, bigint, boolean, int, text) from public;
grant execute on function public.agora_marcar(text, bigint, boolean, int, text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 15. Avisos ntfy con cuenta propia (token)
-- ---------------------------------------------------------------
-- Sin cuenta, ntfy.sh limita los mensajes por dirección IP, y la de Supabase la
-- comparten muchos proyectos: el cupo diario se agota ("429 daily message quota
-- reached") y no llegan los avisos. Con el token de una cuenta gratis de ntfy.sh,
-- el límite pasa a ser el de esa cuenta. El token se pega en el admin (panel
-- Avisos al celular) y queda solo en esta tabla, que solo leen los admins.

alter table public.web_avisos add column if not exists ntfy_token text
  check (ntfy_token is null or ntfy_token ~ '^tk_[A-Za-z0-9]{10,64}$');

create or replace function public._aviso_ntfy(p_tema text, p_titulo text, p_mensaje text, p_tag text, p_prioridad int default 3)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
begin
  if p_tema is null then return; end if;
  select ntfy_token into v_token from public.web_avisos where id = 1;
  perform net.http_post(
    url  := 'https://ntfy.sh/',
    body := jsonb_build_object(
      'topic', p_tema, 'title', p_titulo, 'message', p_mensaje,
      'tags', jsonb_build_array(p_tag), 'priority', p_prioridad,
      'click', 'https://admin.terrysburgers.com/'),
    headers := case when v_token is null then '{"Content-Type": "application/json"}'::jsonb
                    else jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_token) end);
exception when others then
  raise warning 'aviso ntfy no enviado: %', sqlerrm;   -- nunca frena la reserva ni el pedido
end;
$$;
revoke all on function public._aviso_ntfy(text, text, text, text, int) from public, anon, authenticated;

-- ---------------------------------------------------------------
-- 16. Aviso de pedidos take away desde el TPV
-- ---------------------------------------------------------------
-- ntfy.sh gratis limita por IP y la de Supabase es compartida (429). Los avisos
-- de pedidos los manda ahora enviar-pedidos.ps1 desde la conexión del local:
-- le pide a Supabase los pedidos sin avisar (con el tema y el texto ya armados)
-- y después los marca. Solo pedidos de las últimas 6 horas (si el TPV estuvo
-- apagado no llega una avalancha de avisos viejos).

alter table public.pedidos_take add column if not exists avisado timestamptz;
update public.pedidos_take set avisado = coalesce(avisado, now()) where avisado is null;

-- Supabase ya no intenta avisar los pedidos (reservas y consultas siguen igual).
drop trigger if exists pedidos_take_avisar on public.pedidos_take;

create or replace function public.tpv_avisos_pendientes(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.web_avisos;
  v_hoy date := (now() at time zone 'Europe/Madrid')::date;
begin
  if not public._token_valido('agora', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  select * into a from public.web_avisos where id = 1;
  if a.ntfy_tema is null or not coalesce(a.pedidos, true) then
    return jsonb_build_object('tema', null, 'avisos', '[]'::jsonb);
  end if;
  return jsonb_build_object('tema', a.ntfy_tema, 'avisos', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id,
      'titulo', case when p.dia = v_hoy then 'Pedido take away para HOY' else 'Pedido take away' end,
      'mensaje', public._dia_corto(p.dia) || ' · retira ' || to_char(p.hora, 'HH24:MI') || ' · ' ||
                 p.unidades || case when p.unidades = 1 then ' producto' else ' productos' end || ' · ' ||
                 replace(to_char(p.total, 'FM9990.00'), '.', ',') || ' €',
      'prioridad', case when p.dia = v_hoy then 5 else 4 end) order by p.creado)
    from public.pedidos_take p
    where p.avisado is null and p.estado <> 'cancelado' and p.creado > now() - interval '6 hours'), '[]'::jsonb));
end;
$$;
revoke all on function public.tpv_avisos_pendientes(text) from public;
grant execute on function public.tpv_avisos_pendientes(text) to anon, authenticated;

create or replace function public.tpv_aviso_marcar(p_token text, p_ids bigint[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._token_valido('agora', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  update public.pedidos_take set avisado = now() where id = any(p_ids) and avisado is null;
end;
$$;
revoke all on function public.tpv_aviso_marcar(text, bigint[]) from public;
grant execute on function public.tpv_aviso_marcar(text, bigint[]) to anon, authenticated;
