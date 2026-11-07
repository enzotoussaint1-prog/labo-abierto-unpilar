-- =====================================================================
-- Panel docente: rol, prácticas y reglas editables, respuestas del foro
-- Todas las escrituras pasan por funciones que verifican es_docente().
-- Para dar acceso a la primera persona docente (una sola vez, desde el SQL Editor):
--   insert into public.docentes (user_id) select id from auth.users where email = 'correo@docente.edu.ar';
-- Después, desde el panel, cualquier docente puede agregar a otras personas por correo.
-- =====================================================================

-- 1. Rol docente
create table public.docentes (
  user_id uuid primary key references public.perfiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.docentes enable row level security;
create policy "docentes: ver si soy docente" on public.docentes
  for select to authenticated using (user_id = auth.uid());

create function public.es_docente() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.docentes where user_id = auth.uid());
$$;
revoke all on function public.es_docente() from public, anon;
grant execute on function public.es_docente() to authenticated;

-- 2. Prácticas: se ocultan en lugar de borrarse (las reservas viejas las siguen necesitando)
alter table public.practicas add column activa boolean not null default true;

-- 3. Reglas de uso editables (texto con **negrita**)
create table public.reglas_uso (
  id bigint generated always as identity primary key,
  orden int not null default 0,
  texto text not null check (length(texto) between 3 and 600)
);
alter table public.reglas_uso enable row level security;
create policy "reglas: lectura pública" on public.reglas_uso for select using (true);

insert into public.reglas_uso (orden, texto) values
 (1, 'Cada jornada tiene **dos turnos de 2 horas**: mañana 8–10 y 10–12 · tarde 13–15 y 15–17 · noche 18–20 y 20–22. Los sábados, solo mañana y tarde.'),
 (2, 'El laboratorio es un espacio único y chico: **en cada turno se hace una sola práctica**. La primera reserva define la práctica del turno; después, solo pueden sumarse quienes hagan esa misma práctica.'),
 (3, 'El cupo es de **12 personas por turno** y se descuenta por día y turno, sin importar la carrera.'),
 (4, '**La reserva es individual:** cada estudiante ingresa con sus datos (DNI, correo y celular) y toma su propio turno. No hay reservas grupales ni a nombre de otra persona.'),
 (5, 'Se reserva como en unpilarapp: **Laboratorio → Área (carrera) → Práctica → Fecha y horario → Confirmación**.'),
 (6, 'Máximo 2 turnos activos por persona. Dos turnos sin confirmar o sin asistir suspenden las reservas por una semana.');

-- 4. El foro: los docentes ven todas las preguntas (las respuestas se escriben con responder_hilo)
create policy "foro: docentes leen todo" on public.foro_hilos
  for select to authenticated using (public.es_docente());

