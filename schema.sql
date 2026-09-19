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

drop policy if exists movimientos_admin on public.movimientos;
create policy movimientos_admin on public.movimientos
  for all to authenticated
  using (public.es_admin())
  with check (public.es_admin());

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
    new.actualizado_por := quien;
    insert into public.movimientos_log (mov_id, accion, quien, antes, despues)
    values (old.id, 'editar', quien, to_jsonb(old), to_jsonb(new));
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
  values (new.id, 'crear', auth.jwt() ->> 'email', to_jsonb(new));
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
