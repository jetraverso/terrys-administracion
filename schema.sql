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
  -- Datos sueltos: el texto lo arma el TPV (sin nombre ni teléfono del cliente).
  return jsonb_build_object('tema', a.ntfy_tema, 'avisos', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'dia', to_char(p.dia, 'DD/MM'), 'hora', to_char(p.hora, 'HH24:MI'),
      'cuando', case when p.dia = v_hoy then 'hoy' when p.dia = v_hoy + 1 then 'manana' else 'otro' end,
      'unidades', p.unidades, 'total', p.total, 'comentario', p.comentario is not null,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('cant', i ->> 'cant', 'nombre', i ->> 'nombre', 'extra', i ->> 'extra')), '[]'::jsonb)
                  from jsonb_array_elements(p.items) i)) order by p.creado)
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

-- ---------------------------------------------------------------
-- 17. Estado de los pedidos en Ágora → admin
-- ---------------------------------------------------------------
-- Cada 30 s el TPV exporta de Ágora los pedidos de la serie WEB y manda su estado
-- (agora_estados). La API de Ágora solo distingue Pending, Cancelled e Invoiced:
-- anulado en Ágora → 'cancelado'; cobrado (facturado) en Ágora → 'entregado'.

alter table public.pedidos_take add column if not exists agora_status text;
alter table public.pedidos_take add column if not exists agora_status_at timestamptz;

-- p_estados: [{"numero": 105, "status": "Invoiced"}, ...]  → cuántos pedidos cambiaron
create or replace function public.agora_estados(p_token text, p_estados jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  e jsonb;
  v_status text;
  v_n int := 0;
  v_filas int;
begin
  if not public._token_valido('agora', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  if jsonb_typeof(p_estados) <> 'array' then return 0; end if;
  for e in select * from jsonb_array_elements(p_estados) loop
    v_status := left(e ->> 'status', 30);
    update public.pedidos_take set
      agora_status = v_status,
      agora_status_at = now(),
      estado = case
        when v_status = 'Cancelled' and estado <> 'cancelado' then 'cancelado'
        when v_status = 'Invoiced' and estado not in ('entregado', 'cancelado') then 'entregado'
        else estado end,
      actualizado = case
        when (v_status = 'Cancelled' and estado <> 'cancelado')
          or (v_status = 'Invoiced' and estado not in ('entregado', 'cancelado')) then now()
        else actualizado end
    where agora_numero = (e ->> 'numero')::int
      and agora_estado = 'enviado'
      and agora_status is distinct from v_status;
    get diagnostics v_filas = row_count;
    v_n := v_n + v_filas;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.agora_estados(text, jsonb) from public;
grant execute on function public.agora_estados(text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------
-- 18. Carta de pedidos sincronizada con Ágora (extras, quitar, salsas y menús)
-- ---------------------------------------------------------------
-- El TPV sube cada hora el catálogo de Ágora (agora_subir_catalogo): producto,
-- precio de la tarifa Local y sus grupos de opciones (EXTRA, QUITAR, SALSA,
-- HAMBURGUESA SIMPLE, BEBIDA…, con mínimo, máximo y precio de cada opción).
-- La tabla productos sigue siendo la carta de la web (qué se muestra, nombre
-- lindo, foto, descripción, orden), pero el precio y las opciones salen de
-- Ágora por agora_id / agora_id_doble. web_carta() arma la carta para la página
-- y web_pedir() valida y cobra las opciones con esos mismos datos.

create table if not exists public.agora_catalogo (
  id          int primary key,             -- ProductId de Ágora
  nombre      text not null,
  cocina      text,                        -- orden de preparación (Bebidas, Fritos, Hamburguesas…)
  precio      numeric(6,2),                -- tarifa Local (la que usa el centro TAKE AWAY)
  roles       jsonb not null default '[]', -- [{nombre, min, max, opciones:[{id, nombre, precio}]}]
  activo      boolean not null default true,
  actualizado timestamptz not null default now()
);
alter table public.agora_catalogo enable row level security;
revoke all on public.agora_catalogo from anon, authenticated;
grant select on public.agora_catalogo to authenticated;
drop policy if exists agora_catalogo_admin on public.agora_catalogo;
create policy agora_catalogo_admin on public.agora_catalogo for select to authenticated using (public.es_admin());

-- Menús como categoría propia.
alter table public.productos drop constraint if exists productos_categoria_check;
alter table public.productos add constraint productos_categoria_check
  check (categoria in ('burgers', 'menus', 'picar', 'bebidas', 'postres'));

-- El TPV sube el catálogo entero; lo que ya no viene queda inactivo.
create or replace function public.agora_subir_catalogo(p_token text, p_productos jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_n int;
begin
  if not public._token_valido('agora', p_token) then
    raise exception 'token inválido' using errcode = '28000';
  end if;
  if jsonb_typeof(p_productos) <> 'array' or jsonb_array_length(p_productos) = 0 then return 0; end if;
  insert into public.agora_catalogo (id, nombre, cocina, precio, roles, activo, actualizado)
  select (x ->> 'id')::int, left(x ->> 'nombre', 120), left(x ->> 'cocina', 60),
         nullif(x ->> 'precio', '')::numeric, coalesce(x -> 'roles', '[]'::jsonb), true, now()
    from jsonb_array_elements(p_productos) x
  on conflict (id) do update set nombre = excluded.nombre, cocina = excluded.cocina, precio = excluded.precio,
    roles = excluded.roles, activo = true, actualizado = now();
  get diagnostics v_n = row_count;
  update public.agora_catalogo set activo = false, actualizado = now()
   where activo and id not in (select (x ->> 'id')::int from jsonb_array_elements(p_productos) x);
  return v_n;
end;
$$;
revoke all on function public.agora_subir_catalogo(text, jsonb) from public;
grant execute on function public.agora_subir_catalogo(text, jsonb) to anon, authenticated;

-- "EXTRA MEDALLÓN" → "Extra medallón", "POTE ALIOLI" → "Alioli", "RUMPI DOBLE TAKE AWAY" → "Rumpi doble"
create or replace function public._nombre_lindo(t text)
returns text
language sql
immutable
as $$
  select case when x is null or x = '' then x
              else upper(left(x, 1)) || translate(lower(substr(x, 2)), 'ÁÉÍÓÚÑÜÀÈÌÒÙÇ', 'áéíóúñüàèìòùç') end
    from (select btrim(regexp_replace(regexp_replace(t, '\s+TAKE\s+AWAY\s*$', '', 'i'), '^POTE\s+', '', 'i')) as x) s;
$$;

-- Una variante de un producto de la web: precio y opciones (de Ágora si está en el catálogo;
-- si no, el precio del admin y, si tiene salsas cargadas a mano, un grupo "Salsa").
create or replace function public._carta_variante(pr public.productos, p_var text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_aid int := case when p_var = 'doble' then pr.agora_id_doble else pr.agora_id end;
  c public.agora_catalogo;
  v_roles jsonb := '[]';
begin
  select * into c from public.agora_catalogo where id = v_aid and activo;
  if c.id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'nombre', public._nombre_lindo(r ->> 'nombre'),
             'min', coalesce((r ->> 'min')::int, 0), 'max', greatest(coalesce((r ->> 'max')::int, 1), 1),
             'opciones', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'id', (o ->> 'id')::int, 'nombre', public._nombre_lindo(o ->> 'nombre'),
                                 'precio', coalesce(nullif(o ->> 'precio', '')::numeric, 0))), '[]'::jsonb)
                            from jsonb_array_elements(r -> 'opciones') o))), '[]'::jsonb)
      into v_roles
      from jsonb_array_elements(c.roles) r
     where jsonb_array_length(coalesce(r -> 'opciones', '[]'::jsonb)) > 0;
  elsif coalesce(cardinality(pr.salsas), 0) > 0 then
    v_roles := jsonb_build_array(jsonb_build_object('nombre', 'Salsa', 'min', 1, 'max', 1,
      'opciones', (select jsonb_agg(jsonb_build_object(
                      'id', coalesce((select value::int from jsonb_each_text(coalesce(pr.agora_salsas, '{}')) where lower(key) = lower(s) limit 1), -n::int),
                      'nombre', s, 'precio', 0) order by n)
                     from unnest(pr.salsas) with ordinality as u(s, n))));
  end if;
  return jsonb_build_object(
    'v', coalesce(p_var, ''), 'agora_id', v_aid,
    'precio', coalesce(c.precio, case when p_var = 'doble' then pr.precio_doble else pr.precio end),
    'roles', v_roles);
end;
$$;
revoke all on function public._carta_variante(public.productos, text) from public, anon, authenticated;

-- Carta para terrysburgers.com/pedido/ (productos activos con take away).
create or replace function public.web_carta()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'categoria', p.categoria, 'nombre', p.nombre, 'descripcion', p.descripcion,
           'foto_url', p.foto_url,
           'variantes', case when p.agora_id_doble is not null or p.precio_doble is not null
                             then jsonb_build_array(public._carta_variante(p, 'simple'), public._carta_variante(p, 'doble'))
                             else jsonb_build_array(public._carta_variante(p, null)) end)
         order by p.orden, p.nombre), '[]'::jsonb)
    from public.productos p
   where p.activo and p.take_away;
$$;
revoke all on function public.web_carta() from public;
grant execute on function public.web_carta() to anon, authenticated;

-- Pedido take away: cobra con los precios y opciones de la carta (Ágora).
-- items: [{id, variante: 'simple'|'doble'|null, cant, opciones: [id de Ágora, ...]}]
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
  v_doble boolean;
  v_var   text;
  v_cant  int;
  v_c     jsonb;
  v_r     jsonb;
  v_ops   int[];
  v_sel   jsonb;
  v_n     int;
  v_usadas int;
  v_precio numeric(8,2);
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
    v_var := nullif(v_it ->> 'variante', '');
    begin v_cant := (v_it ->> 'cant')::int; exception when others then v_cant := null; end;
    if v_pr.id is null or v_cant is null or v_cant not between 1 and 50 then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    -- Menús: solo de lunes a viernes, para retirar entre las 12:00 y las 16:00
    if v_pr.categoria = 'menus' and not (extract(isodow from v_dia) between 1 and 5 and v_hora between time '12:00' and time '16:00') then
      raise exception 'menú fuera de horario' using errcode = '22023';
    end if;
    v_doble := v_pr.agora_id_doble is not null or v_pr.precio_doble is not null;
    if v_doble then
      if v_var is null or v_var not in ('simple', 'doble') then raise exception 'producto inválido' using errcode = '22023'; end if;
    elsif v_var is not null then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    v_c := public._carta_variante(v_pr, v_var);
    if (v_c ->> 'precio') is null then raise exception 'producto inválido' using errcode = '22023'; end if;

    -- opciones elegidas (ids de Ágora); compatibilidad con la página vieja: "salsa" por nombre
    v_ops := array(select distinct (x)::int from jsonb_array_elements_text(coalesce(v_it -> 'opciones', '[]'::jsonb)) x);
    if cardinality(v_ops) = 0 and nullif(v_it ->> 'salsa', '') is not null then
      v_ops := array(select (o ->> 'id')::int from jsonb_array_elements(v_c -> 'roles') r, jsonb_array_elements(r -> 'opciones') o
                      where lower(o ->> 'nombre') = lower(v_it ->> 'salsa') limit 1);
    end if;
    if cardinality(v_ops) > 30 then raise exception 'producto inválido' using errcode = '22023'; end if;

    -- cada grupo dentro de su mínimo y máximo; ninguna opción fuera de los grupos
    v_usadas := 0;
    for v_r in select * from jsonb_array_elements(v_c -> 'roles') loop
      select count(*) into v_n from jsonb_array_elements(v_r -> 'opciones') o where (o ->> 'id')::int = any(v_ops);
      if v_n < (v_r ->> 'min')::int or v_n > (v_r ->> 'max')::int then
        raise exception 'producto inválido' using errcode = '22023';
      end if;
    end loop;
    -- elegidas, en el orden de los grupos de Ágora (hamburguesa, patatas, bebida, quitar…)
    select coalesce(jsonb_agg(o order by ri, oi), '[]'::jsonb) into v_sel
      from (select distinct on ((o ->> 'id')::int) o, ri, oi
              from jsonb_array_elements(v_c -> 'roles') with ordinality r(r, ri),
                   jsonb_array_elements(r -> 'opciones') with ordinality x(o, oi)
             where (o ->> 'id')::int = any(v_ops)
             order by (o ->> 'id')::int, ri, oi) s;
    if jsonb_array_length(v_sel) <> cardinality(v_ops) then
      raise exception 'producto inválido' using errcode = '22023';
    end if;

    v_precio := (v_c ->> 'precio')::numeric + coalesce((select sum((o ->> 'precio')::numeric) from jsonb_array_elements(v_sel) o), 0);
    v_lineas := v_lineas || jsonb_build_object(
      'id', v_pr.id, 'nombre', v_pr.nombre,
      'extra', nullif(concat_ws(' · ', initcap(v_var),
                 (select string_agg(o ->> 'nombre', ', ' order by n) from jsonb_array_elements(v_sel) with ordinality x(o, n))), ''),
      'cant', v_cant, 'precio', v_precio,
      'agora_id', (v_c ->> 'agora_id')::int,
      'addins', (select coalesce(jsonb_agg(jsonb_build_object('id', (o ->> 'id')::int, 'nombre', o ->> 'nombre', 'precio', (o ->> 'precio')::numeric)), '[]'::jsonb)
                   from jsonb_array_elements(v_sel) o where (o ->> 'id')::int > 0));
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

