-- =====================================================================
-- Horarios habilitados por día de la semana (los define el equipo docente)
-- dia = 0 domingo, 1 lunes ... 6 sábado. Un turno deshabilitado no admite reservas
-- nuevas ni lista de espera; las reservas que ya existen se mantienen.
-- =====================================================================

create table public.turnos_semana (
  dia int not null check (dia between 0 and 6),
  turno_id int not null references public.turnos(id) on delete cascade,
  habilitado boolean not null default true,
  primary key (dia, turno_id)
);

-- Punto de partida = las reglas que ya tenía la turnera:
-- lunes a viernes todos los turnos, sábado solo mañana y tarde, domingo cerrado.
insert into public.turnos_semana (dia, turno_id, habilitado)
select d, t.id, case when d = 0 then false when d = 6 and t.id >= 4 then false else true end
from generate_series(0, 6) d cross join public.turnos t;

alter table public.turnos_semana enable row level security;
create policy "horarios: lectura" on public.turnos_semana for select to anon, authenticated using (true);
revoke insert, update, delete on public.turnos_semana from anon, authenticated;

create function public.turno_habilitado(p_fecha date, p_turno int)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select habilitado from public.turnos_semana
                    where dia = extract(dow from p_fecha)::int and turno_id = p_turno), false)
$$;

-- Solo docentes: habilitar o deshabilitar un turno (o todos los turnos de un día si p_turno es null)
create function public.configurar_turno_semana(p_dia int, p_turno int default null, p_habilitado boolean default true)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  if p_dia is null or p_dia not between 0 and 6 then raise exception 'Día inválido'; end if;
  update public.turnos_semana set habilitado = coalesce(p_habilitado, true)
   where dia = p_dia and (p_turno is null or turno_id = p_turno);
  if not found then raise exception 'Turno inexistente'; end if;
end $$;

-- Solo docentes: reservas futuras que quedaron en turnos deshabilitados (para avisarles / ver en el panel)
create function public.reservas_en_horarios_deshabilitados()
returns table(fecha date, turno_id int, ocupados int, en_espera int)
language sql stable security definer set search_path to 'public' as $$
  select r.fecha, r.turno_id,
         (count(*) filter (where r.estado in ('reservado','confirmado')))::int,
         (count(*) filter (where r.estado = 'espera'))::int
    from public.reservas r
   where public.es_docente()
     and r.estado in ('reservado','confirmado','espera')
     and not public.turno_habilitado(r.fecha, r.turno_id)
     and public.inicio_turno(r.fecha, r.turno_id) > now()
   group by r.fecha, r.turno_id
   order by r.fecha, r.turno_id
$$;

revoke all on function public.configurar_turno_semana(int,int,boolean) from public, anon;
revoke all on function public.reservas_en_horarios_deshabilitados() from public, anon;
grant execute on function public.configurar_turno_semana(int,int,boolean) to authenticated;
grant execute on function public.reservas_en_horarios_deshabilitados() to authenticated;

-- Reservar: en vez de las reglas fijas (sin domingos, sin sábados de noche) usa la tabla de horarios.
-- (Mantiene todo lo demás: mínimo 1 h de anticipación, cupo 12, una práctica por turno, máx. 2 activos, suspensión.)
create or replace function public.reservar_turno(p_fecha date, p_turno integer, p_practica text, p_area text)
returns text
language plpgsql security definer set search_path to 'public' as $function$
declare
  uid uuid := auth.uid();
  cupo constant int := 12;
  v_turno public.turnos%rowtype;
  v_inicio timestamptz;
  v_otra text;
  v_ocupados int;
  v_estado text;
  v_hasta timestamptz;
