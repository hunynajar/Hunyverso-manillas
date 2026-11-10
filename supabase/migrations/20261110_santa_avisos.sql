-- Avisos del Santa Secreto: se crean en la base de datos cuando pasa algo en el grupo
-- y se muestran en el Chat y dentro del grupo. Sin acceso directo desde el navegador.

create table if not exists public.santa_avisos (
  id bigint generated always as identity primary key,
  grupo_id uuid not null references public.santa_grupos(id) on delete cascade,
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  texto text not null,
  leido boolean not null default false,
  creado_en timestamptz not null default now()
);
create index if not exists santa_avisos_usuario on public.santa_avisos(usuario_id, leido);
create index if not exists santa_avisos_grupo on public.santa_avisos(grupo_id);
alter table public.santa_avisos enable row level security;
revoke all on public.santa_avisos from anon, authenticated;

alter table public.santa_grupos add column if not exists aviso_dia boolean not null default false;

-- ---------- utilidades internas ----------
create or replace function public.santa_fecha_txt(p timestamptz) returns text
language plpgsql immutable set search_path = public as $$
declare
  l timestamp := p at time zone 'America/Bogota';
  dias text[] := array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'];
  meses text[] := array['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
  h int := extract(hour from l)::int;
begin
  return dias[extract(dow from l)::int + 1] || ' ' || extract(day from l)::int || ' de ' || meses[extract(month from l)::int]
    || ', ' || (case when h % 12 = 0 then 12 else h % 12 end) || ':' || to_char(l, 'MI') || (case when h < 12 then ' a. m.' else ' p. m.' end);
end $$;

create or replace function public.santa_pesos(p integer) returns text
language sql immutable set search_path = public as $$
  select '$' || replace(to_char(p, 'FM9,999,999'), ',', '.')
$$;

create or replace function public.santa_avisar(p_grupo uuid, p_texto text, p_excepto uuid default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.santa_avisos (grupo_id, usuario_id, texto)
    select p_grupo, usuario_id, p_texto from public.santa_miembros
    where grupo_id = p_grupo and (p_excepto is null or usuario_id <> p_excepto);
end $$;

-- ---------- funciones que ahora avisan ----------
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
  insert into public.santa_avisos (grupo_id, usuario_id, texto)
    values (p_grupo, p_usuario, (select nombre from public.usuarios where id = v_yo) || ' te agregó al Santa Secreto «' || g.nombre || '». ¡Entra a conocer el juego! 🎁');
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
  perform public.santa_avisar(p_grupo, '🗳️ El grupo se cerró: ya pueden votar por la administradora del juego.');
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
  perform public.santa_avisar(p_grupo, '🔓 El grupo se reabrió para sumar a más personas; la votación empezará de nuevo.', v_yo);
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
    perform public.santa_avisar(p_grupo, '👑 ¡Terminó la votación! La administradora es ' || (select nombre from public.usuarios where id = v_admin) || '. Ella elegirá la fecha de la reunión y el valor del regalo.', v_admin);
    insert into public.santa_avisos (grupo_id, usuario_id, texto)
      values (p_grupo, v_admin, '👑 ¡Te eligieron administradora! Entra a elegir el día de la reunión y el valor del regalo.');
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
  else
    if p_min is null or p_max is null or p_min < 0 or p_max > 1000000 or p_min > p_max then raise exception 'El rango de valor no es válido.'; end if;
    update public.santa_grupos set fecha_reunion = p_fecha, precio_min = p_min, precio_max = p_max where id = p_grupo;
    if g.precio_min is distinct from p_min or g.precio_max is distinct from p_max then
      perform public.santa_avisar(p_grupo, '💰 ' || (case when g.precio_min is null then 'El regalo será' else 'El valor del regalo cambió: ahora será' end)
        || ' entre ' || public.santa_pesos(p_min) || ' y ' || public.santa_pesos(p_max) || '. ¡Escribe o revisa tus 3 opciones!', v_yo);
    end if;
  end if;
  if date_trunc('minute', g.fecha_reunion) is distinct from date_trunc('minute', p_fecha) then
    perform public.santa_avisar(p_grupo, '📅 ' || (case when g.fecha_reunion is null then 'La reunión será el ' else 'La fecha de la reunión cambió: ahora será el ' end)
      || public.santa_fecha_txt(p_fecha), v_yo);
  end if;
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
  perform public.santa_avisar(p_grupo, '🎲 ¡Ya se hizo el sorteo! Entra a ver a quién le regalas y su lista de regalos.');
end $$;

create or replace function public.santa_revelar(p_grupo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo);
begin
  if g.estado <> 'sorteado' or now() < g.fecha_reunion then raise exception 'Todavía no llega el día de la reunión.'; end if;
  perform 1 from public.santa_grupos where id = p_grupo for update;
  if exists (select 1 from public.santa_miembros where grupo_id = p_grupo and usuario_id = v_yo and revelar) then return; end if;
  update public.santa_miembros set revelar = true where grupo_id = p_grupo and usuario_id = v_yo;
  if not exists (select 1 from public.santa_miembros where grupo_id = p_grupo and not revelar) then
    perform public.santa_avisar(p_grupo, '✨ ¡Ya todas presionaron «Revelar»! Entra a ver quién era tu Santa Secreto.');
  end if;
end $$;

-- ---------- lectura ----------
create or replace function public.santa_mis_avisos() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); v_g uuid;
begin
  -- Aviso de "llegó el día", una sola vez por grupo
  for v_g in
    update public.santa_grupos set aviso_dia = true
    where estado = 'sorteado' and not aviso_dia and fecha_reunion <= now()
      and id in (select grupo_id from public.santa_miembros where usuario_id = v_yo)
    returning id
  loop
    perform public.santa_avisar(v_g, '🎉 ¡Llegó el día de la reunión! Cuando todas presionen «Revelar» se descubre quién era el Santa Secreto de cada una.');
  end loop;
  return coalesce((select jsonb_agg(x order by x->>'creado_en' desc) from (
    select jsonb_build_object('id', a.id, 'grupo_id', a.grupo_id, 'grupo', g.nombre, 'texto', a.texto, 'creado_en', a.creado_en, 'leido', a.leido) x
    from public.santa_avisos a join public.santa_grupos g on g.id = a.grupo_id
    where a.usuario_id = v_yo order by a.creado_en desc limit 50) t), '[]'::jsonb);
end $$;

create or replace function public.santa_marcar_leidos(p_grupo uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo();
begin
  update public.santa_mensajes set leido = true where receptor_id = v_yo and not leido and (p_grupo is null or grupo_id = p_grupo);
  update public.santa_avisos set leido = true where usuario_id = v_yo and not leido and (p_grupo is null or grupo_id = p_grupo);
end $$;

create or replace function public.santa_mis_grupos() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id, 'nombre', g.nombre, 'estado', g.estado, 'fecha_reunion', g.fecha_reunion,
      'miembros', (select count(*) from public.santa_miembros x where x.grupo_id = g.id),
      'sin_leer', (select count(*) from public.santa_mensajes s where s.grupo_id = g.id and s.receptor_id = v_yo and not s.leido)
                + (select count(*) from public.santa_avisos a where a.grupo_id = g.id and a.usuario_id = v_yo and not a.leido),
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
    'avisos', coalesce((select jsonb_agg(jsonb_build_object('texto', texto, 'creado_en', creado_en, 'leido', leido) order by creado_en desc)
                from (select * from public.santa_avisos where grupo_id = p_grupo and usuario_id = v_yo order by creado_en desc limit 5) a), '[]'::jsonb),
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

revoke all on function public.santa_fecha_txt(timestamptz) from public, anon, authenticated;
revoke all on function public.santa_pesos(integer) from public, anon, authenticated;
revoke all on function public.santa_avisar(uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.santa_mis_avisos() from public, anon;
grant execute on function public.santa_mis_avisos() to authenticated;
