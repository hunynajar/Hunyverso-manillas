-- Los mensajitos del Santa Secreto se pueden enviar solo hasta la fecha y hora de la reunión.
create or replace function public.santa_enviar(p_grupo uuid, p_mensaje text) returns void
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.santa_yo(); g public.santa_grupos := public.santa_grupo_de(p_grupo, v_yo); v_rec uuid; v_msg text := trim(coalesce(p_mensaje, ''));
begin
  if g.estado <> 'sorteado' then raise exception 'Los mensajitos se pueden enviar después del sorteo.'; end if;
  if now() >= g.fecha_reunion then raise exception 'Ya llegó el día de la reunión: los mensajitos se cerraron.'; end if;
  if v_msg = '' or char_length(v_msg) > 300 then raise exception 'El mensajito debe tener entre 1 y 300 caracteres.'; end if;
  if (select count(*) from public.santa_mensajes where santa_id = v_yo and creado_en > now() - interval '1 hour') >= 20 then
    raise exception 'Enviaste muchos mensajitos; espera un rato.';
  end if;
  select receptor_id into v_rec from public.santa_asignaciones where grupo_id = p_grupo and santa_id = v_yo;
  if v_rec is null then raise exception 'No encontramos a tu persona.'; end if;
  insert into public.santa_mensajes (grupo_id, santa_id, receptor_id, mensaje) values (p_grupo, v_yo, v_rec, v_msg);
end $$;
