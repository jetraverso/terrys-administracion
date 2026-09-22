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
-- ingresos en la planilla de Compras (una por día, total cobrado con IVA, y el
-- desglose por forma de pago en Información). Esas filas llevan origen='agora'
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
      select coalesce(p ->> 'MethodName', '—') m, sum((p ->> 'Amount')::numeric) s
        from jsonb_array_elements(coalesce(p_datos -> 'Invoices', '[]'::jsonb)) i,
             jsonb_array_elements(coalesce(i -> 'Payments', '[]'::jsonb)) p
       group by 1
    ) x;

  insert into public.movimientos (empresa, fecha, ingreso, egreso, detalle, tipo, desde, hacia, estado, informacion, factura, pagado, clara, comentarios, origen, ref, creado_por)
  values (p_empresa, p_dia, total, null, 'Ventas del día', 'Ventas', 'Ágora', 'Terrys', 'Terminado',
          tickets || ' tickets · ' || coalesce(desglose, ''), '', true, false, '', 'agora', p_dia::text, 'agora')
  on conflict (empresa, origen, ref) where origen is not null do update
    set fecha = excluded.fecha, ingreso = excluded.ingreso, informacion = excluded.informacion, actualizado_por = 'agora';
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
