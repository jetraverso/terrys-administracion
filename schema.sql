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
    select jsonb_object_agg(a, (select jsonb_build_object('id', m.id, 'fecha', m.fecha, 'egreso', m.egreso, 'detalle', m.detalle, 'revisar', m.revisar)
                                  from public.movimientos m where m.empresa = p_empresa and m.archivo = a))
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
