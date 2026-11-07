-- Vista docente de turnos: quién reservó cada turno (solo para docentes).
-- Los estudiantes siguen viendo únicamente sus propias reservas y los cupos sin datos personales.
create function public.turnos_docente(p_desde date, p_hasta date)
returns table (reserva_id bigint, fecha date, turno_id int, practica_id text, area_id text,
               estado text, nombre text, dni text, celular text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 62 then
    raise exception 'Rango de fechas inválido';
  end if;
  return query
    select r.id, r.fecha, r.turno_id, r.practica_id, r.area_id, r.estado, p.nombre, p.dni, p.celular
      from public.reservas r
      join public.perfiles p on p.id = r.user_id
     where r.fecha between p_desde and p_hasta
       and r.estado in ('reservado', 'confirmado', 'espera')
     order by r.fecha, r.turno_id, r.estado, p.nombre;
end $$;

revoke all on function public.turnos_docente(date, date) from public, anon;
grant execute on function public.turnos_docente(date, date) to authenticated;