-- Para el TPV: las líneas nuevas ya traen agora_id y addins; las viejas se resuelven como antes.
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
  v_extra text; v_var text; v_salsa text; v_agora int; v_addin int; v_addins jsonb;
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
      v_extra := coalesce(l ->> 'extra', '');
      if l ? 'agora_id' then
        v_agora := (l ->> 'agora_id')::int;
        v_addins := coalesce(l -> 'addins', '[]'::jsonb);
        v_salsa := null; v_addin := null;
      else
        select * into pr from public.productos where id = l ->> 'id';
        v_var   := case when lower(v_extra) in ('simple', 'doble') then lower(v_extra) end;
        v_salsa := case when v_extra ilike 'Salsa %' then substr(v_extra, 7) end;
        v_agora := case when v_var = 'doble' then pr.agora_id_doble else pr.agora_id end;
        v_addin := null;
        if v_salsa is not null and pr.agora_salsas is not null then
          select value::int into v_addin from jsonb_each_text(pr.agora_salsas) where lower(key) = lower(v_salsa) limit 1;
        end if;
        v_addins := case when v_addin is not null then jsonb_build_array(jsonb_build_object('id', v_addin, 'nombre', v_salsa, 'precio', 0)) else '[]'::jsonb end;
      end if;
      v_lineas := v_lineas || jsonb_build_object(
        'id', l ->> 'id', 'nombre', l ->> 'nombre', 'extra', nullif(v_extra, ''),
        'cant', (l ->> 'cant')::int, 'precio', (l ->> 'precio')::numeric,
        'agora_id', v_agora, 'addins', v_addins,
        'agora_salsa', v_addin, 'salsa', v_salsa);
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

-- Productos de Ágora (take away) que faltaban en la web. Precio de referencia: el de Ágora,
-- que igual se toma del catálogo. Nombre, foto y descripción se completan en el admin.
insert into public.productos (id, categoria, nombre, descripcion, precio, precio_doble, agora_id, agora_id_doble, orden) values
  ('ferb',   'burgers', 'Ferb',   null, 11.50, 13.50, 3273, 3274, 70),
  ('numu',   'burgers', 'Numu',   null, 10.50, 12.50, 3280, 3281, 80),
  ('tata',   'burgers', 'Tata',   null, 10.50, 12.50, 3291, 3289, 90),
  ('tonchi', 'burgers', 'Tonchi', null, 11.50, 13.50, 3259, 3260, 100),
  ('pupi',   'burgers', 'Pupi',   null, 12.50, null,  3305, null, 110),
  ('menu',   'menus',   'Menú',   'Hamburguesa, patatas fritas y bebida', 12.90, 14.90, 3227, 3228, 10),
  ('coca-zero', 'bebidas', 'Coca-Cola Zero',   null, 2.50, null, 3188, null, 31),
  ('fanta',     'bebidas', 'Fanta naranja',    null, 2.50, null, 3189, null, 32),
  ('agua-gas',  'bebidas', 'Agua con gas',     null, 2.20, null, 3219, null, 11)
on conflict (id) do nothing;
-- "Bebidas Coca-Cola" pasa a ser la Coca-Cola común (Zero y Fanta van aparte).
update public.productos set nombre = 'Coca-Cola' where id = 'cocacola' and nombre = 'Bebidas Coca-Cola';
-- Las salsas de muzzarellitas, nuggets y aros ahora salen de Ágora.

-- ---------------------------------------------------------------
-- 19. Opciones de cada producto editables desde el admin
-- ---------------------------------------------------------------
-- productos.opciones = null → la web usa los grupos de Ágora tal cual (parte 18).
-- Si tiene algo, esos grupos reemplazan a los de Ágora para ese producto (simple y doble):
--   [{nombre, min, max, opciones: [{id, nombre?, precio?}]}]
-- id = producto de Ágora de la opción (va como addin al pedido). nombre y precio vacíos =
-- los de Ágora (el precio sigue a Ágora; si se escribe uno, manda ese).

alter table public.productos add column if not exists opciones jsonb;
alter table public.productos drop constraint if exists productos_opciones_check;
alter table public.productos add constraint productos_opciones_check
  check (opciones is null or (jsonb_typeof(opciones) = 'array' and jsonb_array_length(opciones) <= 12));

-- Nombre y precio de una opción de Ágora: primero en los grupos de esta variante,
-- después en cualquier grupo del catálogo, y si no, el producto mismo del catálogo.
create or replace function public._agora_opcion(p_id int, p_roles jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select o from jsonb_array_elements(coalesce(p_roles, '[]'::jsonb)) r, jsonb_array_elements(r -> 'opciones') o
      where (o ->> 'id')::int = p_id limit 1),
    (select o from public.agora_catalogo c, jsonb_array_elements(c.roles) r, jsonb_array_elements(r -> 'opciones') o
      where c.activo and (o ->> 'id')::int = p_id limit 1),
    (select jsonb_build_object('id', c.id, 'nombre', c.nombre, 'precio', c.precio) from public.agora_catalogo c where c.id = p_id),
    jsonb_build_object('id', p_id, 'nombre', null, 'precio', 0));
$$;
revoke all on function public._agora_opcion(int, jsonb) from public, anon, authenticated;

create or replace function public._carta_variante(pr public.productos, p_var text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_aid int := case when p_var = 'doble' then pr.agora_id_doble else pr.agora_id end;
  c public.agora_catalogo;
  v_roles jsonb := '[]';
begin
  select * into c from public.agora_catalogo where id = v_aid and activo;
  if pr.opciones is not null and jsonb_typeof(pr.opciones) = 'array' then
    -- grupos armados en el admin
    select coalesce(jsonb_agg(jsonb_build_object(
             'nombre', g.nom,
             'min', least(g.mn, jsonb_array_length(g.ops)), 'max', least(greatest(g.mx, 1), jsonb_array_length(g.ops)),
             'opciones', g.ops) order by g.gi), '[]'::jsonb)
      into v_roles
      from (select gi, coalesce(nullif(btrim(x ->> 'nombre'), ''), 'Opciones') as nom,
                   greatest(coalesce((x ->> 'min')::int, 0), 0) as mn, coalesce((x ->> 'max')::int, 1) as mx,
                   (select coalesce(jsonb_agg(jsonb_build_object(
                             'id', s.id,
                             'nombre', coalesce(nullif(btrim(s.o ->> 'nombre'), ''), public._nombre_lindo(s.a ->> 'nombre'), 'Opción ' || s.id),
                             'precio', coalesce(nullif(s.o ->> 'precio', '')::numeric, nullif(s.a ->> 'precio', '')::numeric, 0))
                           order by s.oi), '[]'::jsonb)
                      from (select o, oi, (o ->> 'id')::int as id, public._agora_opcion((o ->> 'id')::int, c.roles) as a
                              from jsonb_array_elements(coalesce(x -> 'opciones', '[]'::jsonb)) with ordinality y(o, oi)
                             where (o ->> 'id') ~ '^[0-9]{1,9}$') s) as ops
              from jsonb_array_elements(pr.opciones) with ordinality z(x, gi)) g
     where jsonb_array_length(g.ops) > 0;
  elsif c.id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'nombre', public._nombre_lindo(r ->> 'nombre'),
             'min', coalesce((r ->> 'min')::int, 0), 'max', greatest(coalesce((r ->> 'max')::int, 1), 1),
             'opciones', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'id', (o ->> 'id')::int, 'nombre', public._nombre_lindo(o ->> 'nombre'),
                                 'precio', coalesce(nullif(o ->> 'precio', '')::numeric, 0))), '[]'::jsonb)
                            from jsonb_array_elements(r -> 'opciones') o))), '[]'::jsonb)
      into v_roles
      from jsonb_array_elements(c.roles) r
     where jsonb_array_length(coalesce(r -> 'opciones', '[]'::jsonb)) > 0;
  elsif coalesce(cardinality(pr.salsas), 0) > 0 then
    v_roles := jsonb_build_array(jsonb_build_object('nombre', 'Salsa', 'min', 1, 'max', 1,
      'opciones', (select jsonb_agg(jsonb_build_object(
                      'id', coalesce((select value::int from jsonb_each_text(coalesce(pr.agora_salsas, '{}')) where lower(key) = lower(s) limit 1), -n::int),
                      'nombre', s, 'precio', 0) order by n)
                     from unnest(pr.salsas) with ordinality as u(s, n))));
  end if;
  return jsonb_build_object(
    'v', coalesce(p_var, ''), 'agora_id', v_aid,
    'precio', coalesce(c.precio, case when p_var = 'doble' then pr.precio_doble else pr.precio end),
    'roles', v_roles);
end;
$$;
revoke all on function public._carta_variante(public.productos, text) from public, anon, authenticated;

-- ---------------------------------------------------------------
-- 20. Postres: tres Franui (Leche, Negro y Pink)
-- ---------------------------------------------------------------
-- Cada uno con su producto de Ágora: FRANUI LECHE 2053, FRANUI AMARGO 2054, FRANUI ROSADO 3368.
-- Los dos nuevos arrancan con la misma foto del Franui; se cambia en el admin.
update public.productos
   set nombre = 'Franui Leche',
       descripcion = 'Frambuesas congeladas bañadas en chocolate blanco y chocolate con leche',
       agora_id = 2053, orden = 10, actualizado = now()
 where id = 'franui';
insert into public.productos (id, categoria, nombre, descripcion, precio, agora_id, foto_url, take_away, terraza, activo, orden)
select v.id, 'postres', v.nombre, v.descripcion, 5.50, v.agora_id, f.foto_url, true, true, true, v.orden
  from (values
    ('franui-negro', 'Franui Negro', 'Frambuesas congeladas bañadas en chocolate blanco y chocolate negro', 2054, 20),
    ('franui-pink',  'Franui Pink',  'Frambuesas frescas bañadas en chocolate blanco y chocolate de frambuesa', 3368, 30)
  ) as v(id, nombre, descripcion, agora_id, orden)
  left join public.productos f on f.id = 'franui'
on conflict (id) do nothing;

-- ---------------------------------------------------------------
-- 21. Pedidos desde la mesa de la terraza (terrysburgers.com/terraza/?m=5&c=código)
-- ---------------------------------------------------------------
-- Cada mesa tiene un QR con su número y un código (así nadie pide a una mesa desde su casa
-- adivinando el número). Los productos son los que tienen la tilde Terraza. El pedido se
-- guarda en pedidos_take con mesa = número (sin día/hora elegidos ni teléfono) y el TPV lo
-- carga en Ágora en la mesa del centro TERRAZA (Type = Table). Se paga al final, al camarero.

create table if not exists public.terraza_mesas (
  numero     int primary key check (numero between 1 and 99),
  nombre     text not null,                     -- como se ve en la página: 'Mesa 5'
  agora_mesa text not null,                     -- mesa en Ágora (centro TERRAZA): 'MESA 5'
  codigo     text not null default substr(md5(random()::text || clock_timestamp()::text), 1, 10),
  activa     boolean not null default true
);
alter table public.terraza_mesas enable row level security;
revoke all on public.terraza_mesas from anon, authenticated;
grant select, insert, update, delete on public.terraza_mesas to authenticated;
drop policy if exists terraza_mesas_admin on public.terraza_mesas;
create policy terraza_mesas_admin on public.terraza_mesas for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
insert into public.terraza_mesas (numero, nombre, agora_mesa)
select n, 'Mesa ' || n, 'MESA ' || n from generate_series(1, 10) n
on conflict (numero) do nothing;

alter table public.pedidos_take add column if not exists mesa int;
alter table public.pedidos_take alter column telefono drop not null;   -- los de mesa no llevan teléfono

-- En la terraza se usan los productos de LOCAL de Ágora (sin «TAKE AWAY»): su precio, sus opciones
-- y su código en el pedido. Si un producto no tiene código de local, usa el de take away.
alter table public.productos add column if not exists agora_id_local int;
alter table public.productos add column if not exists agora_id_doble_local int;
-- Se completan solos por nombre: «TERRY DOBLE TAKE AWAY» → «TERRY DOBLE»; bebidas 330ML → 350ML/300ML.
with c as (
  select p.id, ta.nombre as ta, ta2.nombre as ta2
    from public.productos p
    left join public.agora_catalogo ta  on ta.id = p.agora_id
    left join public.agora_catalogo ta2 on ta2.id = p.agora_id_doble
), cand as (
  select c.id,
    (select l.id from public.agora_catalogo l, unnest(array[
        regexp_replace(c.ta, '\s+TAKE\s+AWAY\s*$', '', 'i'),
        replace(regexp_replace(c.ta, '\s+TAKE\s+AWAY\s*$', '', 'i'), '330ML', '350ML'),
        replace(regexp_replace(c.ta, '\s+TAKE\s+AWAY\s*$', '', 'i'), '330ML', '300ML')]) with ordinality as n(nom, k)
      where l.activo and c.ta ~* 'TAKE\s+AWAY\s*$' and upper(l.nombre) = upper(n.nom) order by n.k limit 1) as loc,
    (select l.id from public.agora_catalogo l
      where l.activo and c.ta2 ~* 'TAKE\s+AWAY\s*$' and upper(l.nombre) = upper(regexp_replace(c.ta2, '\s+TAKE\s+AWAY\s*$', '', 'i')) limit 1) as loc2
    from c
)
update public.productos p
   set agora_id_local = coalesce(p.agora_id_local, cand.loc),
       agora_id_doble_local = coalesce(p.agora_id_doble_local, cand.loc2)
  from cand where cand.id = p.id and (cand.loc is not null or cand.loc2 is not null);

