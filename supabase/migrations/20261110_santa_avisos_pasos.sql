-- Santa Secreto: avisos en cada paso (para el/la administrador(a) y para las personas), con botón directo,
-- lenguaje neutro ("el/la administrador(a)") y lista de deseos con mínimo 1 opción (hasta 3).

alter table public.santa_avisos add column if not exists accion text;

drop function if exists public.santa_avisar(uuid, text, uuid);
create or replace function public.santa_avisar(p_grupo uuid, p_texto text, p_excepto uuid default null, p_accion text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.santa_avisos (grupo_id, usuario_id, texto, accion)
    select p_grupo, usuario_id, p_texto, p_accion from public.santa_miembros
    where grupo_id = p_grupo and (p_excepto is null or usuario_id <> p_excepto);
end $$;
revoke all on function public.santa_avisar(uuid, text, uuid, text) from public, anon, authenticated;

create or replace function public.santa_avisar_a(p_grupo uuid, p_usuario uuid, p_texto text, p_accion text default null) returns void
language sql security definer set search_path = public as $$
  insert into public.santa_avisos (grupo_id, usuario_id, texto, accion) values (p_grupo, p_usuario, p_texto, p_accion);
$$;
revoke all on function public.santa_avisar_a(uuid, uuid, text, text) from public, anon, authenticated;

-- Lista de deseos: de 1 a 3 opciones, cada una con descripción y precio dentro del rango
create or replace function public.santa_regalos_validos(p jsonb, p_min integer, p_max integer) returns boolean
language plpgsql immutable set search_path = public as $$
declare r jsonb; v_precio numeric;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) not between 1 and 3 or p_min is null or p_max is null then return false; end if;
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

create or replace function public.santa_listas_completas(p_grupo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.santa_miembros m join public.santa_grupos g on g.id = m.grupo_id
                     where m.grupo_id = p_grupo and not public.santa_regalos_validos(m.regalos, g.precio_min, g.precio_max));
$$;
revoke all on function public.santa_listas_completas(uuid) from public, anon, authenticated;

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
  perform public.santa_avisar_a(p_grupo, p_usuario, (select nombre from public.usuarios where id = v_yo) || ' te agregó al Santa Secreto «' || g.nombre || '». ¡Entra a conocer el juego! 🎁');
  if g.creador_id <> v_yo then
    perform public.santa_avisar_a(p_grupo, g.creador_id, (select nombre from public.usuarios where id = v_yo) || ' agregó a ' || (select nombre from public.usuarios where id = p_usuario) || ' al grupo.');
  end if;
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
  perform public.santa_avisar(p_grupo, '🗳️ El grupo se cerró: ya puedes votar por quién será el/la administrador(a) del juego.', null, 'votar');
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
  perform public.santa_avisar(p_grupo, '🔓 El grupo se reabrió para sumar a más personas; la votación del/la administrador(a) empezará de nuevo.');
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
    perform public.santa_avisar(p_grupo, '👑 ¡Terminó la votación! El/la administrador(a) es ' || (select nombre from public.usuarios where id = v_admin)
      || '. Elegirá la fecha de la reunión y el valor del regalo; te avisaremos para que llenes tu lista de deseos.', v_admin);
    perform public.santa_avisar_a(p_grupo, v_admin, '👑 ¡Te eligieron administrador(a)! Elige el día de la reunión y el valor del regalo.', 'configurar');
  end if;
end $$;

create or replace function public.santa_configurar(p_grupo uuid, p_fecha timestamptz, p_min integer, p_max integer) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo); v_rango text;
begin
  if g.admin_id is distinct from v_yo or g.estado not in ('listo','sorteado') then raise exception 'Solo el/la administrador(a) puede hacer esto.'; end if;
  if p_fecha is null or p_fecha <= now() then raise exception 'Elige una fecha y hora en el futuro.'; end if;
  if g.estado = 'sorteado' then
    if now() >= g.fecha_reunion then raise exception 'La reunión ya pasó.'; end if;
    update public.santa_grupos set fecha_reunion = p_fecha where id = p_grupo;
  else
    if p_min is null or p_max is null or p_min < 0 or p_max > 1000000 or p_min > p_max then raise exception 'El rango de valor no es válido.'; end if;
    update public.santa_grupos set fecha_reunion = p_fecha, precio_min = p_min, precio_max = p_max where id = p_grupo;
    if g.precio_min is distinct from p_min or g.precio_max is distinct from p_max then
      v_rango := public.santa_pesos(p_min) || ' y ' || public.santa_pesos(p_max);
      perform public.santa_avisar(p_grupo, '💰 ' || (case when g.precio_min is null then 'El regalo será' else 'El valor del regalo cambió: ahora será' end)
        || ' entre ' || v_rango || '. ¡Llena tu lista de deseos (mínimo 1 opción)!', v_yo, 'lista');
      perform public.santa_avisar_a(p_grupo, v_yo, '💰 Guardaste el valor del regalo: entre ' || v_rango
        || '. Ya le avisamos a todos para que llenen su lista; no olvides llenar la tuya. Te avisaremos cuando todas las listas estén completas.', 'lista');
    end if;
  end if;
  if date_trunc('minute', g.fecha_reunion) is distinct from date_trunc('minute', p_fecha) then
    perform public.santa_avisar(p_grupo, '📅 ' || (case when g.fecha_reunion is null then 'La reunión será el ' else 'La fecha de la reunión cambió: ahora será el ' end)
      || public.santa_fecha_txt(p_fecha));
  end if;
end $$;

