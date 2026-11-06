-- Migración aplicada al proyecto cdjsatazelokimilojxs (labo_foro_cupos_y_permisos + labo_catalogo_lectura_publica)
drop view if exists public.cupos;
create or replace function public.cupos_rango(p_desde date, p_hasta date)
returns table (fecha date, turno_id int, practica_id text, ocupados int, en_espera int)
language sql stable security definer set search_path = public as $$
  select r.fecha, r.turno_id,
         min(r.practica_id) filter (where r.estado in ('reservado','confirmado')),
         (count(*) filter (where r.estado in ('reservado','confirmado')))::int,
         (count(*) filter (where r.estado = 'espera'))::int
    from reservas r where r.fecha between p_desde and p_hasta group by r.fecha, r.turno_id
$$;
revoke execute on function public.cupos_rango(date, date) from public, anon;
grant execute on function public.cupos_rango(date, date) to authenticated;

create table public.foro_hilos (
  id bigint generated always as identity primary key,
  user_id uuid default auth.uid() references public.perfiles(id) on delete set null,
  practica_id text not null references public.practicas(id),
  pregunta text not null check (char_length(btrim(pregunta)) between 5 and 1000),
  respuesta text, respondido_por text,
  created_at timestamptz not null default now()
);
create index foro_hilos_created_idx on public.foro_hilos (created_at desc);
alter table public.foro_hilos enable row level security;
create or replace function public.tiene_reserva() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from reservas where user_id = auth.uid() and estado in ('reservado','confirmado','espera')) $$;
revoke execute on function public.tiene_reserva() from public, anon;
grant execute on function public.tiene_reserva() to authenticated;
create policy "foro: leer con reserva" on public.foro_hilos for select to authenticated using (public.tiene_reserva());
create policy "foro: preguntar con reserva" on public.foro_hilos for insert to authenticated
  with check (user_id = auth.uid() and public.tiene_reserva() and respuesta is null);

revoke all on all tables in schema public from anon;
revoke insert, delete, truncate, references, trigger on all tables in schema public from authenticated;
revoke update on public.labs, public.areas, public.practicas, public.practica_areas, public.turnos, public.reservas, public.foro_hilos from authenticated;
grant insert (practica_id, pregunta) on public.foro_hilos to authenticated;
grant select on public.labs, public.areas, public.practicas, public.practica_areas, public.turnos to anon;
