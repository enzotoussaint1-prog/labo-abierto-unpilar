-- Programa la Edge Function `enviar-avisos` cada 10 minutos (NO aplicado todavía).
-- La función procesa los plazos (libera turnos sin confirmar, ofrece lugares de la lista de espera,
-- genera recordatorios 24 h antes) y envía los avisos por correo.
--
-- 1) Guardar la clave anon (la de "Legacy anon" en Project Settings > API Keys) en Vault:
--    select vault.create_secret('PEGAR_LA_CLAVE_ANON_ACA', 'enviar_avisos_key');
-- 2) Programar el trabajo:
select cron.schedule(
  'enviar-avisos',
  '*/10 * * * *',
  $$
  select net.http_post(
    url     := 'https://cdjsatazelokimilojxs.supabase.co/functions/v1/enviar-avisos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'enviar_avisos_key')
    ),
    body    := '{}'::jsonb
  );
  $$
);
-- Para pausarlo:  select cron.unschedule('enviar-avisos');