create or replace function public.santa_guardar_regalos(p_grupo uuid, p_regalos jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo); v jsonb;
  v_antes boolean; v_todas_antes boolean; v_listas int; v_total int;
begin
  if g.estado <> 'listo' then raise exception 'Ahora no se puede cambiar la lista de deseos.'; end if;
  if g.precio_min is null then raise exception 'Espera a que el/la administrador(a) defina el valor del regalo.'; end if;
  perform 1 from public.santa_grupos where id = p_grupo for update;
  -- Se ignoran las opciones vacías (son opcionales)
  select jsonb_agg(jsonb_build_object('desc', trim(e->>'desc'), 'precio', e->'precio', 'link', trim(coalesce(e->>'link', ''))))
    into v from jsonb_array_elements(case when jsonb_typeof(p_regalos) = 'array' then p_regalos else '[]'::jsonb end) e
    where trim(coalesce(e->>'desc', '')) <> '' or coalesce(e->>'precio', '') <> '' or trim(coalesce(e->>'link', '')) <> '';
  if not public.santa_regalos_validos(v, g.precio_min, g.precio_max) then
    raise exception 'Revisa tu lista: escribe mínimo 1 opción (máximo 3), cada una con descripción y un precio entre % y %; los links deben empezar por https://.',
      public.santa_pesos(g.precio_min), public.santa_pesos(g.precio_max);
  end if;
  select public.santa_regalos_validos(regalos, g.precio_min, g.precio_max) into v_antes from public.santa_miembros where grupo_id = p_grupo and usuario_id = v_yo;
  v_todas_antes := public.santa_listas_completas(p_grupo);
  update public.santa_miembros set regalos = v where grupo_id = p_grupo and usuario_id = v_yo;
  if not v_antes and g.admin_id is not null and g.admin_id <> v_yo then
    select count(*) filter (where public.santa_regalos_validos(regalos, g.precio_min, g.precio_max)), count(*) into v_listas, v_total
      from public.santa_miembros where grupo_id = p_grupo;
    perform public.santa_avisar_a(p_grupo, g.admin_id, '📝 ' || (select nombre from public.usuarios where id = v_yo) || ' completó su lista de deseos (' || v_listas || ' de ' || v_total || ').');
  end if;
  if not v_todas_antes and public.santa_listas_completas(p_grupo) then
    perform public.santa_avisar(p_grupo, '✅ ¡Todas las listas de deseos están completas! El/la administrador(a) ya puede hacer el sorteo.', g.admin_id);
    perform public.santa_avisar_a(p_grupo, g.admin_id, '✅ ¡Todas las listas de deseos están completas! Ya puedes hacer el sorteo 🎲', 'sorteo');
  end if;
end $$;

create or replace function public.santa_sortear(p_grupo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo); v_ids uuid[]; n int;
begin
  if g.admin_id is distinct from v_yo then raise exception 'Solo el/la administrador(a) puede hacer el sorteo.'; end if;
  if g.estado <> 'listo' then raise exception 'El sorteo no está disponible.'; end if;
  if g.fecha_reunion is null or g.fecha_reunion <= now() then raise exception 'Primero elige la fecha de la reunión (en el futuro).'; end if;
  perform 1 from public.santa_grupos where id = p_grupo for update;
  if not public.santa_listas_completas(p_grupo) then
    raise exception 'Todos deben tener su lista de deseos (mínimo 1 opción dentro del rango).';
  end if;
  select array_agg(usuario_id order by random()) into v_ids from public.santa_miembros where grupo_id = p_grupo;
  n := array_length(v_ids, 1);
  if n < 3 then raise exception 'Se necesitan al menos 3 personas.'; end if;
  delete from public.santa_asignaciones where grupo_id = p_grupo;
  insert into public.santa_asignaciones (grupo_id, santa_id, receptor_id)
    select p_grupo, v_ids[i], v_ids[(i % n) + 1] from generate_series(1, n) i;
  update public.santa_grupos set estado = 'sorteado' where id = p_grupo;
  perform public.santa_avisar(p_grupo, '🎲 ¡Ya se hizo el sorteo! Entra a ver a quién le regalas y su lista de deseos.');
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
    perform public.santa_avisar(p_grupo, '✨ ¡Ya todos y todas presionaron «Revelar»! Entra a ver quién era tu Santa Secreto.');
  end if;
end $$;

create or replace function public.santa_mis_avisos() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); v_g uuid;
begin
  for v_g in
    update public.santa_grupos set aviso_dia = true
    where estado = 'sorteado' and not aviso_dia and fecha_reunion <= now()
      and id in (select grupo_id from public.santa_miembros where usuario_id = v_yo)
    returning id
  loop
    perform public.santa_avisar(v_g, '🎉 ¡Llegó el día de la reunión! Presiona «Revelar»: cuando todos y todas lo hagan se descubre quién era el Santa Secreto de cada persona.', null, 'revelar');
  end loop;
  return coalesce((select jsonb_agg(x order by x->>'creado_en' desc) from (
    select jsonb_build_object('id', a.id, 'grupo_id', a.grupo_id, 'grupo', g.nombre, 'texto', a.texto, 'accion', a.accion, 'creado_en', a.creado_en, 'leido', a.leido) x
    from public.santa_avisos a join public.santa_grupos g on g.id = a.grupo_id
    where a.usuario_id = v_yo order by a.creado_en desc limit 50) t), '[]'::jsonb);
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
    'avisos', coalesce((select jsonb_agg(jsonb_build_object('texto', texto, 'accion', accion, 'creado_en', creado_en, 'leido', leido) order by creado_en desc)
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
