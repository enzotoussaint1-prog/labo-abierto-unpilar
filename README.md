# Labo Abierto UNPILAR

Turnera de laboratorios: sitio estático (`index.html`) + Supabase (Auth, Postgres con RLS, funciones RPC y una Edge Function).

- **Cliente:** `index.html` usa `@supabase/supabase-js` por CDN. La URL y la clave *publishable* están al inicio del script (es seguro exponerlas: la seguridad está en RLS y en las funciones).
- **Reglas de reserva (servidor):** `reservar_turno`, `confirmar_reserva`, `cancelar_reserva`, `cupos_rango`, `tiene_reserva`, `eliminar_mi_cuenta`.
- **Plazos y avisos (servidor):** `procesar_turnos` libera los turnos sin confirmar, ofrece el lugar a la lista de espera (`promover_espera`) y genera los recordatorios de 24 h. `reclamar_avisos` / `marcar_aviso` manejan la cola de la tabla `avisos`. Solo las puede usar `service_role`.
- **Confirmación de asistencia (solo por correo):** se puede reservar en cualquier momento, pero confirmar solo se puede desde el botón del correo que llega 24 h antes (`procesar_turnos` genera `reservas.token_confirmacion` y el aviso `recordatorio`). La web abre `?confirmar=TOKEN`, consulta con `consultar_confirmacion` y confirma con `confirmar_por_token`. `confirmar_reserva` no se puede llamar desde el navegador y `token_confirmacion` no es legible por `authenticated`. Ver `supabase/confirmar_solo_por_email.sql`.
- **Envío de correos:** Edge Function `supabase/functions/enviar-avisos`. Secretos en Supabase (nunca en el código): `SMTP_USER`, `SMTP_PASS`; obligatorio `SITE_URL` (dirección de la turnera, adonde apunta el botón de confirmación); opcionales `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM`.
- **Programación:** `supabase/programar_avisos.sql` (cron cada 10 minutos con `pg_cron` + `pg_net`).
- **Panel docente:** `supabase/panel_docente.sql` (tabla `docentes`, funciones `guardar_practica`, `guardar_regla`, `mover_regla`, `eliminar_regla`, `responder_hilo`, `agregar_docente`, `quitar_docente`, `listar_docentes`). Los docentes editan prácticas, reglas de uso y responden el foro desde la pestaña “Panel docente”. Para dar acceso a la primera persona: `insert into public.docentes (user_id) select id from auth.users where email = 'correo@docente.edu.ar';`
- `supabase/foro_cupos_permisos.sql`: migración del foro, cupos y permisos.

Pendiente: avisos por WhatsApp (hoy los avisos salen por correo; "Simular avisos" es solo una demo ilustrativa).