begin
  if uid is null then raise exception 'Tenés que ingresar para reservar'; end if;
  if not exists (select 1 from perfiles where id = uid) then
    raise exception 'Falta completar tu perfil';
  end if;
  select * into v_turno from turnos where id = p_turno;
  if not found then raise exception 'Turno inexistente'; end if;
  if not public.turno_habilitado(p_fecha, p_turno) then
    raise exception 'Ese horario no está habilitado: no se dictan prácticas ese día y turno';
  end if;
  v_inicio := (p_fecha + make_time(v_turno.hora_ini, 0, 0)) at time zone 'America/Argentina/Buenos_Aires';
  if v_inicio <= now() then raise exception 'Ese turno ya empezó o pasó'; end if;
  if v_inicio < now() + interval '1 hour' then
    raise exception 'Ya no se puede reservar este turno: falta menos de 1 hora y la asistencia se confirma desde el correo';
  end if;
  if not exists (select 1 from practica_areas where practica_id = p_practica and area_id = p_area) then
    raise exception 'Esa práctica no corresponde a tu área';
  end if;
  if not exists (select 1 from practicas where id = p_practica and activa) then
    raise exception 'Esa práctica no está disponible por ahora';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_fecha::text || '-' || p_turno::text));
  if (select count(*) from reservas
      where user_id = uid and estado = 'liberado' and updated_at > now() - interval '7 days') >= 2 then
    raise exception 'Reservas suspendidas por una semana (2 turnos sin confirmar)';
  end if;
  if (select count(*) from reservas
      where user_id = uid and estado in ('reservado','confirmado')
        and ((fecha + make_time((select hora_ini from turnos t where t.id = turno_id),0,0))
             at time zone 'America/Argentina/Buenos_Aires') > now()) >= 2 then
    raise exception 'Ya tenés 2 turnos activos (el máximo)';
  end if;
  select practica_id into v_otra from reservas
   where fecha = p_fecha and turno_id = p_turno and estado in ('reservado','confirmado') limit 1;
  if v_otra is not null and v_otra <> p_practica then
    raise exception 'Ese turno ya está ocupado por otra práctica';
  end if;
  select count(*) into v_ocupados from reservas
   where fecha = p_fecha and turno_id = p_turno and estado in ('reservado','confirmado');
  if v_ocupados >= cupo then
    v_estado := 'espera';
  else
    v_estado := 'reservado';
    v_hasta := plazo_confirmacion(p_fecha, p_turno);
    if v_hasta < now() + interval '1 hour' then v_hasta := v_inicio; end if;
  end if;
  begin
    insert into reservas (user_id, fecha, turno_id, practica_id, area_id, estado, confirmar_hasta)
    values (uid, p_fecha, p_turno, p_practica, p_area, v_estado, v_hasta);
  exception when unique_violation then
    raise exception 'Ya tenés un lugar en ese turno';
  end;
  return v_estado;
end $function$;

-- Lista de espera: en un turno deshabilitado no se ofrece el lugar a nadie
create or replace function public.promover_espera(p_fecha date, p_turno integer)
returns integer
language plpgsql security definer set search_path to 'public' as $function$
declare
  cupo constant int := 12;
  v_inicio timestamptz := inicio_turno(p_fecha, p_turno);
  v_ocup int; v_prac text; r reservas%rowtype; n int := 0;
begin
  if v_inicio <= now() then return 0; end if;
  if not public.turno_habilitado(p_fecha, p_turno) then return 0; end if;
  perform pg_advisory_xact_lock(hashtext(p_fecha::text || '-' || p_turno::text));
  loop
    select count(*), min(practica_id) into v_ocup, v_prac from reservas
     where fecha = p_fecha and turno_id = p_turno and estado in ('reservado','confirmado');
    exit when v_ocup >= cupo;
    select e.* into r from reservas e
     where e.fecha = p_fecha and e.turno_id = p_turno and e.estado = 'espera'
       and (v_prac is null or e.practica_id = v_prac)
       and (select count(*) from reservas a
             where a.user_id = e.user_id and a.estado in ('reservado','confirmado')
               and inicio_turno(a.fecha, a.turno_id) > now()) < 2
     order by e.created_at, e.id limit 1;
    exit when not found;
    if v_inicio - interval '24 hours' > now() then
      update reservas set estado = 'reservado', confirmar_hasta = plazo_confirmacion(p_fecha, p_turno),
             recordatorio_at = null, token_confirmacion = null, updated_at = now() where id = r.id;
    else
      update reservas set estado = 'reservado', confirmar_hasta = least(now() + interval '5 hours', v_inicio),
             recordatorio_at = now(), token_confirmacion = gen_random_uuid(), updated_at = now() where id = r.id;
    end if;
    insert into avisos (reserva_id, user_id, tipo) values (r.id, r.user_id, 'lugar_ofrecido');
    n := n + 1;
  end loop;
  return n;
end $function$;
