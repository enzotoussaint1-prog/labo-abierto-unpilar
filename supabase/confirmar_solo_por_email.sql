-- La asistencia SOLO se confirma desde el link del correo que llega 24 h antes del turno.
-- Se aplica SOBRE el estado actual de la base, que ya tiene: reservas.token_confirmacion, procesar_turnos
-- (genera el token + el aviso "recordatorio" 24 h antes), consultar_confirmacion / confirmar_por_token,
-- y `confirmar_reserva` sin permiso para el navegador. Este script cierra lo que faltaba.

-- 1. Ventana de 24 h dentro de la base: aunque exista un token, antes de las 24 h previas responde 'muy_pronto'.
--    (confirmar_por_token ya solo confirma cuando el resultado es 'pendiente', así que queda cubierto.)
create or replace function public.consultar_confirmacion(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $function$
declare r reservas%rowtype; v_ini timestamptz; d jsonb;
begin
  if p_token is null then return jsonb_build_object('resultado', 'invalido'); end if;
  select * into r from reservas where token_confirmacion = p_token;
  if not found then return jsonb_build_object('resultado', 'invalido'); end if;
  v_ini := inicio_turno(r.fecha, r.turno_id);
  select jsonb_build_object('fecha', r.fecha, 'hora_ini', t.hora_ini, 'hora_fin', t.hora_fin,
                            'practica', pr.nombre, 'hasta', r.confirmar_hasta)
    into d from turnos t, practicas pr where t.id = r.turno_id and pr.id = r.practica_id;
  return d || jsonb_build_object('resultado', case
    when r.estado = 'confirmado' then 'ya'
    when r.estado = 'reservado' and v_ini > now() and v_ini - interval '24 hours' > now() then 'muy_pronto'
    when r.estado = 'reservado' and v_ini > now() and (r.confirmar_hasta is null or r.confirmar_hasta > now()) then 'pendiente'
    else 'vencido' end);
end $function$;

-- 2. Lista de espera: si el lugar se libera con MÁS de 24 h de anticipación (p. ej. alguien cancela una semana antes),
--    la persona pasa a "reservado" con el plazo normal, SIN token ni plazo de 5 h. Recibe el recordatorio normal
--    24 h antes (lo genera procesar_turnos). Si faltan 24 h o menos, sigue igual: token + 5 h para confirmar.
create or replace function public.promover_espera(p_fecha date, p_turno integer)
returns integer
language plpgsql security definer set search_path to 'public' as $function$
declare
  cupo constant int := 12;
  v_inicio timestamptz := inicio_turno(p_fecha, p_turno);
  v_ocup int; v_prac text; r reservas%rowtype; n int := 0;
begin
  if v_inicio <= now() then return 0; end if;
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

-- 3. El token no debe poder leerse desde el navegador (si no, se podría confirmar sin pasar por el correo).
--    Se mantiene la lectura de las demás columnas, que son las que usa la web.
revoke select on public.reservas from authenticated;
grant select (id, user_id, fecha, turno_id, practica_id, area_id, estado, created_at, updated_at, confirmar_hasta, recordatorio_at)
  on public.reservas to authenticated;
-- Si en el futuro agregás una columna a `reservas` que la web deba leer, hay que darle grant select (columna) igual que arriba.

-- 4. Por las dudas (ya está aplicado en tu proyecto): confirmar_reserva no se llama desde el navegador.
revoke all on function public.confirmar_reserva(bigint) from public, anon, authenticated;
