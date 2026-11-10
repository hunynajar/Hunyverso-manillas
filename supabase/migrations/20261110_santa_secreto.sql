-- Santa Secreto: grupos, votación de administradora, listas de regalos, sorteo, mensajitos anónimos y revelación.
-- Las tablas no tienen acceso directo desde el navegador: todo pasa por funciones security definer
-- que verifican quién eres y si perteneces al grupo. Así nadie puede ver asignaciones, votos ni remitentes.

create table if not exists public.santa_grupos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (char_length(nombre) between 1 and 60),
  creador_id uuid not null references public.usuarios(id) on delete cascade,
  estado text not null default 'abierto' check (estado in ('abierto','votacion','listo','sorteado')),
  admin_id uuid references public.usuarios(id) on delete set null,
  fecha_reunion timestamptz,
  precio_min integer check (precio_min between 0 and 1000000),
  precio_max integer check (precio_max between 0 and 1000000),
  creado_en timestamptz not null default now(),
  check (precio_min is null or precio_max is null or precio_min <= precio_max)
);

create table if not exists public.santa_miembros (
  grupo_id uuid not null references public.santa_grupos(id) on delete cascade,
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  agregado_por uuid references public.usuarios(id) on delete set null,
  voto uuid references public.usuarios(id) on delete set null,
  regalos jsonb not null default '[]'::jsonb,
  revelar boolean not null default false,
  unido_en timestamptz not null default now(),
  primary key (grupo_id, usuario_id)
);
create index if not exists santa_miembros_usuario on public.santa_miembros(usuario_id);

create table if not exists public.santa_asignaciones (
  grupo_id uuid not null references public.santa_grupos(id) on delete cascade,
  santa_id uuid not null references public.usuarios(id) on delete cascade,
  receptor_id uuid not null references public.usuarios(id) on delete cascade,
  primary key (grupo_id, santa_id),
  unique (grupo_id, receptor_id),
  check (santa_id <> receptor_id)
);

create table if not exists public.santa_mensajes (
  id bigint generated always as identity primary key,
  grupo_id uuid not null references public.santa_grupos(id) on delete cascade,
  santa_id uuid not null references public.usuarios(id) on delete cascade,
  receptor_id uuid not null references public.usuarios(id) on delete cascade,
  mensaje text not null check (char_length(mensaje) between 1 and 300),
  leido boolean not null default false,
  creado_en timestamptz not null default now()
);
create index if not exists santa_mensajes_receptor on public.santa_mensajes(receptor_id, leido);

alter table public.santa_grupos enable row level security;
alter table public.santa_miembros enable row level security;
alter table public.santa_asignaciones enable row level security;
alter table public.santa_mensajes enable row level security;
revoke all on public.santa_grupos, public.santa_miembros, public.santa_asignaciones, public.santa_mensajes from anon, authenticated;

-- ---------- utilidades internas ----------
create or replace function public.santa_yo() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid := public.mi_usuario_id();
begin
  if v is null then raise exception 'Inicia sesión para continuar.'; end if;
  return v;
end $$;

create or replace function public.santa_grupo_de(p_grupo uuid, p_yo uuid) returns public.santa_grupos
language plpgsql stable security definer set search_path = public as $$
declare g public.santa_grupos;
begin
  select * into g from public.santa_grupos where id = p_grupo;
  if g.id is null or not exists (select 1 from public.santa_miembros where grupo_id = p_grupo and usuario_id = p_yo) then
    raise exception 'No perteneces a este grupo.';
  end if;
  return g;
end $$;

create or replace function public.santa_regalos_validos(p jsonb, p_min integer, p_max integer) returns boolean
language plpgsql immutable set search_path = public as $$
declare r jsonb; v_precio numeric;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) <> 3 or p_min is null or p_max is null then return false; end if;
  for r in select * from jsonb_array_elements(p) loop
    if jsonb_typeof(r) <> 'object' then return false; end if;
    if char_length(trim(coalesce(r->>'desc', ''))) not between 1 and 120 then return false; end if;
    if jsonb_typeof(r->'precio') <> 'number' then return false; end if;
    v_precio := (r->>'precio')::numeric;
    if v_precio < p_min or v_precio > p_max then return false; end if;
    if coalesce(r->>'link', '') <> '' and ((r->>'link') !~* '^https?://[^\s<>"]+$' or char_length(r->>'link') > 500) then return false; end if;
  end loop;
  return true;
