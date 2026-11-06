# Labo Abierto UNPILAR

Turnera de laboratorios: sitio estático (`index.html`) + Supabase (Auth, Postgres con RLS y funciones RPC).

- Cliente: `index.html` usa `@supabase/supabase-js` por CDN. La URL y la clave *publishable* están al inicio del script (es seguro exponerlas: la seguridad está en RLS y en las funciones).
- Reglas de negocio en el servidor: `reservar_turno`, `confirmar_reserva`, `cancelar_reserva`, `cupos_rango`, `tiene_reserva`.
- `supabase/foro_cupos_permisos.sql`: migración del foro, cupos y permisos.
- Pendiente: avisos por WhatsApp y liberación automática de turnos sin confirmar (hoy "Simular avisos" es solo ilustrativo).