create or replace function public._carta_variante(pr public.productos, p_var text, p_terraza boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_terraza then
    pr.agora_id := coalesce(pr.agora_id_local, pr.agora_id);
    pr.agora_id_doble := coalesce(pr.agora_id_doble_local, pr.agora_id_doble);
  end if;
  return public._carta_variante(pr, p_var);
end;
$$;
revoke all on function public._carta_variante(public.productos, text, boolean) from public, anon, authenticated;

-- Carta: la de take away (web_carta) y la de terraza salen de la misma función.
create or replace function public._web_carta(p_terraza boolean)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'categoria', p.categoria, 'nombre', p.nombre, 'descripcion', p.descripcion,
           'foto_url', p.foto_url,
           'variantes', case when p.agora_id_doble is not null or p.precio_doble is not null
                             then jsonb_build_array(public._carta_variante(p, 'simple', p_terraza), public._carta_variante(p, 'doble', p_terraza))
                             else jsonb_build_array(public._carta_variante(p, null, p_terraza)) end)
         order by p.orden, p.nombre), '[]'::jsonb)
    from public.productos p
   where p.activo and (case when p_terraza then p.terraza else p.take_away end);
$$;
revoke all on function public._web_carta(boolean) from public, anon, authenticated;

create or replace function public.web_carta()
returns jsonb language sql stable security definer set search_path = public
as $$ select public._web_carta(false); $$;
revoke all on function public.web_carta() from public;
grant execute on function public.web_carta() to anon, authenticated;

create or replace function public.web_carta_terraza()
returns jsonb language sql stable security definer set search_path = public
as $$ select public._web_carta(true); $$;
revoke all on function public.web_carta_terraza() from public;
grant execute on function public.web_carta_terraza() to anon, authenticated;

-- Valida y cobra los productos de un pedido (igual que web_pedir) → {lineas, unidades, total}
create or replace function public._pedido_lineas(p_items jsonb, p_terraza boolean, p_dia date, p_hora time)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_it jsonb; v_pr public.productos; v_doble boolean; v_var text; v_cant int; v_c jsonb; v_r jsonb;
  v_ops int[]; v_sel jsonb; v_n int; v_precio numeric(8,2);
  v_lineas jsonb := '[]'; v_unid int := 0; v_total numeric(8,2) := 0;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then
    raise exception 'pedido vacío' using errcode = '22023';
  end if;
  for v_it in select * from jsonb_array_elements(p_items) loop
    select * into v_pr from public.productos
      where id = left(coalesce(v_it ->> 'id', ''), 40) and activo
        and (case when p_terraza then terraza else take_away end);
    v_var := nullif(v_it ->> 'variante', '');
    begin v_cant := (v_it ->> 'cant')::int; exception when others then v_cant := null; end;
    if v_pr.id is null or v_cant is null or v_cant not between 1 and 50 then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    if v_pr.categoria = 'menus' and not (extract(isodow from p_dia) between 1 and 5 and p_hora between time '12:00' and time '16:00') then
      raise exception 'menú fuera de horario' using errcode = '22023';
    end if;
    v_doble := v_pr.agora_id_doble is not null or v_pr.precio_doble is not null;
    if v_doble then
      if v_var is null or v_var not in ('simple', 'doble') then raise exception 'producto inválido' using errcode = '22023'; end if;
    elsif v_var is not null then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    v_c := public._carta_variante(v_pr, v_var, p_terraza);
    if (v_c ->> 'precio') is null then raise exception 'producto inválido' using errcode = '22023'; end if;
    v_ops := array(select distinct (x)::int from jsonb_array_elements_text(coalesce(v_it -> 'opciones', '[]'::jsonb)) x);
    if cardinality(v_ops) > 30 then raise exception 'producto inválido' using errcode = '22023'; end if;
    for v_r in select * from jsonb_array_elements(v_c -> 'roles') loop
      select count(*) into v_n from jsonb_array_elements(v_r -> 'opciones') o where (o ->> 'id')::int = any(v_ops);
      if v_n < (v_r ->> 'min')::int or v_n > (v_r ->> 'max')::int then
        raise exception 'producto inválido' using errcode = '22023';
      end if;
    end loop;
    select coalesce(jsonb_agg(o order by ri, oi), '[]'::jsonb) into v_sel
      from (select distinct on ((o ->> 'id')::int) o, ri, oi
              from jsonb_array_elements(v_c -> 'roles') with ordinality r(r, ri),
                   jsonb_array_elements(r -> 'opciones') with ordinality x(o, oi)
             where (o ->> 'id')::int = any(v_ops)
             order by (o ->> 'id')::int, ri, oi) s;
    if jsonb_array_length(v_sel) <> cardinality(v_ops) then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    v_precio := (v_c ->> 'precio')::numeric + coalesce((select sum((o ->> 'precio')::numeric) from jsonb_array_elements(v_sel) o), 0);
    v_lineas := v_lineas || jsonb_build_object(
      'id', v_pr.id, 'nombre', v_pr.nombre,
      'extra', nullif(concat_ws(' · ', initcap(v_var),
                 (select string_agg(o ->> 'nombre', ', ' order by n) from jsonb_array_elements(v_sel) with ordinality x(o, n))), ''),
      'cant', v_cant, 'precio', v_precio,
      'agora_id', (v_c ->> 'agora_id')::int,
      'addins', (select coalesce(jsonb_agg(jsonb_build_object('id', (o ->> 'id')::int, 'nombre', o ->> 'nombre', 'precio', (o ->> 'precio')::numeric)), '[]'::jsonb)
                   from jsonb_array_elements(v_sel) o where (o ->> 'id')::int > 0));
    v_unid  := v_unid + v_cant;
    v_total := v_total + v_cant * v_precio;
  end loop;
  if v_unid > 200 then raise exception 'pedido demasiado grande' using errcode = '22023'; end if;
  return jsonb_build_object('lineas', v_lineas, 'unidades', v_unid, 'total', v_total);
end;
$$;
revoke all on function public._pedido_lineas(jsonb, boolean, date, time) from public, anon, authenticated;

-- Para la página de la mesa: ¿el QR es válido? → {mesa, nombre}
create or replace function public.web_mesa(p_mesa int, p_codigo text)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object('mesa', numero, 'nombre', nombre)
    from public.terraza_mesas where numero = p_mesa and codigo = p_codigo and activa;
$$;
revoke all on function public.web_mesa(int, text) from public;
grant execute on function public.web_mesa(int, text) to anon, authenticated;

-- Pedido desde la mesa: {mesa, codigo, nombre?, comentario?, items, web}
create or replace function public.web_pedir_mesa(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dia  date := (now() at time zone 'Europe/Madrid')::date;
  v_hora time := date_trunc('minute', (now() at time zone 'Europe/Madrid')::time);
  v_m    public.terraza_mesas;
  v_l    jsonb;
  v_pid  bigint;
begin
  if public._txt(p ->> 'web', 200) is not null then return jsonb_build_object('ok', true); end if;   -- trampa para bots
  begin
    select * into v_m from public.terraza_mesas
     where numero = (p ->> 'mesa')::int and codigo = coalesce(p ->> 'codigo', '') and activa;
  exception when others then v_m := null; end;
  if v_m.numero is null then raise exception 'mesa inválida' using errcode = '22023'; end if;
  -- solo con el local abierto (mediodía y noche)
  if not (v_hora between time '12:00' and time '16:30' or v_hora >= time '19:00') then
    raise exception 'terraza cerrada' using errcode = '22023';
  end if;
  if (select count(*) from public.pedidos_take where mesa = v_m.numero and creado > now() - interval '3 hours') >= 15
     or (select count(*) from public.pedidos_take where creado > now() - interval '1 day') >= 300 then
    raise exception 'demasiados pedidos, llamá al camarero' using errcode = '54000';
  end if;
  v_l := public._pedido_lineas(p -> 'items', true, v_dia, v_hora);
  insert into public.pedidos_take (dia, hora, nombre, telefono, comentario, items, unidades, total, mesa)
  values (v_dia, v_hora, coalesce(case when char_length(public._txt(p ->> 'nombre', 80)) >= 2 then public._txt(p ->> 'nombre', 80) end, v_m.nombre), null,
          public._txt(p ->> 'comentario', 500), v_l -> 'lineas', (v_l ->> 'unidades')::int, (v_l ->> 'total')::numeric, v_m.numero)
  returning id into v_pid;
  return jsonb_build_object('ok', true, 'id', v_pid, 'total', (v_l ->> 'total')::numeric, 'mesa', v_m.nombre);
end;
$$;
revoke all on function public.web_pedir_mesa(jsonb) from public;
grant execute on function public.web_pedir_mesa(jsonb) to anon, authenticated;

-- El TPV recibe la mesa: los pedidos con mesa van a Ágora como Type = Table en esa mesa de TERRAZA.
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
  v_extra text; v_var text; v_salsa text; v_agora int; v_addin int; v_addins jsonb;
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
      v_extra := coalesce(l ->> 'extra', '');
      if l ? 'agora_id' then
        v_agora := (l ->> 'agora_id')::int;
        v_addins := coalesce(l -> 'addins', '[]'::jsonb);
        v_salsa := null; v_addin := null;
      else
        select * into pr from public.productos where id = l ->> 'id';
        v_var   := case when lower(v_extra) in ('simple', 'doble') then lower(v_extra) end;
        v_salsa := case when v_extra ilike 'Salsa %' then substr(v_extra, 7) end;
        v_agora := case when v_var = 'doble' then pr.agora_id_doble else pr.agora_id end;
        v_addin := null;
        if v_salsa is not null and pr.agora_salsas is not null then
          select value::int into v_addin from jsonb_each_text(pr.agora_salsas) where lower(key) = lower(v_salsa) limit 1;
        end if;
        v_addins := case when v_addin is not null then jsonb_build_array(jsonb_build_object('id', v_addin, 'nombre', v_salsa, 'precio', 0)) else '[]'::jsonb end;
      end if;
      v_lineas := v_lineas || jsonb_build_object(
        'id', l ->> 'id', 'nombre', l ->> 'nombre', 'extra', nullif(v_extra, ''),
        'cant', (l ->> 'cant')::int, 'precio', (l ->> 'precio')::numeric,
        'agora_id', v_agora, 'addins', v_addins,
        'agora_salsa', v_addin, 'salsa', v_salsa);
    end loop;
    v_out := v_out || jsonb_build_object(
      'id', r.id, 'creado', r.creado, 'dia', r.dia, 'hora', to_char(r.hora, 'HH24:MI'),
      'nombre', r.nombre, 'telefono', r.telefono, 'comentario', r.comentario,
      'total', r.total, 'pagado', false, 'lineas', v_lineas, 'intentos', r.agora_intentos,
      'mesa', r.mesa, 'agora_mesa', (select m.agora_mesa from public.terraza_mesas m where m.numero = r.mesa));
  end loop;
  return v_out;
end;
$$;
revoke all on function public.agora_pendientes(text) from public;
grant execute on function public.agora_pendientes(text) to anon, authenticated;

-- Aviso al celular: el TPV pone «Mesa 5» en vez de la hora de retiro.
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
  -- Datos sueltos: el texto lo arma el TPV (sin nombre ni teléfono del cliente).
  return jsonb_build_object('tema', a.ntfy_tema, 'avisos', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'dia', to_char(p.dia, 'DD/MM'), 'hora', to_char(p.hora, 'HH24:MI'),
      'cuando', case when p.dia = v_hoy then 'hoy' when p.dia = v_hoy + 1 then 'manana' else 'otro' end,
      'unidades', p.unidades, 'total', p.total, 'comentario', p.comentario is not null, 'mesa', p.mesa,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('cant', i ->> 'cant', 'nombre', i ->> 'nombre', 'extra', i ->> 'extra')), '[]'::jsonb)
                  from jsonb_array_elements(p.items) i)) order by p.creado)
    from public.pedidos_take p
    where p.avisado is null and p.estado <> 'cancelado' and p.creado > now() - interval '6 hours'), '[]'::jsonb));
end;
$$;
revoke all on function public.tpv_avisos_pendientes(text) from public;
grant execute on function public.tpv_avisos_pendientes(text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 22. Foto aparte para local / terraza
-- ---------------------------------------------------------------
-- foto_url sigue siendo la de take away (terrysburgers.com/pedido/). foto_terraza_url es la del
-- producto servido en el local; la usa la página de la terraza (si no hay, usa la de take away).
alter table public.productos add column if not exists foto_terraza_url text;

create or replace function public._web_carta(p_terraza boolean)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'categoria', p.categoria, 'nombre', p.nombre, 'descripcion', p.descripcion,
           'foto_url', case when p_terraza then coalesce(p.foto_terraza_url, p.foto_url) else p.foto_url end,
           'variantes', case when p.agora_id_doble is not null or p.precio_doble is not null
                             then jsonb_build_array(public._carta_variante(p, 'simple', p_terraza), public._carta_variante(p, 'doble', p_terraza))
                             else jsonb_build_array(public._carta_variante(p, null, p_terraza)) end)
         order by p.orden, p.nombre), '[]'::jsonb)
    from public.productos p
   where p.activo and (case when p_terraza then p.terraza else p.take_away end);