end $$;

-- ---------- grupo ----------
create or replace function public.santa_crear(p_nombre text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); v_id uuid; v_nombre text := left(trim(coalesce(p_nombre, '')), 60);
begin
  if v_nombre = '' then raise exception 'Escribe un nombre para el grupo.'; end if;
  if (select count(*) from public.santa_grupos where creador_id = v_yo) >= 10 then raise exception 'Ya creaste muchos grupos.'; end if;
  insert into public.santa_grupos (nombre, creador_id) values (v_nombre, v_yo) returning id into v_id;
  insert into public.santa_miembros (grupo_id, usuario_id, agregado_por) values (v_id, v_yo, v_yo);
  return v_id;
end $$;

create or replace function public.santa_agregar(p_grupo uuid, p_usuario uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
begin
  if g.estado <> 'abierto' then raise exception 'El grupo está cerrado. Pídele a quien lo creó que lo reabra.'; end if;
  if not exists (select 1 from public.contactos_usuarios where usuario_id = v_yo and amigo_id = p_usuario) then
    raise exception 'Solo puedes agregar a tus amigos de la app.';
  end if;
  if exists (select 1 from public.santa_miembros where grupo_id = p_grupo and usuario_id = p_usuario) then
    raise exception 'Esa persona ya está en el grupo.';
  end if;
  perform 1 from public.santa_grupos where id = p_grupo for update;
  if (select count(*) from public.santa_miembros where grupo_id = p_grupo) >= 20 then raise exception 'El grupo ya tiene 20 personas.'; end if;
  insert into public.santa_miembros (grupo_id, usuario_id, agregado_por) values (p_grupo, p_usuario, v_yo);
end $$;

create or replace function public.santa_salir(p_grupo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
begin
  if g.estado <> 'abierto' then raise exception 'Solo puedes salir mientras el grupo está abierto.'; end if;
  if g.creador_id = v_yo then raise exception 'Creaste este grupo: si ya no quieres jugar, elimínalo.'; end if;
  delete from public.santa_miembros where grupo_id = p_grupo and usuario_id = v_yo;
end $$;

create or replace function public.santa_quitar(p_grupo uuid, p_usuario uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
begin
  if g.creador_id <> v_yo then raise exception 'Solo quien creó el grupo puede quitar personas.'; end if;
  if g.estado <> 'abierto' then raise exception 'Reabre el grupo para quitar personas.'; end if;
  if p_usuario = v_yo then raise exception 'No puedes quitarte a ti misma.'; end if;
  delete from public.santa_miembros where grupo_id = p_grupo and usuario_id = p_usuario;
end $$;

create or replace function public.santa_eliminar(p_grupo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
begin
  if g.creador_id <> v_yo then raise exception 'Solo quien creó el grupo puede eliminarlo.'; end if;
  if g.estado = 'sorteado' and now() < g.fecha_reunion then raise exception 'El sorteo ya se hizo: el grupo se puede eliminar después de la reunión.'; end if;
  delete from public.santa_grupos where id = p_grupo;
end $$;

create or replace function public.santa_cerrar(p_grupo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
begin
  if g.creador_id <> v_yo then raise exception 'Solo quien creó el grupo puede cerrarlo.'; end if;
  if g.estado <> 'abierto' then raise exception 'El grupo ya está cerrado.'; end if;
  if (select count(*) from public.santa_miembros where grupo_id = p_grupo) < 3 then raise exception 'Se necesitan al menos 3 personas.'; end if;
  update public.santa_miembros set voto = null where grupo_id = p_grupo;
  update public.santa_grupos set estado = 'votacion', admin_id = null where id = p_grupo;
end $$;

create or replace function public.santa_reabrir(p_grupo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
begin
  if g.creador_id <> v_yo then raise exception 'Solo quien creó el grupo puede reabrirlo.'; end if;
  if g.estado = 'sorteado' then raise exception 'El sorteo ya se hizo; no se puede reabrir.'; end if;
  if g.estado = 'abierto' then return; end if;
  update public.santa_miembros set voto = null where grupo_id = p_grupo;
  update public.santa_grupos set estado = 'abierto', admin_id = null where id = p_grupo;
end $$;

create or replace function public.santa_votar(p_grupo uuid, p_candidata uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo); v_admin uuid;
begin
  if g.estado <> 'votacion' then raise exception 'La votación no está abierta.'; end if;
  if not exists (select 1 from public.santa_miembros where grupo_id = p_grupo and usuario_id = p_candidata) then
    raise exception 'Esa persona no está en el grupo.';
  end if;
  perform 1 from public.santa_grupos where id = p_grupo for update;
  update public.santa_miembros set voto = p_candidata where grupo_id = p_grupo and usuario_id = v_yo;
  if not exists (select 1 from public.santa_miembros where grupo_id = p_grupo and voto is null) then
    with conteo as (select voto, count(*) n from public.santa_miembros where grupo_id = p_grupo group by voto)
    select voto into v_admin from conteo where n = (select max(n) from conteo) order by random() limit 1;
    update public.santa_grupos set estado = 'listo', admin_id = v_admin where id = p_grupo;
  end if;
end $$;

create or replace function public.santa_configurar(p_grupo uuid, p_fecha timestamptz, p_min integer, p_max integer) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
begin
  if g.admin_id is distinct from v_yo or g.estado not in ('listo','sorteado') then raise exception 'Solo la administradora puede hacer esto.'; end if;
  if p_fecha is null or p_fecha <= now() then raise exception 'Elige una fecha y hora en el futuro.'; end if;
  if g.estado = 'sorteado' then
    if now() >= g.fecha_reunion then raise exception 'La reunión ya pasó.'; end if;
    update public.santa_grupos set fecha_reunion = p_fecha where id = p_grupo;
    return;
  end if;
  if p_min is null or p_max is null or p_min < 0 or p_max > 1000000 or p_min > p_max then raise exception 'El rango de valor no es válido.'; end if;
  update public.santa_grupos set fecha_reunion = p_fecha, precio_min = p_min, precio_max = p_max where id = p_grupo;
end $$;

create or replace function public.santa_guardar_regalos(p_grupo uuid, p_regalos jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo); v jsonb;
begin
  if g.estado <> 'listo' then raise exception 'Ahora no se puede cambiar la lista de regalos.'; end if;
  if g.precio_min is null then raise exception 'Espera a que la administradora defina el valor del regalo.'; end if;
  select jsonb_agg(jsonb_build_object('desc', trim(e->>'desc'), 'precio', e->'precio', 'link', trim(coalesce(e->>'link', ''))))
    into v from jsonb_array_elements(case when jsonb_typeof(p_regalos) = 'array' then p_regalos else '[]'::jsonb end) e;
  if not public.santa_regalos_validos(v, g.precio_min, g.precio_max) then
    raise exception 'Revisa tus 3 opciones: cada una necesita descripción y un precio entre % y %; los links deben empezar por https://.', g.precio_min, g.precio_max;
  end if;
  update public.santa_miembros set regalos = v where grupo_id = p_grupo and usuario_id = v_yo;
end $$;

create or replace function public.santa_sortear(p_grupo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo); v_ids uuid[]; n int;
begin
  if g.admin_id is distinct from v_yo then raise exception 'Solo la administradora puede hacer el sorteo.'; end if;
  if g.estado <> 'listo' then raise exception 'El sorteo no está disponible.'; end if;
  if g.fecha_reunion is null or g.fecha_reunion <= now() then raise exception 'Primero elige la fecha de la reunión (en el futuro).'; end if;
  perform 1 from public.santa_grupos where id = p_grupo for update;
  if exists (select 1 from public.santa_miembros where grupo_id = p_grupo and not public.santa_regalos_validos(regalos, g.precio_min, g.precio_max)) then
    raise exception 'Todas deben tener sus 3 opciones de regalo dentro del rango.';
  end if;
  select array_agg(usuario_id order by random()) into v_ids from public.santa_miembros where grupo_id = p_grupo;
  n := array_length(v_ids, 1);
  if n < 3 then raise exception 'Se necesitan al menos 3 personas.'; end if;
  delete from public.santa_asignaciones where grupo_id = p_grupo;
  insert into public.santa_asignaciones (grupo_id, santa_id, receptor_id)
    select p_grupo, v_ids[i], v_ids[(i % n) + 1] from generate_series(1, n) i;
  update public.santa_grupos set estado = 'sorteado' where id = p_grupo;
end $$;

-- ---------- lectura ----------
create or replace function public.santa_mis_grupos() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id, 'nombre', g.nombre, 'estado', g.estado, 'fecha_reunion', g.fecha_reunion,
      'miembros', (select count(*) from public.santa_miembros x where x.grupo_id = g.id),
      'sin_leer', (select count(*) from public.santa_mensajes s where s.grupo_id = g.id and s.receptor_id = v_yo and not s.leido),
      'accion', (g.estado = 'votacion' and m.voto is null)
             or (g.estado = 'listo' and g.admin_id = v_yo and g.fecha_reunion is null)
             or (g.estado = 'listo' and g.precio_min is not null and not public.santa_regalos_validos(m.regalos, g.precio_min, g.precio_max))
             or (g.estado = 'sorteado' and now() >= g.fecha_reunion and not m.revelar)
    ) order by g.creado_en desc)
    from public.santa_grupos g join public.santa_miembros m on m.grupo_id = g.id and m.usuario_id = v_yo
  ), '[]'::jsonb);
end $$;

create or replace function public.santa_detalle(p_grupo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
  v_yo_m public.santa_miembros; v_rec uuid; v_santa uuid; v_todos_revelan boolean; r jsonb;
begin
  select * into v_yo_m from public.santa_miembros where grupo_id = p_grupo and usuario_id = v_yo;
  select bool_and(revelar) into v_todos_revelan from public.santa_miembros where grupo_id = p_grupo;
  r := jsonb_build_object(
    'id', g.id, 'nombre', g.nombre, 'estado', g.estado, 'yo', v_yo,
    'creador_id', g.creador_id, 'admin_id', g.admin_id, 'fecha_reunion', g.fecha_reunion,
    'precio_min', g.precio_min, 'precio_max', g.precio_max, 'ahora', now(),
    'mi_voto', v_yo_m.voto, 'mis_regalos', v_yo_m.regalos, 'yo_revele', v_yo_m.revelar,
    'miembros', (select jsonb_agg(jsonb_build_object(
        'id', u.id, 'nombre', u.nombre, 'username', u.username,
        'voto', m.voto is not null, 'lista', public.santa_regalos_validos(m.regalos, g.precio_min, g.precio_max),
        'revelar', m.revelar,
        'votos', case when g.estado = 'votacion' then (select count(*) from public.santa_miembros x where x.grupo_id = p_grupo and x.voto = u.id) else null end
      ) order by m.unido_en)
      from public.santa_miembros m join public.usuarios u on u.id = m.usuario_id where m.grupo_id = p_grupo)
  );
  if g.estado = 'sorteado' then
    select receptor_id into v_rec from public.santa_asignaciones where grupo_id = p_grupo and santa_id = v_yo;
    r := r || jsonb_build_object(
      'receptor', (select jsonb_build_object('id', u.id, 'nombre', u.nombre, 'username', u.username, 'regalos', m.regalos)
                   from public.usuarios u join public.santa_miembros m on m.usuario_id = u.id and m.grupo_id = p_grupo where u.id = v_rec),
      'enviados', (select count(*) from public.santa_mensajes where grupo_id = p_grupo and santa_id = v_yo),
      'recibidos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'mensaje', mensaje, 'creado_en', creado_en, 'leido', leido) order by creado_en desc)
                   from public.santa_mensajes where grupo_id = p_grupo and receptor_id = v_yo), '[]'::jsonb)
    );
    if now() >= g.fecha_reunion and v_todos_revelan then
      select santa_id into v_santa from public.santa_asignaciones where grupo_id = p_grupo and receptor_id = v_yo;
      r := r || jsonb_build_object('mi_santa', (select jsonb_build_object('nombre', nombre, 'username', username) from public.usuarios where id = v_santa));
    end if;
  end if;
  return r;
end $$;

-- ---------- mensajitos (solo Santa -> su persona) ----------
create or replace function public.santa_enviar(p_grupo uuid, p_mensaje text) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo); v_rec uuid; v_msg text := trim(coalesce(p_mensaje, ''));
begin
  if g.estado <> 'sorteado' then raise exception 'Los mensajitos se pueden enviar después del sorteo.'; end if;
  if v_msg = '' or char_length(v_msg) > 300 then raise exception 'El mensajito debe tener entre 1 y 300 caracteres.'; end if;
  if (select count(*) from public.santa_mensajes where santa_id = v_yo and creado_en > now() - interval '1 hour') >= 20 then
    raise exception 'Enviaste muchos mensajitos; espera un rato.';
  end if;
  select receptor_id into v_rec from public.santa_asignaciones where grupo_id = p_grupo and santa_id = v_yo;
  if v_rec is null then raise exception 'No encontramos a tu persona.'; end if;
  insert into public.santa_mensajes (grupo_id, santa_id, receptor_id, mensaje) values (p_grupo, v_yo, v_rec, v_msg);