-- 5. Funciones del panel
create function public.guardar_practica(
  p_id text, p_nombre text, p_equipo text, p_epp text,
  p_precauciones text[], p_areas text[], p_activa boolean
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(trim(coalesce(p_id,'')), '');
  v_nom text := trim(coalesce(p_nombre,''));
  v_prec text[];
  v_base text;
  v_n int := 1;
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  if length(v_nom) < 3 or length(v_nom) > 80 then
    raise exception 'El nombre de la práctica debe tener entre 3 y 80 caracteres';
  end if;
  if length(coalesce(p_equipo,'')) > 300 or length(coalesce(p_epp,'')) > 300 then
    raise exception 'Equipamiento y protección: máximo 300 caracteres cada uno';
  end if;
  select coalesce(array_agg(left(trim(x), 200)), '{}') into v_prec
    from unnest(coalesce(p_precauciones, '{}'::text[])) x where trim(x) <> '';
  if coalesce(array_length(v_prec, 1), 0) > 20 then raise exception 'Máximo 20 precauciones'; end if;
  if p_areas is null or coalesce(array_length(p_areas, 1), 0) = 0 then
    raise exception 'Elegí al menos un área para la práctica';
  end if;
  if exists (select 1 from unnest(p_areas) a where not exists (select 1 from public.areas where id = a)) then
    raise exception 'Hay un área que no existe';
  end if;

  if v_id is null then
    v_base := trim(both '-' from regexp_replace(
      lower(translate(v_nom, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', '-', 'g'));
    if v_base = '' then v_base := 'practica'; end if;
    v_base := left(v_base, 40);
    v_id := v_base;
    while exists (select 1 from public.practicas where id = v_id) loop
      v_n := v_n + 1; v_id := v_base || '-' || v_n;
    end loop;
    insert into public.practicas (id, nombre, equipo, epp, precauciones, activa)
    values (v_id, v_nom, trim(coalesce(p_equipo,'')), trim(coalesce(p_epp,'')), v_prec, coalesce(p_activa, true));
  else
    update public.practicas
       set nombre = v_nom, equipo = trim(coalesce(p_equipo,'')), epp = trim(coalesce(p_epp,'')),
           precauciones = v_prec, activa = coalesce(p_activa, true)
     where id = v_id;
    if not found then raise exception 'La práctica no existe'; end if;
  end if;

  delete from public.practica_areas where practica_id = v_id;
  insert into public.practica_areas (practica_id, area_id)
    select distinct v_id, a from unnest(p_areas) a;
  return v_id;
end $$;

create function public.guardar_regla(p_id bigint, p_texto text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_t text := trim(coalesce(p_texto,'')); v_id bigint;
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  if length(v_t) < 3 or length(v_t) > 600 then raise exception 'La regla debe tener entre 3 y 600 caracteres'; end if;
  if p_id is null then
    insert into public.reglas_uso (orden, texto)
    values ((select coalesce(max(orden), 0) + 1 from public.reglas_uso), v_t) returning id into v_id;
  else
    update public.reglas_uso set texto = v_t where id = p_id;
    if not found then raise exception 'La regla no existe'; end if;
    v_id := p_id;
  end if;
  return v_id;
end $$;

create function public.eliminar_regla(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  delete from public.reglas_uso where id = p_id;
end $$;

create function public.mover_regla(p_id bigint, p_dir int) returns void
language plpgsql security definer set search_path = public as $$
declare a public.reglas_uso%rowtype; b public.reglas_uso%rowtype;
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  select * into a from public.reglas_uso where id = p_id;
  if not found then raise exception 'La regla no existe'; end if;
  if p_dir < 0 then
    select * into b from public.reglas_uso where (orden, id) < (a.orden, a.id) order by orden desc, id desc limit 1;
  else
    select * into b from public.reglas_uso where (orden, id) > (a.orden, a.id) order by orden, id limit 1;
  end if;
  if not found then return; end if;
  update public.reglas_uso set orden = case when id = a.id then b.orden else a.orden end
   where id in (a.id, b.id);
end $$;

create function public.responder_hilo(p_id bigint, p_respuesta text) returns void
language plpgsql security definer set search_path = public as $$
declare v_r text := trim(coalesce(p_respuesta,'')); v_quien text;
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  if v_r <> '' and length(v_r) < 2 then raise exception 'La respuesta es demasiado corta'; end if;
  if length(v_r) > 2000 then raise exception 'La respuesta es demasiado larga (máximo 2000 caracteres)'; end if;
  select coalesce(nullif(trim(nombre), ''), 'Equipo docente') into v_quien from public.perfiles where id = auth.uid();
  update public.foro_hilos
     set respuesta = nullif(v_r, ''),
         respondido_por = case when v_r = '' then null else v_quien || ' (docente)' end
   where id = p_id;
  if not found then raise exception 'La pregunta no existe'; end if;
end $$;

create function public.listar_docentes() returns table (docente_id uuid, nombre text, email text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  return query
    select d.user_id, p.nombre, u.email::text
      from public.docentes d
      join public.perfiles p on p.id = d.user_id
      join auth.users u on u.id = d.user_id
     order by p.nombre;
end $$;

create function public.agregar_docente(p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  select u.id into v_uid from auth.users u where lower(u.email) = lower(trim(coalesce(p_email,'')));
  if v_uid is null then
    raise exception 'Esa persona todavía no tiene cuenta en la turnera. Pedile que se registre primero.';
  end if;
  insert into public.docentes (user_id) values (v_uid) on conflict do nothing;
  return (select nombre from public.perfiles where id = v_uid);
end $$;

create function public.quitar_docente(p_user_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  if p_user_id = auth.uid() then raise exception 'No podés quitarte el acceso a vos mismo'; end if;
  delete from public.docentes where user_id = p_user_id;
end $$;

revoke all on function public.guardar_practica(text,text,text,text,text[],text[],boolean) from public, anon;
revoke all on function public.guardar_regla(bigint,text) from public, anon;
revoke all on function public.eliminar_regla(bigint) from public, anon;
revoke all on function public.mover_regla(bigint,int) from public, anon;
revoke all on function public.responder_hilo(bigint,text) from public, anon;
revoke all on function public.listar_docentes() from public, anon;
revoke all on function public.agregar_docente(text) from public, anon;
revoke all on function public.quitar_docente(uuid) from public, anon;
grant execute on function public.guardar_practica(text,text,text,text,text[],text[],boolean) to authenticated;
grant execute on function public.guardar_regla(bigint,text) to authenticated;
grant execute on function public.eliminar_regla(bigint) to authenticated;
grant execute on function public.mover_regla(bigint,int) to authenticated;
grant execute on function public.responder_hilo(bigint,text) to authenticated;
grant execute on function public.listar_docentes() to authenticated;
grant execute on function public.agregar_docente(text) to authenticated;
grant execute on function public.quitar_docente(uuid) to authenticated;

-- 6. Las prácticas ocultas no se pueden reservar (se agrega un control a reservar_turno)
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
begin
  if uid is null then raise exception 'Tenés que ingresar para reservar'; end if;
  if not exists (select 1 from perfiles where id = uid) then
    raise exception 'Falta completar tu perfil';
  end if;
  select * into v_turno from turnos where id = p_turno;
  if not found then raise exception 'Turno inexistente'; end if;
  if extract(dow from p_fecha) = 0 then raise exception 'El laboratorio no abre los domingos'; end if;
  if extract(dow from p_fecha) = 6 and p_turno >= 4 then
    raise exception 'Los sábados solo hay turnos de mañana y tarde';
  end if;
  v_inicio := (p_fecha + make_time(v_turno.hora_ini, 0, 0)) at time zone 'America/Argentina/Buenos_Aires';
  if v_inicio <= now() then raise exception 'Ese turno ya empezó o pasó'; end if;
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
  elsif v_inicio < now() + interval '24 hours' then
    v_estado := 'confirmado';
  else
    v_estado := 'reservado';
  end if;
  begin
    insert into reservas (user_id, fecha, turno_id, practica_id, area_id, estado, confirmar_hasta)
    values (uid, p_fecha, p_turno, p_practica, p_area, v_estado,
            case when v_estado = 'reservado' then plazo_confirmacion(p_fecha, p_turno) end);
  exception when unique_violation then
    raise exception 'Ya tenés un lugar en ese turno';
  end;
  return v_estado;
end $function$;