$$;
revoke all on function public._web_carta(boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------
-- 23. Productos solo de terraza y foto de local como respaldo
-- ---------------------------------------------------------------
-- · Si un producto no tiene foto de take away, la página de take away usa la de local.
-- · En la terraza, un producto es «simple / doble» también si solo tiene código doble de local.
create or replace function public._web_carta(p_terraza boolean)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'categoria', p.categoria, 'nombre', p.nombre, 'descripcion', p.descripcion,
           'foto_url', case when p_terraza then coalesce(p.foto_terraza_url, p.foto_url) else coalesce(p.foto_url, p.foto_terraza_url) end,
           'variantes', case when p.agora_id_doble is not null or p.precio_doble is not null
                               or (p_terraza and p.agora_id_doble_local is not null)
                             then jsonb_build_array(public._carta_variante(p, 'simple', p_terraza), public._carta_variante(p, 'doble', p_terraza))
                             else jsonb_build_array(public._carta_variante(p, null, p_terraza)) end)
         order by p.orden, p.nombre), '[]'::jsonb)
    from public.productos p
   where p.activo and (case when p_terraza then p.terraza else p.take_away end);
$$;
revoke all on function public._web_carta(boolean) from public, anon, authenticated;

-- Mismo criterio de simple / doble al cobrar el pedido.
create or replace function public._pedido_lineas(p_items jsonb, p_terraza boolean, p_dia date, p_hora time)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_it jsonb; v_pr public.productos; v_doble boolean; v_var text; v_cant int; v_c jsonb; v_r jsonb;
  v_ops int[]; v_sel jsonb; v_n int; v_precio numeric(8,2);
  v_lineas jsonb := '[]'; v_unid int := 0; v_total numeric(8,2) := 0;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then
    raise exception 'pedido vacío' using errcode = '22023';
  end if;
  for v_it in select * from jsonb_array_elements(p_items) loop
    select * into v_pr from public.productos
      where id = left(coalesce(v_it ->> 'id', ''), 40) and activo
        and (case when p_terraza then terraza else take_away end);
    v_var := nullif(v_it ->> 'variante', '');
    begin v_cant := (v_it ->> 'cant')::int; exception when others then v_cant := null; end;
    if v_pr.id is null or v_cant is null or v_cant not between 1 and 50 then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    if v_pr.categoria = 'menus' and not (extract(isodow from p_dia) between 1 and 5 and p_hora between time '12:00' and time '16:00') then
      raise exception 'menú fuera de horario' using errcode = '22023';
    end if;
    v_doble := v_pr.agora_id_doble is not null or v_pr.precio_doble is not null
               or (p_terraza and v_pr.agora_id_doble_local is not null);
    if v_doble then
      if v_var is null or v_var not in ('simple', 'doble') then raise exception 'producto inválido' using errcode = '22023'; end if;
    elsif v_var is not null then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    v_c := public._carta_variante(v_pr, v_var, p_terraza);
    if (v_c ->> 'precio') is null then raise exception 'producto inválido' using errcode = '22023'; end if;
    v_ops := array(select distinct (x)::int from jsonb_array_elements_text(coalesce(v_it -> 'opciones', '[]'::jsonb)) x);
    if cardinality(v_ops) > 30 then raise exception 'producto inválido' using errcode = '22023'; end if;
    for v_r in select * from jsonb_array_elements(v_c -> 'roles') loop
      select count(*) into v_n from jsonb_array_elements(v_r -> 'opciones') o where (o ->> 'id')::int = any(v_ops);
      if v_n < (v_r ->> 'min')::int or v_n > (v_r ->> 'max')::int then
        raise exception 'producto inválido' using errcode = '22023';
      end if;
    end loop;
    select coalesce(jsonb_agg(o order by ri, oi), '[]'::jsonb) into v_sel
      from (select distinct on ((o ->> 'id')::int) o, ri, oi
              from jsonb_array_elements(v_c -> 'roles') with ordinality r(r, ri),
                   jsonb_array_elements(r -> 'opciones') with ordinality x(o, oi)
             where (o ->> 'id')::int = any(v_ops)
             order by (o ->> 'id')::int, ri, oi) s;
    if jsonb_array_length(v_sel) <> cardinality(v_ops) then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    v_precio := (v_c ->> 'precio')::numeric + coalesce((select sum((o ->> 'precio')::numeric) from jsonb_array_elements(v_sel) o), 0);
    v_lineas := v_lineas || jsonb_build_object(
      'id', v_pr.id, 'nombre', v_pr.nombre,
      'extra', nullif(concat_ws(' · ', initcap(v_var),
                 (select string_agg(o ->> 'nombre', ', ' order by n) from jsonb_array_elements(v_sel) with ordinality x(o, n))), ''),
      'cant', v_cant, 'precio', v_precio,
      'agora_id', (v_c ->> 'agora_id')::int,
      'addins', (select coalesce(jsonb_agg(jsonb_build_object('id', (o ->> 'id')::int, 'nombre', o ->> 'nombre', 'precio', (o ->> 'precio')::numeric)), '[]'::jsonb)
                   from jsonb_array_elements(v_sel) o where (o ->> 'id')::int > 0));
    v_unid  := v_unid + v_cant;
    v_total := v_total + v_cant * v_precio;
  end loop;
  if v_unid > 200 then raise exception 'pedido demasiado grande' using errcode = '22023'; end if;
  return jsonb_build_object('lineas', v_lineas, 'unidades', v_unid, 'total', v_total);
end;
$$;
revoke all on function public._pedido_lineas(jsonb, boolean, date, time) from public, anon, authenticated;

-- ---------------------------------------------------------------
-- 24. Pedidos en el local (página de camareros: admin.terrysburgers.com/pos/)
-- ---------------------------------------------------------------
-- · Cada camarero entra con su PIN (se cargan en el admin: Pedidos → Camareros).
-- · El TPV sube la carta de cada centro de venta tal como la muestra el iPad de Ágora
--   (categorías y productos de LOCAL, TERRAZA, TAKE AWAY…) y, cada pocos segundos, las mesas
--   abiertas con lo que tienen cargado (lo lee de la base de Ágora).
-- · El pedido se guarda en pedidos_take con el centro y la mesa de Ágora; el TPV lo carga como
--   pedido de mesa y Ágora lo suma a la cuenta abierta de esa mesa (o la abre).

create table if not exists public.pos_camareros (
  id       int generated always as identity primary key,
  nombre   text not null check (char_length(nombre) between 2 and 40),
  pin_hash text not null,
  activo   boolean not null default true,
  creado   timestamptz not null default now()
);
create unique index if not exists pos_camareros_pin on public.pos_camareros (pin_hash) where activo;
alter table public.pos_camareros enable row level security;
revoke all on public.pos_camareros from anon, authenticated;
grant select (id, nombre, activo, creado) on public.pos_camareros to authenticated;
drop policy if exists pos_camareros_admin on public.pos_camareros;
create policy pos_camareros_admin on public.pos_camareros for select to authenticated using (public.es_admin());

create table if not exists public.pos_sesiones (
  token_hash  text primary key,
  camarero_id int not null references public.pos_camareros (id) on delete cascade,
  vence       timestamptz not null
);
alter table public.pos_sesiones enable row level security;
revoke all on public.pos_sesiones from anon, authenticated;

create table if not exists public.pos_intentos (creado timestamptz not null default now());
alter table public.pos_intentos enable row level security;
revoke all on public.pos_intentos from anon, authenticated;

-- Lo que sube el TPV: carta por centro y mesas abiertas (una sola fila).
create table if not exists public.pos_estado (
  id                 int primary key default 1 check (id = 1),
  carta              jsonb not null default '{"centros": []}',
  carta_actualizada  timestamptz,
  mesas              jsonb not null default '[]',
  mesas_actualizadas timestamptz
);
insert into public.pos_estado (id) values (1) on conflict (id) do nothing;
alter table public.pos_estado enable row level security;
revoke all on public.pos_estado from anon, authenticated;

alter table public.pedidos_take add column if not exists agora_centro int;
alter table public.pedidos_take add column if not exists agora_ubicacion text;
alter table public.pedidos_take add column if not exists camarero text;

create or replace function public._pos_pin_hash(p_pin text)
returns text
language sql
immutable
set search_path = public
as $$ select encode(extensions.digest('terrys-pos:' || coalesce(p_pin, ''), 'sha256'), 'hex'); $$;
revoke all on function public._pos_pin_hash(text) from public, anon, authenticated;

-- Admin: alta / cambio de nombre, PIN o activo. Devuelve el id.
create or replace function public.pos_camarero_guardar(p_id int, p_nombre text, p_pin text, p_activo boolean default true)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_nombre text := btrim(coalesce(p_nombre, '')); v_hash text; v_id int;
begin
  if not public.es_admin() then raise exception 'sin permiso' using errcode = '42501'; end if;
  if char_length(v_nombre) not between 2 and 40 then raise exception 'Poné un nombre (2 a 40 letras)' using errcode = '22023'; end if;
  if nullif(p_pin, '') is not null then
    if p_pin !~ '^[0-9]{4,6}$' then raise exception 'El PIN tiene que ser de 4 a 6 números' using errcode = '22023'; end if;
    v_hash := public._pos_pin_hash(p_pin);
    if exists (select 1 from public.pos_camareros where pin_hash = v_hash and activo and id is distinct from p_id) then
      raise exception 'Ese PIN ya lo usa otro camarero' using errcode = '22023';
    end if;
  end if;
  if p_id is null then
    if v_hash is null then raise exception 'Falta el PIN' using errcode = '22023'; end if;
    insert into public.pos_camareros (nombre, pin_hash, activo) values (v_nombre, v_hash, coalesce(p_activo, true)) returning id into v_id;
  else
    if coalesce(p_activo, true) and v_hash is null and exists (
         select 1 from public.pos_camareros a, public.pos_camareros b
          where a.id = p_id and b.id <> a.id and b.activo and b.pin_hash = a.pin_hash) then
      raise exception 'Ese PIN ya lo usa otro camarero' using errcode = '22023';
    end if;
    update public.pos_camareros set nombre = v_nombre, activo = coalesce(p_activo, true), pin_hash = coalesce(v_hash, pin_hash)
     where id = p_id returning id into v_id;
    if v_id is null then raise exception 'No existe ese camarero' using errcode = '22023'; end if;
    -- PIN nuevo o desactivado: se cierran sus sesiones abiertas
    if v_hash is not null or not coalesce(p_activo, true) then delete from public.pos_sesiones where camarero_id = v_id; end if;
  end if;
  return v_id;
end;
$$;
revoke all on function public.pos_camarero_guardar(int, text, text, boolean) from public;
grant execute on function public.pos_camarero_guardar(int, text, text, boolean) to authenticated;

create or replace function public.pos_camarero_borrar(p_id int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'sin permiso' using errcode = '42501'; end if;
  delete from public.pos_camareros where id = p_id;
end;
$$;
revoke all on function public.pos_camarero_borrar(int) from public;
grant execute on function public.pos_camarero_borrar(int) to authenticated;

-- Entrar con el PIN → token de sesión (14 h). Máximo 20 PIN equivocados cada 15 minutos.
create or replace function public.pos_entrar(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare c public.pos_camareros; v_tok text;
begin
  delete from public.pos_intentos where creado < now() - interval '15 minutes';
  if (select count(*) from public.pos_intentos) >= 20 then
    return jsonb_build_object('ok', false, 'error', 'Demasiados intentos. Esperá unos minutos.');
  end if;
  select * into c from public.pos_camareros where activo and pin_hash = public._pos_pin_hash(left(coalesce(p_pin, ''), 10));
  if c.id is null then
    insert into public.pos_intentos default values;
    return jsonb_build_object('ok', false, 'error', 'PIN incorrecto');
  end if;
  delete from public.pos_sesiones where vence < now();
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.pos_sesiones (token_hash, camarero_id, vence)
  values (encode(extensions.digest(v_tok, 'sha256'), 'hex'), c.id, now() + interval '14 hours');
  return jsonb_build_object('ok', true, 'token', v_tok, 'nombre', c.nombre);
end;
$$;
revoke all on function public.pos_entrar(text) from public;
grant execute on function public.pos_entrar(text) to anon, authenticated;

create or replace function public._pos_sesion(p_token text)
returns public.pos_camareros
language plpgsql
stable
security definer
set search_path = public
as $$
declare c public.pos_camareros;
begin
  select k.* into c from public.pos_sesiones s join public.pos_camareros k on k.id = s.camarero_id
   where s.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') and s.vence > now() and k.activo;
  if c.id is null then raise exception 'sesión vencida' using errcode = '28000'; end if;
  return c;
end;
$$;
revoke all on function public._pos_sesion(text) from public, anon, authenticated;

create or replace function public.pos_salir(p_token text)
returns void
language sql
security definer
set search_path = public
as $$ delete from public.pos_sesiones where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex'); $$;
revoke all on function public.pos_salir(text) from public;
grant execute on function public.pos_salir(text) to anon, authenticated;

-- Carta de cada centro + datos de los productos (precio y opciones de Ágora).
create or replace function public.pos_datos(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare c public.pos_camareros; e public.pos_estado;
begin
  c := public._pos_sesion(p_token);
  select * into e from public.pos_estado where id = 1;
  return jsonb_build_object(
    'camarero', c.nombre,
    'centros', coalesce(e.carta -> 'centros', '[]'::jsonb),
    'carta_actualizada', e.carta_actualizada,
    'productos', coalesce((
      select jsonb_object_agg(a.id::text, jsonb_build_object('nombre', a.nombre, 'precio', a.precio, 'roles', a.roles))
        from public.agora_catalogo a
       where a.activo and a.id in (
         select (pid)::int
           from jsonb_array_elements(coalesce(e.carta -> 'centros', '[]'::jsonb)) ce,
                jsonb_array_elements(ce -> 'categorias') ca,
                jsonb_array_elements_text(ca -> 'productos') pid)), '{}'::jsonb));
end;
$$;
revoke all on function public.pos_datos(text) from public;
grant execute on function public.pos_datos(text) to anon, authenticated;

-- Mesas abiertas en Ágora + pedidos de la página que todavía no entraron (o dieron error).
create or replace function public.pos_mesas(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare c public.pos_camareros; e public.pos_estado;
begin
  c := public._pos_sesion(p_token);
  select * into e from public.pos_estado where id = 1;
  return jsonb_build_object(
    'mesas', e.mesas, 'actualizadas', e.mesas_actualizadas, 'ahora', now(),
    'pedidos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'centro', p.agora_centro, 'mesa', p.agora_ubicacion, 'camarero', p.camarero,
               'creado', p.creado, 'estado', coalesce(p.agora_estado, 'pendiente'), 'error', p.agora_error,
               'items', (select coalesce(jsonb_agg(jsonb_build_object('nombre', i ->> 'nombre', 'extra', i ->> 'extra', 'cant', i ->> 'cant', 'nota', i ->> 'nota')), '[]'::jsonb)
                           from jsonb_array_elements(p.items) i)) order by p.id)
        from public.pedidos_take p
       where p.agora_centro is not null and p.estado <> 'cancelado' and p.creado > now() - interval '2 hours'
         and (p.agora_estado is null or p.agora_estado = 'error'
              or (p.agora_estado = 'enviado' and p.agora_enviado > coalesce(e.mesas_actualizadas, now()) - interval '10 seconds'))), '[]'::jsonb));