end $$;

create or replace function public.santa_mis_mensajes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'grupo_id', s.grupo_id, 'grupo', g.nombre, 'mensaje', s.mensaje, 'creado_en', s.creado_en, 'leido', s.leido) order by s.creado_en desc)
    from public.santa_mensajes s join public.santa_grupos g on g.id = s.grupo_id where s.receptor_id = v_yo), '[]'::jsonb);
end $$;

create or replace function public.santa_marcar_leidos(p_grupo uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo();
begin
  update public.santa_mensajes set leido = true where receptor_id = v_yo and not leido and (p_grupo is null or grupo_id = p_grupo);
end $$;

create or replace function public.santa_revelar(p_grupo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
begin
  if g.estado <> 'sorteado' or now() < g.fecha_reunion then raise exception 'Todavía no llega el día de la reunión.'; end if;
  update public.santa_miembros set revelar = true where grupo_id = p_grupo and usuario_id = v_yo;
end $$;

-- Permisos: solo usuarios con sesión ejecutan las funciones públicas; las internas no se exponen.
do $$
declare f text;
begin
  foreach f in array array[
    'santa_yo()', 'santa_grupo_de(uuid, uuid)', 'santa_regalos_validos(jsonb, integer, integer)',
    'santa_crear(text)', 'santa_agregar(uuid, uuid)', 'santa_salir(uuid)', 'santa_quitar(uuid, uuid)', 'santa_eliminar(uuid)',
    'santa_cerrar(uuid)', 'santa_reabrir(uuid)', 'santa_votar(uuid, uuid)', 'santa_configurar(uuid, timestamptz, integer, integer)',
    'santa_guardar_regalos(uuid, jsonb)', 'santa_sortear(uuid)', 'santa_mis_grupos()', 'santa_detalle(uuid)',
    'santa_enviar(uuid, text)', 'santa_mis_mensajes()', 'santa_marcar_leidos(uuid)', 'santa_revelar(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'santa_crear(text)', 'santa_agregar(uuid, uuid)', 'santa_salir(uuid)', 'santa_quitar(uuid, uuid)', 'santa_eliminar(uuid)',
    'santa_cerrar(uuid)', 'santa_reabrir(uuid)', 'santa_votar(uuid, uuid)', 'santa_configurar(uuid, timestamptz, integer, integer)',
    'santa_guardar_regalos(uuid, jsonb)', 'santa_sortear(uuid)', 'santa_mis_grupos()', 'santa_detalle(uuid)',
    'santa_enviar(uuid, text)', 'santa_mis_mensajes()', 'santa_marcar_leidos(uuid)', 'santa_revelar(uuid)'
  ] loop
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
