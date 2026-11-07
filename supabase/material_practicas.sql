-- =====================================================================
-- Material de apoyo por práctica: PDF y/o video (archivo o link)
-- Los archivos van al bucket público "practicas-material" (lectura para todos,
-- escritura solo para docentes). La práctica guarda la ruta o el link.
-- =====================================================================

-- 1. Columnas nuevas en practicas (todas opcionales)
alter table public.practicas
  add column pdf_path text,
  add column pdf_nombre text,
  add column video_path text,
  add column video_url text;

-- 2. Bucket: PDF hasta 20 MB y videos hasta 50 MB (límite del plan gratuito)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('practicas-material', 'practicas-material', true, 52428800,
        array['application/pdf','video/mp4','video/webm','video/quicktime'])
on conflict (id) do nothing;

-- 3. Solo docentes suben, reemplazan o borran archivos
create policy "material: docentes suben" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'practicas-material' and public.es_docente());
create policy "material: docentes reemplazan" on storage.objects
  for update to authenticated
  using (bucket_id = 'practicas-material' and public.es_docente())
  with check (bucket_id = 'practicas-material' and public.es_docente());
create policy "material: docentes borran" on storage.objects
  for delete to authenticated
  using (bucket_id = 'practicas-material' and public.es_docente());

-- 4. Guardar el material de una práctica (valida rutas y link)
create function public.guardar_material(
  p_id text, p_pdf_path text, p_pdf_nombre text, p_video_path text, p_video_url text
) returns void
language plpgsql security definer set search_path = public as $$
declare v_url text := nullif(trim(coalesce(p_video_url,'')), '');
begin
  if not public.es_docente() then raise exception 'Solo el equipo docente puede hacer esto'; end if;
  if not exists (select 1 from public.practicas where id = p_id) then
    raise exception 'La práctica no existe';
  end if;
  if p_pdf_path is not null and left(p_pdf_path, length(p_id) + 1) <> p_id || '/' then
    raise exception 'Ruta de PDF inválida';
  end if;
  if p_video_path is not null and left(p_video_path, length(p_id) + 1) <> p_id || '/' then
    raise exception 'Ruta de video inválida';
  end if;
  if v_url is not null and (v_url !~* '^https://' or length(v_url) > 500) then
    raise exception 'El link del video debe empezar con https:// (máximo 500 caracteres)';
  end if;
  update public.practicas
     set pdf_path = p_pdf_path,
         pdf_nombre = case when p_pdf_path is null then null else left(trim(coalesce(p_pdf_nombre,'')), 120) end,
         video_path = p_video_path,
         video_url = v_url
   where id = p_id;
end $$;

revoke all on function public.guardar_material(text,text,text,text,text) from public, anon;
grant execute on function public.guardar_material(text,text,text,text,text) to authenticated;