end;
$$;
revoke all on function public.pos_mesas(text) from public;
grant execute on function public.pos_mesas(text) to anon, authenticated;

-- Cargar un pedido en una mesa. p = {centro, mesa, items: [{id, cant, opciones: [ids], nota}], comentario}
create or replace function public.pos_pedir(p_token text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.pos_camareros; e public.pos_estado; v_centro jsonb; v_cid int; v_mesa text;
  v_it jsonb; v_cat public.agora_catalogo; v_cant int; v_ops int[]; v_r jsonb; v_n int; v_sel jsonb; v_precio numeric(8,2);
  v_lineas jsonb := '[]'; v_unid int := 0; v_total numeric(8,2) := 0; v_pid bigint;
begin
  c := public._pos_sesion(p_token);
  select * into e from public.pos_estado where id = 1;
  begin v_cid := (p ->> 'centro')::int; exception when others then v_cid := null; end;
  select x into v_centro from jsonb_array_elements(e.carta -> 'centros') x where (x ->> 'id')::int = v_cid;
  v_mesa := p ->> 'mesa';
  if v_centro is null or v_mesa is null or not (v_centro -> 'mesas') ? v_mesa then
    raise exception 'mesa inválida' using errcode = '22023';
  end if;
  if jsonb_typeof(p -> 'items') <> 'array' or jsonb_array_length(p -> 'items') not between 1 and 60 then
    raise exception 'pedido vacío' using errcode = '22023';
  end if;
  if (select count(*) from public.pedidos_take where agora_centro is not null and creado > now() - interval '1 hour') >= 200 then
    raise exception 'demasiados pedidos' using errcode = '54000';
  end if;
  for v_it in select * from jsonb_array_elements(p -> 'items') loop
    v_cat := null;
    select a.* into v_cat from public.agora_catalogo a
     where a.activo and a.id = (case when (v_it ->> 'id') ~ '^[0-9]{1,9}$' then (v_it ->> 'id')::int end)
       and exists (select 1 from jsonb_array_elements(v_centro -> 'categorias') ca, jsonb_array_elements_text(ca -> 'productos') pid
                    where pid::int = a.id);
    begin v_cant := (v_it ->> 'cant')::int; exception when others then v_cant := null; end;
    if v_cat.id is null or v_cat.precio is null or v_cant is null or v_cant not between 1 and 50 then
      raise exception 'producto inválido' using errcode = '22023';
    end if;
    begin
      v_ops := array(select (x)::int from jsonb_array_elements_text(coalesce(v_it -> 'opciones', '[]'::jsonb)) x);
    exception when others then raise exception 'producto inválido' using errcode = '22023'; end;
    if cardinality(v_ops) > 30 then raise exception 'producto inválido' using errcode = '22023'; end if;
    -- (una opción puede ir repetida: 2 × extra medallón)
    for v_r in select * from jsonb_array_elements(v_cat.roles) loop
      select count(*) into v_n from unnest(v_ops) u(id)
       where u.id in (select (o ->> 'id')::int from jsonb_array_elements(v_r -> 'opciones') o);
      if v_n < coalesce((v_r ->> 'min')::int, 0) or (coalesce((v_r ->> 'max')::int, 0) > 0 and v_n > (v_r ->> 'max')::int) then
        raise exception 'Revisá las opciones de %', v_cat.nombre using errcode = '22023';
      end if;
    end loop;
    select coalesce(jsonb_agg(m.o order by u.n), '[]'::jsonb) into v_sel
      from unnest(v_ops) with ordinality u(id, n)
      cross join lateral (
        select o from jsonb_array_elements(v_cat.roles) with ordinality r(r, ri),
                      jsonb_array_elements(r -> 'opciones') with ordinality x(o, oi)
         where (o ->> 'id')::int = u.id order by ri, oi limit 1) m;
    if jsonb_array_length(v_sel) <> cardinality(v_ops) then raise exception 'producto inválido' using errcode = '22023'; end if;
    v_precio := v_cat.precio + coalesce((select sum(coalesce((o ->> 'precio')::numeric, 0)) from jsonb_array_elements(v_sel) o), 0);
    v_lineas := v_lineas || jsonb_build_object(
      'id', v_cat.id::text, 'nombre', v_cat.nombre,
      'extra', (select string_agg(case when k > 1 then k || ' × ' else '' end || nom, ', ' order by pri)
                  from (select o ->> 'nombre' nom, count(*) k, min(n) pri from jsonb_array_elements(v_sel) with ordinality x(o, n) group by 1) g),
      'nota', public._txt(v_it ->> 'nota', 120),
      'cant', v_cant, 'precio', v_precio, 'agora_id', v_cat.id,
      'addins', (select coalesce(jsonb_agg(jsonb_build_object('id', (o ->> 'id')::int, 'nombre', o ->> 'nombre', 'precio', coalesce((o ->> 'precio')::numeric, 0))), '[]'::jsonb)
                   from jsonb_array_elements(v_sel) o));
    v_unid := v_unid + v_cant;
    v_total := v_total + v_cant * v_precio;
  end loop;
  if v_unid > 200 then raise exception 'pedido demasiado grande' using errcode = '22023'; end if;
  insert into public.pedidos_take (dia, hora, nombre, telefono, comentario, items, unidades, total,
                                   agora_centro, agora_ubicacion, camarero, avisado)
  values ((now() at time zone 'Europe/Madrid')::date, date_trunc('minute', (now() at time zone 'Europe/Madrid')::time),
          left((v_centro ->> 'nombre') || ' · ' || v_mesa, 80), null, public._txt(p ->> 'comentario', 300),
          v_lineas, v_unid, v_total, v_cid, v_mesa, c.nombre, now())   -- avisado: sin aviso al celular
  returning id into v_pid;
  return jsonb_build_object('ok', true, 'id', v_pid, 'total', v_total);
end;
$$;
revoke all on function public.pos_pedir(text, jsonb) from public;
grant execute on function public.pos_pedir(text, jsonb) to anon, authenticated;

-- Lo que sube el TPV.
create or replace function public.tpv_subir_carta(p_token text, p_carta jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._token_valido('agora', p_token) then raise exception 'token inválido' using errcode = '28000'; end if;
  if jsonb_typeof(p_carta -> 'centros') <> 'array' or pg_column_size(p_carta) > 400000 then
    raise exception 'carta inválida' using errcode = '22023';
  end if;
  update public.pos_estado set carta = p_carta, carta_actualizada = now() where id = 1;
end;
$$;
revoke all on function public.tpv_subir_carta(text, jsonb) from public;
grant execute on function public.tpv_subir_carta(text, jsonb) to anon, authenticated;

create or replace function public.tpv_subir_mesas(p_token text, p_mesas jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._token_valido('agora', p_token) then raise exception 'token inválido' using errcode = '28000'; end if;
  if jsonb_typeof(p_mesas) <> 'array' or pg_column_size(p_mesas) > 400000 then
    raise exception 'mesas inválidas' using errcode = '22023';
  end if;
  update public.pos_estado set mesas = p_mesas, mesas_actualizadas = now() where id = 1;
end;
$$;
revoke all on function public.tpv_subir_mesas(text, jsonb) from public;
grant execute on function public.tpv_subir_mesas(text, jsonb) to anon, authenticated;

-- El TPV recibe también el centro y la mesa de Ágora, el camarero y la nota de cada línea.
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
  v_extra text; v_var text; v_salsa text; v_agora int; v_addin int; v_addins jsonb;
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
            order by (agora_centro is null), creado limit 20 loop
    v_lineas := '[]';
    for l in select * from jsonb_array_elements(r.items) loop
      v_extra := coalesce(l ->> 'extra', '');
      if l ? 'agora_id' then
        v_agora := (l ->> 'agora_id')::int;
        v_addins := coalesce(l -> 'addins', '[]'::jsonb);
        v_salsa := null; v_addin := null;
      else
        select * into pr from public.productos where id = l ->> 'id';
        v_var   := case when lower(v_extra) in ('simple', 'doble') then lower(v_extra) end;
        v_salsa := case when v_extra ilike 'Salsa %' then substr(v_extra, 7) end;
        v_agora := case when v_var = 'doble' then pr.agora_id_doble else pr.agora_id end;
        v_addin := null;
        if v_salsa is not null and pr.agora_salsas is not null then
          select value::int into v_addin from jsonb_each_text(pr.agora_salsas) where lower(key) = lower(v_salsa) limit 1;
        end if;
        v_addins := case when v_addin is not null then jsonb_build_array(jsonb_build_object('id', v_addin, 'nombre', v_salsa, 'precio', 0)) else '[]'::jsonb end;
      end if;
      v_lineas := v_lineas || jsonb_build_object(
        'id', l ->> 'id', 'nombre', l ->> 'nombre', 'extra', nullif(v_extra, ''), 'nota', l ->> 'nota',
        'cant', (l ->> 'cant')::int, 'precio', (l ->> 'precio')::numeric,
        'agora_id', v_agora, 'addins', v_addins,
        'agora_salsa', v_addin, 'salsa', v_salsa);
    end loop;
    v_out := v_out || jsonb_build_object(
      'id', r.id, 'creado', r.creado, 'dia', r.dia, 'hora', to_char(r.hora, 'HH24:MI'),
      'nombre', r.nombre, 'telefono', r.telefono, 'comentario', r.comentario,
      'total', r.total, 'pagado', false, 'lineas', v_lineas, 'intentos', r.agora_intentos,
      'mesa', r.mesa, 'agora_mesa', (select m.agora_mesa from public.terraza_mesas m where m.numero = r.mesa),
      'agora_centro', r.agora_centro, 'agora_ubicacion', r.agora_ubicacion, 'camarero', r.camarero,
      'centro_nombre', (select x ->> 'nombre' from public.pos_estado e, jsonb_array_elements(e.carta -> 'centros') x
                         where e.id = 1 and (x ->> 'id')::int = r.agora_centro));
  end loop;
  return v_out;
end;
$$;
revoke all on function public.agora_pendientes(text) from public;
grant execute on function public.agora_pendientes(text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 25. Quitar productos de una mesa desde la página de camareros
-- ---------------------------------------------------------------
-- La API de Ágora no deja borrar líneas: se manda el mismo producto (con sus extras) con
-- cantidad negativa a la mesa y Ágora lo resta de la cuenta (probado el 2026-11-15).
-- El pedido queda en pedidos_take con quitar = true (cantidades y total en positivo).
alter table public.pedidos_take add column if not exists quitar boolean not null default false;

-- clave de una línea de la mesa: producto | extras ordenados | precio unitario
create or replace function public._pos_clave(l jsonb)
returns text
language sql
immutable
set search_path = public
as $$
  select (l ->> 'id') || '|' ||
         coalesce((select string_agg(a ->> 'id', ',' order by (a ->> 'id')::int) from jsonb_array_elements(coalesce(l -> 'ad', '[]'::jsonb)) a), '') || '|' ||
         to_char(round(coalesce((l ->> 'u')::numeric, 0), 2), 'FM999990.00');
$$;
revoke all on function public._pos_clave(jsonb) from public, anon, authenticated;

-- p = {centro, mesa, clave, cant}
create or replace function public.pos_quitar(p_token text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.pos_camareros; e public.pos_estado; v_cid int; v_mesa text; v_clave text; v_cant int;
  v_lin jsonb; v_hay numeric; v_pend numeric; v_u numeric(8,2); v_pid bigint; v_centro text;
begin
  c := public._pos_sesion(p_token);
  select * into e from public.pos_estado where id = 1;
  begin v_cid := (p ->> 'centro')::int; v_cant := (p ->> 'cant')::int; exception when others then v_cid := null; end;
  v_mesa := p ->> 'mesa'; v_clave := p ->> 'clave';
  if v_cid is null or v_mesa is null or v_clave is null or v_cant is null or v_cant not between 1 and 50 then
    raise exception 'datos inválidos' using errcode = '22023';
  end if;
  -- cuántas unidades de esa línea hay en la mesa según el último dato del TPV
  select sum((l ->> 'c')::numeric) into v_hay
    from jsonb_array_elements(e.mesas) m, jsonb_array_elements(m -> 'lineas') l
   where (m ->> 'centro')::int = v_cid and m ->> 'mesa' = v_mesa and l ->> 'id' is not null and public._pos_clave(l) = v_clave;
  -- (para armar la línea se usa una positiva)
  select l into v_lin
    from jsonb_array_elements(e.mesas) m, jsonb_array_elements(m -> 'lineas') l
   where (m ->> 'centro')::int = v_cid and m ->> 'mesa' = v_mesa and l ->> 'id' is not null and public._pos_clave(l) = v_clave
     and (l ->> 'c')::numeric > 0
   limit 1;
  -- menos lo que ya se mandó a quitar y todavía no figura en la mesa
  select coalesce(sum((i ->> 'cant')::int), 0) into v_pend
    from public.pedidos_take t, jsonb_array_elements(t.items) i
   where t.quitar and t.agora_centro = v_cid and t.agora_ubicacion = v_mesa and t.estado <> 'cancelado'
     and t.creado > now() - interval '2 hours' and i ->> 'clave' = v_clave
     and (t.agora_estado is distinct from 'enviado' or t.agora_enviado > coalesce(e.mesas_actualizadas, now()) - interval '10 seconds');
  if v_lin is null or coalesce(v_hay, 0) - v_pend < v_cant then
    raise exception 'Ese producto ya no está en la mesa (o ya se quitó)' using errcode = '22023';
  end if;
  v_u := (v_lin ->> 'u')::numeric;
  select x ->> 'nombre' into v_centro from jsonb_array_elements(e.carta -> 'centros') x where (x ->> 'id')::int = v_cid;
  insert into public.pedidos_take (dia, hora, nombre, telefono, comentario, items, unidades, total,
                                   agora_centro, agora_ubicacion, camarero, avisado, quitar)
  values ((now() at time zone 'Europe/Madrid')::date, date_trunc('minute', (now() at time zone 'Europe/Madrid')::time),
          left(coalesce(v_centro, 'Centro ' || v_cid) || ' · ' || v_mesa, 80), null, null,
          jsonb_build_array(jsonb_build_object(
            'id', v_lin ->> 'id', 'nombre', v_lin ->> 'n', 'extra', nullif(v_lin ->> 'a', ''), 'cant', v_cant, 'precio', v_u,
            'agora_id', (v_lin ->> 'id')::int, 'clave', v_clave,
            'addins', (select coalesce(jsonb_agg(jsonb_build_object('id', (a ->> 'id')::int, 'nombre', a ->> 'n', 'precio', coalesce((a ->> 'p')::numeric, 0))), '[]'::jsonb)
                         from jsonb_array_elements(coalesce(v_lin -> 'ad', '[]'::jsonb)) a where a ->> 'id' is not null))),
          v_cant, v_cant * v_u, v_cid, v_mesa, c.nombre, now(), true)
  returning id into v_pid;
  return jsonb_build_object('ok', true, 'id', v_pid);
end;
$$;
revoke all on function public.pos_quitar(text, jsonb) from public;
grant execute on function public.pos_quitar(text, jsonb) to anon, authenticated;

-- La página ve también los «quitar» en curso.
create or replace function public.pos_mesas(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare c public.pos_camareros; e public.pos_estado;
begin
  c := public._pos_sesion(p_token);
  select * into e from public.pos_estado where id = 1;
  return jsonb_build_object(
    'mesas', e.mesas, 'actualizadas', e.mesas_actualizadas, 'ahora', now(),
    'pedidos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'centro', p.agora_centro, 'mesa', p.agora_ubicacion, 'camarero', p.camarero, 'quitar', p.quitar,
               'creado', p.creado, 'estado', coalesce(p.agora_estado, 'pendiente'), 'error', p.agora_error,
               'items', (select coalesce(jsonb_agg(jsonb_build_object('nombre', i ->> 'nombre', 'extra', i ->> 'extra', 'cant', i ->> 'cant', 'nota', i ->> 'nota', 'clave', i ->> 'clave')), '[]'::jsonb)
                           from jsonb_array_elements(p.items) i)) order by p.id)
        from public.pedidos_take p
       where p.agora_centro is not null and p.estado <> 'cancelado' and p.creado > now() - interval '2 hours'
         and (p.agora_estado is null or p.agora_estado = 'error'
              or (p.agora_estado = 'enviado' and p.agora_enviado > coalesce(e.mesas_actualizadas, now()) - interval '10 seconds'))), '[]'::jsonb));
end;
$$;
revoke all on function public.pos_mesas(text) from public;
grant execute on function public.pos_mesas(text) to anon, authenticated;

-- Al TPV le llegan los «quitar» con cantidad negativa.
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
  v_extra text; v_var text; v_salsa text; v_agora int; v_addin int; v_addins jsonb;
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
            order by (agora_centro is null), creado limit 20 loop
    v_lineas := '[]';
    for l in select * from jsonb_array_elements(r.items) loop
      v_extra := coalesce(l ->> 'extra', '');
      if l ? 'agora_id' then
        v_agora := (l ->> 'agora_id')::int;
        v_addins := coalesce(l -> 'addins', '[]'::jsonb);
        v_salsa := null; v_addin := null;
      else
        select * into pr from public.productos where id = l ->> 'id';
        v_var   := case when lower(v_extra) in ('simple', 'doble') then lower(v_extra) end;
        v_salsa := case when v_extra ilike 'Salsa %' then substr(v_extra, 7) end;
        v_agora := case when v_var = 'doble' then pr.agora_id_doble else pr.agora_id end;
        v_addin := null;
        if v_salsa is not null and pr.agora_salsas is not null then
          select value::int into v_addin from jsonb_each_text(pr.agora_salsas) where lower(key) = lower(v_salsa) limit 1;
        end if;
        v_addins := case when v_addin is not null then jsonb_build_array(jsonb_build_object('id', v_addin, 'nombre', v_salsa, 'precio', 0)) else '[]'::jsonb end;
      end if;
      v_lineas := v_lineas || jsonb_build_object(
        'id', l ->> 'id', 'nombre', l ->> 'nombre', 'extra', nullif(v_extra, ''), 'nota', l ->> 'nota',
        'cant', (l ->> 'cant')::int * case when r.quitar then -1 else 1 end, 'precio', (l ->> 'precio')::numeric,
        'agora_id', v_agora, 'addins', v_addins,
        'agora_salsa', v_addin, 'salsa', v_salsa);
    end loop;
    v_out := v_out || jsonb_build_object(
      'id', r.id, 'creado', r.creado, 'dia', r.dia, 'hora', to_char(r.hora, 'HH24:MI'),
      'nombre', r.nombre, 'telefono', r.telefono, 'comentario', r.comentario,
      'total', case when r.quitar then -r.total else r.total end, 'pagado', false, 'lineas', v_lineas, 'intentos', r.agora_intentos,
      'mesa', r.mesa, 'agora_mesa', (select m.agora_mesa from public.terraza_mesas m where m.numero = r.mesa),
      'agora_centro', r.agora_centro, 'agora_ubicacion', r.agora_ubicacion, 'camarero', r.camarero, 'quitar', r.quitar,
      'centro_nombre', (select x ->> 'nombre' from public.pos_estado e, jsonb_array_elements(e.carta -> 'centros') x
                         where e.id = 1 and (x ->> 'id')::int = r.agora_centro));
  end loop;
  return v_out;
end;
$$;
revoke all on function public.agora_pendientes(text) from public;
grant execute on function public.agora_pendientes(text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 26. Página de camareros: solo desde dispositivos aceptados
-- ---------------------------------------------------------------
-- Cada iPad / celular guarda una clave propia. La primera vez que alguien pone un PIN correcto
-- desde un dispositivo nuevo, queda «pendiente» con un código de 4 letras; hasta que se acepta en
-- el admin (Pedidos → Camareros) no se puede entrar. Quitar un dispositivo cierra su sesión.
create table if not exists public.pos_dispositivos (
  id          int generated always as identity primary key,
  clave_hash  text not null unique,
  codigo      text not null,
  nombre      text check (nombre is null or char_length(nombre) <= 40),
  estado      text not null default 'pendiente' check (estado in ('pendiente', 'aceptado')),
  pedido_por  text,
  agente      text,
  creado      timestamptz not null default now(),
  aceptado    timestamptz,
  ultimo_uso  timestamptz
);
alter table public.pos_dispositivos enable row level security;
revoke all on public.pos_dispositivos from anon, authenticated;
grant select (id, codigo, nombre, estado, pedido_por, agente, creado, aceptado, ultimo_uso) on public.pos_dispositivos to authenticated;
drop policy if exists pos_dispositivos_admin on public.pos_dispositivos;
create policy pos_dispositivos_admin on public.pos_dispositivos for select to authenticated using (public.es_admin());

alter table public.pos_sesiones add column if not exists dispositivo_id int references public.pos_dispositivos (id) on delete cascade;
-- las sesiones abiertas antes de esto (sin dispositivo) se cierran
delete from public.pos_sesiones where dispositivo_id is null;

drop function if exists public.pos_entrar(text);
create or replace function public.pos_entrar(p_pin text, p_dispositivo text default null, p_agente text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare c public.pos_camareros; d public.pos_dispositivos; v_hash text; v_tok text;
begin
  delete from public.pos_intentos where creado < now() - interval '15 minutes';
  if (select count(*) from public.pos_intentos) >= 20 then
    return jsonb_build_object('ok', false, 'error', 'Demasiados intentos. Esperá unos minutos.');
  end if;
  select * into c from public.pos_camareros where activo and pin_hash = public._pos_pin_hash(left(coalesce(p_pin, ''), 10));
  if c.id is null then
    insert into public.pos_intentos default values;
    return jsonb_build_object('ok', false, 'error', 'PIN incorrecto');
  end if;
  if coalesce(p_dispositivo, '') !~ '^[0-9a-f]{32,64}$' then
    return jsonb_build_object('ok', false, 'error', 'Actualizá la página (Cmd/Ctrl + R) y probá de nuevo.');
  end if;
  v_hash := encode(extensions.digest(p_dispositivo, 'sha256'), 'hex');
  select * into d from public.pos_dispositivos where clave_hash = v_hash;
  if d.id is null then
    if (select count(*) from public.pos_dispositivos where estado = 'pendiente') >= 30 then
      return jsonb_build_object('ok', false, 'error', 'Hay demasiados dispositivos esperando. Pedí que revisen el admin.');
    end if;
    insert into public.pos_dispositivos (clave_hash, codigo, pedido_por, agente)
    values (v_hash, upper(substr(v_hash, 1, 4)), c.nombre, public._txt(p_agente, 120))
    returning * into d;
  elsif d.estado = 'pendiente' then
    update public.pos_dispositivos set pedido_por = c.nombre, agente = coalesce(public._txt(p_agente, 120), agente) where id = d.id;
  end if;
  if d.estado <> 'aceptado' then
    return jsonb_build_object('ok', false, 'pendiente', true, 'codigo', d.codigo,
      'error', 'Este dispositivo todavía no está autorizado.');
  end if;
  delete from public.pos_sesiones where vence < now();
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.pos_sesiones (token_hash, camarero_id, vence, dispositivo_id)
  values (encode(extensions.digest(v_tok, 'sha256'), 'hex'), c.id, now() + interval '14 hours', d.id);
  update public.pos_dispositivos set ultimo_uso = now() where id = d.id;
  return jsonb_build_object('ok', true, 'token', v_tok, 'nombre', c.nombre, 'dispositivo', d.nombre);
end;
$$;
revoke all on function public.pos_entrar(text, text, text) from public;
grant execute on function public.pos_entrar(text, text, text) to anon, authenticated;

-- La sesión vale solo si el dispositivo sigue aceptado.
create or replace function public._pos_sesion(p_token text)
returns public.pos_camareros
language plpgsql
stable
security definer
set search_path = public
as $$
declare c public.pos_camareros;
begin
  select k.* into c
    from public.pos_sesiones s
    join public.pos_camareros k on k.id = s.camarero_id
    join public.pos_dispositivos d on d.id = s.dispositivo_id and d.estado = 'aceptado'
   where s.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') and s.vence > now() and k.activo;
  if c.id is null then raise exception 'sesión vencida' using errcode = '28000'; end if;
  return c;
end;
$$;
revoke all on function public._pos_sesion(text) from public, anon, authenticated;

-- Admin: aceptar / renombrar (p_aceptar) y borrar (rechazar o quitar).
create or replace function public.pos_dispositivo_guardar(p_id int, p_nombre text, p_aceptar boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'sin permiso' using errcode = '42501'; end if;
  update public.pos_dispositivos
     set nombre = nullif(left(btrim(coalesce(p_nombre, '')), 40), ''),
         estado = case when p_aceptar then 'aceptado' else estado end,
         aceptado = case when p_aceptar and estado <> 'aceptado' then now() else aceptado end
   where id = p_id;
  if not found then raise exception 'No existe ese dispositivo' using errcode = '22023'; end if;
end;
$$;
revoke all on function public.pos_dispositivo_guardar(int, text, boolean) from public;
grant execute on function public.pos_dispositivo_guardar(int, text, boolean) to authenticated;

create or replace function public.pos_dispositivo_borrar(p_id int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'sin permiso' using errcode = '42501'; end if;
  delete from public.pos_dispositivos where id = p_id;   -- sus sesiones se borran solas
end;
$$;
revoke all on function public.pos_dispositivo_borrar(int) from public;
grant execute on function public.pos_dispositivo_borrar(int) to authenticated;

-- ---------------------------------------------------------------
-- 27. Página de camareros: orden de los productos elegido en el admin
-- ---------------------------------------------------------------
-- La carta de la página de camareros la sube el TPV desde Ágora (categorías y productos, cada hora).
-- El orden de los productos dentro de cada categoría se guarda aparte, para que esa subida no lo pise:
--   pos_estado.orden = {"<id de categoría>": [id de producto, id de producto, …]}
-- Vale para esa categoría en todos los centros donde aparece. Los productos que no están en la
-- lista (nuevos en Ágora) van al final, en el orden de Ágora. Se edita en Pedidos → Camareros.
alter table public.pos_estado add column if not exists orden jsonb not null default '{}'::jsonb;

-- Lo que necesita el admin para mostrar la carta y ordenarla.
create or replace function public.pos_carta_admin()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare e public.pos_estado;
begin
  if not public.es_admin() then raise exception 'sin permiso' using errcode = '42501'; end if;
  select * into e from public.pos_estado where id = 1;
  return jsonb_build_object(
    'centros', coalesce(e.carta -> 'centros', '[]'::jsonb),
    'carta_actualizada', e.carta_actualizada,
    'orden', coalesce(e.orden, '{}'::jsonb),
    'productos', coalesce((
      select jsonb_object_agg(a.id::text, jsonb_build_object('nombre', a.nombre, 'precio', a.precio))
        from public.agora_catalogo a
       where a.activo and a.id in (
         select (pid)::int
           from jsonb_array_elements(coalesce(e.carta -> 'centros', '[]'::jsonb)) ce,
                jsonb_array_elements(ce -> 'categorias') ca,
                jsonb_array_elements_text(ca -> 'productos') pid)), '{}'::jsonb));
end;
$$;
revoke all on function public.pos_carta_admin() from public, anon;
grant execute on function public.pos_carta_admin() to authenticated;

-- Guarda el orden de una categoría. Lista vacía (o null) = volver al orden de Ágora.
create or replace function public.pos_orden_guardar(p_categoria int, p_orden jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v jsonb;
begin
  if not public.es_admin() then raise exception 'sin permiso' using errcode = '42501'; end if;
  if p_categoria is null then raise exception 'falta la categoría' using errcode = '22023'; end if;
  if p_orden is null or jsonb_typeof(p_orden) <> 'array' or jsonb_array_length(p_orden) = 0 then
    update public.pos_estado set orden = coalesce(orden, '{}'::jsonb) - p_categoria::text where id = 1;
    return;
  end if;
  if jsonb_array_length(p_orden) > 500 then raise exception 'demasiados productos' using errcode = '22023'; end if;
  -- solo números enteros, sin repetir, en el orden recibido
  select coalesce(jsonb_agg(id order by pos), '[]'::jsonb) into v
    from (select (x #>> '{}')::int as id, min(n) as pos
            from jsonb_array_elements(p_orden) with ordinality as t(x, n)
           where jsonb_typeof(x) in ('number', 'string') and (x #>> '{}') ~ '^[0-9]{1,9}$'
           group by 1) s;
  update public.pos_estado set orden = jsonb_set(coalesce(orden, '{}'::jsonb), array[p_categoria::text], v, true) where id = 1;
end;
$$;
revoke all on function public.pos_orden_guardar(int, jsonb) from public, anon;
grant execute on function public.pos_orden_guardar(int, jsonb) to authenticated;

-- La página de camareros recibe también el orden (lo aplica al mostrar los productos).
create or replace function public.pos_datos(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare c public.pos_camareros; e public.pos_estado;
begin
  c := public._pos_sesion(p_token);
  select * into e from public.pos_estado where id = 1;
  return jsonb_build_object(
    'camarero', c.nombre,
    'centros', coalesce(e.carta -> 'centros', '[]'::jsonb),
    'carta_actualizada', e.carta_actualizada,
    'orden', coalesce(e.orden, '{}'::jsonb),
    'productos', coalesce((
      select jsonb_object_agg(a.id::text, jsonb_build_object('nombre', a.nombre, 'precio', a.precio, 'roles', a.roles))
        from public.agora_catalogo a
       where a.activo and a.id in (
         select (pid)::int
           from jsonb_array_elements(coalesce(e.carta -> 'centros', '[]'::jsonb)) ce,
                jsonb_array_elements(ce -> 'categorias') ca,
                jsonb_array_elements_text(ca -> 'productos') pid)), '{}'::jsonb));
end;
$$;
revoke all on function public.pos_datos(text) from public;
grant execute on function public.pos_datos(text) to anon, authenticated;

-- ---------------------------------------------------------------
-- 28. Pago online con tarjeta (TPV virtual de CaixaBank / Redsys)
-- ---------------------------------------------------------------
-- Take away (terrysburgers.com/pedido/) y terraza (terrysburgers.com/terraza/): el cliente puede
-- pagar online o seguir pagando al retirar / al camarero.
--   1. web_pagar() valida el pedido igual que web_pedir / web_pedir_mesa, lo guarda en pagos_web
--      (todavía NO es un pedido) y devuelve el formulario firmado para ir a la página de Redsys.
--   2. Redsys avisa el resultado a redsys_notificacion() (POST directo a Supabase). Si la firma es
--      buena y el pago está autorizado, recién ahí se crea el pedido en pedidos_take con pagado = true:
--      el TPV lo carga en Ágora como pagado y entra solo a cocina. Los pagos abandonados no dejan pedido.
--   3. El cliente vuelve a la web y web_pago_estado() le dice cómo salió.
-- La clave secreta vive solo en pago_redsys (nadie la puede leer desde la web ni desde el admin).

-- Configuración (una sola fila). La clave y el código de prueba se cargan aparte, fuera del repo.
create table if not exists public.pago_redsys (
  id            int primary key default 1 check (id = 1),
  activo        boolean not null default false,
  entorno       text not null default 'pruebas' check (entorno in ('pruebas', 'real')),
  comercio      text not null,
  terminal      text not null default '1',
  moneda        text not null default '978',
  clave         text,
  nombre        text not null default 'TERRYS BURGERS',
  web           text not null default 'https://terrysburgers.com',
  notificacion  text not null,
  codigo_prueba text          -- en pruebas, solo se ofrece con ?pago-prueba=<código> en la dirección
);
alter table public.pago_redsys enable row level security;
revoke all on public.pago_redsys from anon, authenticated;
insert into public.pago_redsys (id, comercio, notificacion)
values (1, '369781448',
        'https://cgkpklimplpedgxbgzvu.supabase.co/rest/v1/rpc/redsys_notificacion?apikey=sb_publishable_yG1hrdoynoxBBYh9LX7QpA_we_bb_qC')
on conflict (id) do nothing;

-- Cada intento de pago (un pedido puede tener varios si el primero se rechaza).
create table if not exists public.pagos_web (
  id            bigint generated always as identity primary key,
  creado        timestamptz not null default now(),
  orden         text unique,                 -- Ds_Merchant_Order (12: 8 números + 4 letras/números)
  token         text not null unique,        -- para que la página consulte cómo salió
  tipo          text not null check (tipo in ('take', 'mesa')),
  entorno       text not null,
  datos         jsonb not null,              -- el pedido ya validado y cobrado
  telefono      text,
  importe       numeric(8,2) not null check (importe > 0),
  estado        text not null default 'esperando' check (estado in ('esperando', 'pagado', 'denegado', 'error')),
  respuesta     text,                        -- Ds_Response
  autorizacion  text,                        -- Ds_AuthorisationCode
  notificacion  jsonb,
  notificado    timestamptz,
  pedido_id     bigint references public.pedidos_take (id) on delete set null
);
alter table public.pagos_web enable row level security;
revoke all on public.pagos_web from anon, authenticated;
grant select on public.pagos_web to authenticated;
drop policy if exists pagos_web_admin on public.pagos_web;
create policy pagos_web_admin on public.pagos_web for select to authenticated using (public.es_admin());

alter table public.pedidos_take add column if not exists pagado boolean not null default false;
alter table public.pedidos_take add column if not exists pago_ref text;   -- pagos_web.orden

-- ---------- Firma de Redsys (HMAC_SHA256_V1) ----------
-- clave del pedido = 3DES-CBC (IV en ceros) del número de pedido con la clave secreta;
-- firma = HMAC-SHA256 de Ds_MerchantParameters (tal cual, en base64) con esa clave, en base64.
create or replace function public._b64(b bytea)
returns text language sql immutable
as $$ select translate(encode(b, 'base64'), E'\n\r', ''); $$;
revoke all on function public._b64(bytea) from public, anon, authenticated;

create or replace function public._redsys_firma(p_params text, p_orden text, p_clave text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare v_o bytea := convert_to(p_orden, 'UTF8');
begin
  -- el número de pedido se completa con ceros hasta múltiplo de 8 bytes
  if length(v_o) % 8 <> 0 then
    v_o := v_o || decode(repeat('00', 8 - length(v_o) % 8), 'hex');
  end if;
  return public._b64(extensions.hmac(convert_to(p_params, 'UTF8'),
           extensions.encrypt_iv(v_o, decode(p_clave, 'base64'), decode('0000000000000000', 'hex'), '3des-cbc/pad:none'),
           'sha256'));
end;
$$;
revoke all on function public._redsys_firma(text, text, text) from public, anon, authenticated;

-- ---------- Validación compartida (pedido normal y pedido con pago) ----------
-- Take away: {dia, hora, nombre, telefono, comentario, items} → pedido listo para guardar
create or replace function public._pedido_take_datos(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoy   date := (now() at time zone 'Europe/Madrid')::date;
  v_ahora time := (now() at time zone 'Europe/Madrid')::time;
  v_dia date; v_hora time;
  v_tel text := public._txt(p ->> 'telefono', 30);
  v_l jsonb;
begin
  begin
    v_dia  := (p ->> 'dia')::date;
    v_hora := (p ->> 'hora')::time;
  exception when others then
    raise exception 'datos inválidos' using errcode = '22023';
  end;
  if v_dia is null or v_dia < v_hoy or v_dia > v_hoy + 1 then
    raise exception 'día fuera de rango' using errcode = '22023';
  end if;
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
  v_l := public._pedido_lineas(p -> 'items', false, v_dia, v_hora);
  if (select count(*) from public.pedidos_take where telefono = v_tel and creado > now() - interval '1 day') >= 5
     or (select count(*) from public.pedidos_take where creado > now() - interval '1 day') >= 300 then
    raise exception 'demasiados pedidos, llamanos' using errcode = '54000';
  end if;
  return jsonb_build_object(
    'dia', v_dia, 'hora', to_char(v_hora, 'HH24:MI'), 'nombre', public._txt(p ->> 'nombre', 80), 'telefono', v_tel,
    'comentario', public._txt(p ->> 'comentario', 500), 'lineas', v_l -> 'lineas',
    'unidades', (v_l ->> 'unidades')::int, 'total', (v_l ->> 'total')::numeric, 'mesa', null);
end;
$$;
revoke all on function public._pedido_take_datos(jsonb) from public, anon, authenticated;

-- Terraza: {mesa, codigo, nombre?, comentario?, items}
create or replace function public._pedido_mesa_datos(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dia  date := (now() at time zone 'Europe/Madrid')::date;
  v_hora time := date_trunc('minute', (now() at time zone 'Europe/Madrid')::time);
  v_m public.terraza_mesas;
  v_l jsonb;
begin
  begin
    select * into v_m from public.terraza_mesas
     where numero = (p ->> 'mesa')::int and codigo = coalesce(p ->> 'codigo', '') and activa;
  exception when others then v_m := null; end;
  if v_m.numero is null then raise exception 'mesa inválida' using errcode = '22023'; end if;
  if not (v_hora between time '12:00' and time '16:30' or v_hora >= time '19:00') then
    raise exception 'terraza cerrada' using errcode = '22023';
  end if;
  if (select count(*) from public.pedidos_take where mesa = v_m.numero and creado > now() - interval '3 hours') >= 15
     or (select count(*) from public.pedidos_take where creado > now() - interval '1 day') >= 300 then
    raise exception 'demasiados pedidos, llamá al camarero' using errcode = '54000';
  end if;
  v_l := public._pedido_lineas(p -> 'items', true, v_dia, v_hora);
  return jsonb_build_object(
    'dia', v_dia, 'hora', to_char(v_hora, 'HH24:MI'),
    'nombre', coalesce(case when char_length(public._txt(p ->> 'nombre', 80)) >= 2 then public._txt(p ->> 'nombre', 80) end, v_m.nombre),
    'telefono', null, 'comentario', public._txt(p ->> 'comentario', 500), 'lineas', v_l -> 'lineas',
    'unidades', (v_l ->> 'unidades')::int, 'total', (v_l ->> 'total')::numeric,
    'mesa', v_m.numero, 'mesa_nombre', v_m.nombre, 'codigo', v_m.codigo);
end;
$$;
revoke all on function public._pedido_mesa_datos(jsonb) from public, anon, authenticated;

create or replace function public._pedido_guardar(d jsonb, p_pagado boolean, p_ref text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v_pid bigint;
begin
  insert into public.pedidos_take (dia, hora, nombre, telefono, comentario, items, unidades, total, mesa, pagado, pago_ref)
  values ((d ->> 'dia')::date, (d ->> 'hora')::time, d ->> 'nombre', d ->> 'telefono', d ->> 'comentario',
          d -> 'lineas', (d ->> 'unidades')::int, (d ->> 'total')::numeric, (d ->> 'mesa')::int, p_pagado, p_ref)
  returning id into v_pid;
  return v_pid;
end;
$$;
revoke all on function public._pedido_guardar(jsonb, boolean, text) from public, anon, authenticated;

-- Pedido para pagar al retirar (misma respuesta que antes).
create or replace function public.web_pedir(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare d jsonb; v_pid bigint;
begin
  if public._txt(p ->> 'web', 200) is not null then return jsonb_build_object('ok', true); end if;   -- trampa para bots
  d := public._pedido_take_datos(p);
  v_pid := public._pedido_guardar(d, false, null);
  return jsonb_build_object('ok', true, 'id', v_pid, 'total', (d ->> 'total')::numeric);
end;
$$;
revoke all on function public.web_pedir(jsonb) from public;
grant execute on function public.web_pedir(jsonb) to anon, authenticated;

-- Pedido de mesa para pagar al camarero (misma respuesta que antes).
create or replace function public.web_pedir_mesa(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare d jsonb; v_pid bigint;
begin
  if public._txt(p ->> 'web', 200) is not null then return jsonb_build_object('ok', true); end if;
  d := public._pedido_mesa_datos(p);
  v_pid := public._pedido_guardar(d, false, null);
  return jsonb_build_object('ok', true, 'id', v_pid, 'total', (d ->> 'total')::numeric, 'mesa', d ->> 'mesa_nombre');
end;
$$;
revoke all on function public.web_pedir_mesa(jsonb) from public;
grant execute on function public.web_pedir_mesa(jsonb) to anon, authenticated;

-- ¿Se ofrece pagar online? (en pruebas, solo con el código de prueba en la dirección)
create or replace function public.web_pago_info(p_prueba text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('online', coalesce((
    select c.activo and c.clave is not null
           and (c.entorno = 'real' or (c.codigo_prueba is not null and p_prueba = c.codigo_prueba))
      from public.pago_redsys c where c.id = 1), false));
$$;
revoke all on function public.web_pago_info(text) from public;
grant execute on function public.web_pago_info(text) to anon, authenticated;

-- Arranca un pago: p = el mismo pedido que web_pedir / web_pedir_mesa (+ prueba).
-- → {ok, url, params: {Ds_SignatureVersion, Ds_MerchantParameters, Ds_Signature}, token, total}
create or replace function public.web_pagar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.pago_redsys; d jsonb; v_tipo text; v_id bigint; v_orden text; v_token text;
  v_volver text; v_params text; v_json jsonb;
begin
  if public._txt(p ->> 'web', 200) is not null then raise exception 'datos inválidos' using errcode = '22023'; end if;
  select * into c from public.pago_redsys where id = 1;
  if c.id is null or not c.activo or c.clave is null
     or (c.entorno = 'pruebas' and (c.codigo_prueba is null or coalesce(p ->> 'prueba', '') <> c.codigo_prueba)) then
    raise exception 'pago online no disponible' using errcode = '22023';
  end if;
  v_tipo := case when p ? 'mesa' then 'mesa' else 'take' end;
  d := case when v_tipo = 'mesa' then public._pedido_mesa_datos(p) else public._pedido_take_datos(p) end;
  -- freno: intentos de pago por teléfono (take away) o por mesa, y en total
  if (v_tipo = 'take' and (select count(*) from public.pagos_web where telefono = d ->> 'telefono' and creado > now() - interval '1 day') >= 10)
     or (v_tipo = 'mesa' and (select count(*) from public.pagos_web where tipo = 'mesa' and (datos ->> 'mesa')::int = (d ->> 'mesa')::int and creado > now() - interval '3 hours') >= 20)
     or (select count(*) from public.pagos_web where creado > now() - interval '1 day') >= 500 then
    raise exception 'demasiados pedidos, llamanos' using errcode = '54000';
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  insert into public.pagos_web (token, tipo, entorno, datos, telefono, importe)
  values (v_token, v_tipo, c.entorno, d - 'codigo', d ->> 'telefono', (d ->> 'total')::numeric)
  returning id into v_id;
  -- número de pedido para Redsys: 4 a 12 caracteres, los 4 primeros números, único
  v_orden := lpad((v_id % 100000000)::text, 8, '0') || upper(substr(v_token, 1, 4));
  update public.pagos_web set orden = v_orden where id = v_id;

  v_volver := case when v_tipo = 'mesa'
                   then c.web || '/terraza/?m=' || (d ->> 'mesa') || '&c=' || (d ->> 'codigo') || '&pago=' || v_token
                   else c.web || '/pedido/?pago=' || v_token end;
  v_json := jsonb_build_object(
    'DS_MERCHANT_AMOUNT', (round((d ->> 'total')::numeric * 100))::bigint::text,
    'DS_MERCHANT_ORDER', v_orden,
    'DS_MERCHANT_MERCHANTCODE', c.comercio,
    'DS_MERCHANT_CURRENCY', c.moneda,
    'DS_MERCHANT_TRANSACTIONTYPE', '0',
    'DS_MERCHANT_TERMINAL', c.terminal,
    'DS_MERCHANT_MERCHANTURL', c.notificacion,
    'DS_MERCHANT_URLOK', v_volver,
    'DS_MERCHANT_URLKO', v_volver || '&ko=1',
    'DS_MERCHANT_MERCHANTNAME', c.nombre,
    'DS_MERCHANT_PRODUCTDESCRIPTION', case when v_tipo = 'mesa' then 'Pedido terraza ' else 'Pedido take away ' end || v_id,
    'DS_MERCHANT_CONSUMERLANGUAGE', '001');
  v_params := public._b64(convert_to(v_json::text, 'UTF8'));
  return jsonb_build_object('ok', true, 'token', v_token, 'total', (d ->> 'total')::numeric,
    'url', case when c.entorno = 'real' then 'https://sis.redsys.es/sis/realizarPago'
                else 'https://sis-t.redsys.es:25443/sis/realizarPago' end,
    'params', jsonb_build_object('Ds_SignatureVersion', 'HMAC_SHA256_V1', 'Ds_MerchantParameters', v_params,
                                 'Ds_Signature', public._redsys_firma(v_params, v_orden, c.clave)));
end;
$$;
revoke all on function public.web_pagar(jsonb) from public;
grant execute on function public.web_pagar(jsonb) to anon, authenticated;

-- Aviso de Redsys (POST con Ds_SignatureVersion, Ds_MerchantParameters y Ds_Signature).
-- Se puede llamar desde cualquier lado: sin la clave secreta no hay firma válida.
-- La página también lo llama con lo que Redsys le agrega a la dirección de vuelta (si lo agrega).
create or replace function public.redsys_notificacion("Ds_SignatureVersion" text default null,
                                                     "Ds_MerchantParameters" text default null,
                                                     "Ds_Signature" text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.pago_redsys; v_json jsonb; v_orden text; v_pw public.pagos_web; v_resp int; v_amount bigint; v_pid bigint;
  v_p text := "Ds_MerchantParameters";
begin
  select * into c from public.pago_redsys where id = 1;
  if c.clave is null or v_p is null or "Ds_Signature" is null or length(v_p) > 20000 then return 'KO'; end if;
  begin
    v_json := convert_from(decode(rpad(translate(v_p, '-_', '+/'), ((length(v_p) + 3) / 4) * 4, '='), 'base64'), 'UTF8')::jsonb;
    select jsonb_object_agg(lower(key), value) into v_json from jsonb_each(v_json);   -- Ds_Order / DS_ORDER
  exception when others then return 'KO'; end;
  v_orden := v_json ->> 'ds_order';
  if v_orden is null or v_orden !~ '^[0-9A-Za-z]{4,12}$' then return 'KO'; end if;
  if rtrim(translate(public._redsys_firma(v_p, v_orden, c.clave), '+/', '-_'), '=')
     <> rtrim(translate("Ds_Signature", '+/', '-_'), '=') then
    return 'KO';
  end if;

  select * into v_pw from public.pagos_web where orden = v_orden for update;
  if v_pw.id is null then return 'KO'; end if;
  if v_pw.estado = 'pagado' then return 'OK'; end if;       -- el aviso puede llegar dos veces
  begin
    v_resp := nullif(regexp_replace(coalesce(v_json ->> 'ds_response', ''), '\D', '', 'g'), '')::int;
    v_amount := (v_json ->> 'ds_amount')::bigint;
  exception when others then v_resp := null; end;

  if v_resp between 0 and 99 and v_amount = round(v_pw.importe * 100) and v_json ->> 'ds_merchantcode' = c.comercio then
    v_pid := public._pedido_guardar(v_pw.datos, true, v_orden);
    update public.pagos_web set estado = 'pagado', pedido_id = v_pid, respuesta = v_json ->> 'ds_response',
           autorizacion = nullif(btrim(v_json ->> 'ds_authorisationcode'), ''), notificacion = v_json, notificado = now()
     where id = v_pw.id;
  else
    update public.pagos_web set estado = case when v_resp between 0 and 99 then 'error' else 'denegado' end,
           respuesta = v_json ->> 'ds_response', notificacion = v_json, notificado = now()
     where id = v_pw.id;
  end if;
  return 'OK';
end;
$$;
revoke all on function public.redsys_notificacion(text, text, text) from public;
grant execute on function public.redsys_notificacion(text, text, text) to anon, authenticated;

-- La página, al volver de Redsys: ¿cómo salió? (solo con el token de ese pago)
create or replace function public.web_pago_estado(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'estado', case when w.estado = 'esperando' and w.creado < now() - interval '40 minutes' then 'vencido' else w.estado end,
           'pedido', w.pedido_id, 'total', w.importe, 'tipo', w.tipo,
           'dia', w.datos ->> 'dia', 'hora', w.datos ->> 'hora', 'mesa', w.datos ->> 'mesa_nombre')
    from public.pagos_web w
   where w.token = left(coalesce(p_token, ''), 64);
$$;
revoke all on function public.web_pago_estado(text) from public;
grant execute on function public.web_pago_estado(text) to anon, authenticated;

-- El aviso al celular dice si ya está pagado.
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
  -- Datos sueltos: el texto lo arma el TPV (sin nombre ni teléfono del cliente).
  return jsonb_build_object('tema', a.ntfy_tema, 'avisos', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'dia', to_char(p.dia, 'DD/MM'), 'hora', to_char(p.hora, 'HH24:MI'),
      'cuando', case when p.dia = v_hoy then 'hoy' when p.dia = v_hoy + 1 then 'manana' else 'otro' end,
      'unidades', p.unidades, 'total', p.total, 'comentario', p.comentario is not null, 'mesa', p.mesa, 'pagado', p.pagado,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('cant', i ->> 'cant', 'nombre', i ->> 'nombre', 'extra', i ->> 'extra')), '[]'::jsonb)
                  from jsonb_array_elements(p.items) i)) order by p.creado)
    from public.pedidos_take p
    where p.avisado is null and p.estado <> 'cancelado' and p.creado > now() - interval '6 hours'), '[]'::jsonb));
end;
$$;
revoke all on function public.tpv_avisos_pendientes(text) from public;
grant execute on function public.tpv_avisos_pendientes(text) to anon, authenticated;

-- Al TPV le llega «pagado»: Ágora lo registra con la forma de pago de la web y lo pasa solo a cocina.
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
  v_extra text; v_var text; v_salsa text; v_agora int; v_addin int; v_addins jsonb;
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
            order by (agora_centro is null), creado limit 20 loop
    v_lineas := '[]';
    for l in select * from jsonb_array_elements(r.items) loop
      v_extra := coalesce(l ->> 'extra', '');
      if l ? 'agora_id' then
        v_agora := (l ->> 'agora_id')::int;
        v_addins := coalesce(l -> 'addins', '[]'::jsonb);
        v_salsa := null; v_addin := null;
      else
        select * into pr from public.productos where id = l ->> 'id';
        v_var   := case when lower(v_extra) in ('simple', 'doble') then lower(v_extra) end;
        v_salsa := case when v_extra ilike 'Salsa %' then substr(v_extra, 7) end;
        v_agora := case when v_var = 'doble' then pr.agora_id_doble else pr.agora_id end;
        v_addin := null;
        if v_salsa is not null and pr.agora_salsas is not null then
          select value::int into v_addin from jsonb_each_text(pr.agora_salsas) where lower(key) = lower(v_salsa) limit 1;
        end if;
        v_addins := case when v_addin is not null then jsonb_build_array(jsonb_build_object('id', v_addin, 'nombre', v_salsa, 'precio', 0)) else '[]'::jsonb end;
      end if;
      v_lineas := v_lineas || jsonb_build_object(
        'id', l ->> 'id', 'nombre', l ->> 'nombre', 'extra', nullif(v_extra, ''), 'nota', l ->> 'nota',
        'cant', (l ->> 'cant')::int * case when r.quitar then -1 else 1 end, 'precio', (l ->> 'precio')::numeric,
        'agora_id', v_agora, 'addins', v_addins,
        'agora_salsa', v_addin, 'salsa', v_salsa);
    end loop;
    v_out := v_out || jsonb_build_object(
      'id', r.id, 'creado', r.creado, 'dia', r.dia, 'hora', to_char(r.hora, 'HH24:MI'),
      'nombre', r.nombre, 'telefono', r.telefono, 'comentario', r.comentario,
      'total', case when r.quitar then -r.total else r.total end, 'pagado', r.pagado, 'pago_ref', r.pago_ref,
      'lineas', v_lineas, 'intentos', r.agora_intentos,
      'mesa', r.mesa, 'agora_mesa', (select m.agora_mesa from public.terraza_mesas m where m.numero = r.mesa),
      'agora_centro', r.agora_centro, 'agora_ubicacion', r.agora_ubicacion, 'camarero', r.camarero, 'quitar', r.quitar,
      'centro_nombre', (select x ->> 'nombre' from public.pos_estado e, jsonb_array_elements(e.carta -> 'centros') x
                         where e.id = 1 and (x ->> 'id')::int = r.agora_centro));
  end loop;
  return v_out;
end;
$$;
revoke all on function public.agora_pendientes(text) from public;
grant execute on function public.agora_pendientes(text) to anon, authenticated;
