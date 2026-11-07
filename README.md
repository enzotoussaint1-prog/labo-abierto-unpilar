# Labo Abierto UNPILAR

Turnera de laboratorios: sitio estático (`index.html`) + Supabase (Auth, Postgres con RLS, funciones RPC y una Edge Function).

- **Cliente:** `index.html` usa `@supabase/supabase-js` por CDN. La URL y la clave *publishable* están al inicio del script (es seguro exponerlas: la seguridad está en RLS y en las funciones).
- **Reglas de reserva (servidor):** `reservar_turno`, `confirmar_reserva`, `cancelar_reserva`, `cupos_rango`, `tiene_reserva`, `eliminar_mi_cuenta`.
- **Plazos y avisos (servidor):** `procesar_turnos` libera los turnos sin confirmar, ofrece el lugar a la lista de espera (`promover_espera`) y genera los recordatorios de 24 h. `reclamar_avisos` / `marcar_aviso` manejan la cola de la tabla `avisos`. Solo las puede usar `service_role`.
- **Envío de correos:** Edge Function `supabase/functions/enviar-avisos`. Secretos en Supabase (nunca en el código): `SMTP_USER`, `SMTP_PASS`; opcionales `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM`, `SITE_URL`.
- **Programación:** `supabase/programar_avisos.sql` (cron cada 10 minutos con `pg_cron` + `pg_net`).
- `supabase/foro_cupos_permisos.sql`: migración del foro, cupos y permisos.

Pendiente: avisos por WhatsApp (hoy los avisos salen por correo; "Simular avisos" es solo una demo ilustrativa).
