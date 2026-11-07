import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

// Datos del correo (se cargan como secretos en Supabase, nunca en el código):
//   SMTP_USER, SMTP_PASS            -> obligatorios
//   SMTP_HOST (smtp.gmail.com), SMTP_PORT (465), SMTP_FROM, SITE_URL -> opcionales
// Para pasar al correo de la universidad solo hay que cambiar estos secretos.

const TZ = "America/Argentina/Buenos_Aires";
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const hh = (h: number) => String(h).padStart(2, "0") + ":00";

function diaTurno(fecha: string, ini: number, fin: number) {
  const d = new Date(fecha + "T12:00:00Z");
  const dia = new Intl.DateTimeFormat("es-AR", { timeZone: "UTC", weekday: "long", day: "numeric", month: "long" }).format(d);
  return `${dia}, de ${hh(ini)} a ${hh(fin)}`;
}
function limite(ts: string | null) {
  if (!ts) return "";
  return new Intl.DateTimeFormat("es-AR", { timeZone: TZ, weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(ts)) + " h";
}

type Aviso = {
  id: number; tipo: string; email: string; nombre: string; fecha: string | null; hora_ini: number | null;
  hora_fin: number | null; practica: string | null; confirmar_hasta: string | null; estado: string | null;
};

function armarMensaje(a: Aviso, site: string) {
  const nombre = (a.nombre || "").trim().split(" ")[0] || "";
  const turno = a.fecha && a.hora_ini != null ? diaTurno(a.fecha, a.hora_ini, a.hora_fin!) : "";
  const hasta = limite(a.confirmar_hasta);
  let asunto = "", lineas: string[] = [];
  if (a.tipo === "recordatorio") {
    asunto = `Confirmá tu turno de laboratorio: ${a.practica}`;
    lineas = [
      `Tenés turno de ${a.practica} el ${turno}.`,
      `Entrá a la turnera y confirmá tu asistencia antes del ${hasta}. Si no confirmás, tu lugar se libera para otra persona.`,
      `Si no vas a poder ir, cancelá el turno para que otra persona lo aproveche.`,
    ];
  } else if (a.tipo === "lugar_ofrecido") {
    asunto = `Se liberó un lugar para vos: ${a.practica}`;
    lineas = [
      `Se liberó un lugar en el turno de ${a.practica} del ${turno}, y estabas en la lista de espera.`,
      `Confirmalo en la turnera antes del ${hasta}. Si no lo hacés, el lugar pasa a la siguiente persona.`,
    ];
  } else if (a.tipo === "turno_liberado") {
    asunto = `Se liberó tu turno de ${a.practica}`;
    lineas = [
      `No confirmaste a tiempo tu turno de ${a.practica} del ${turno}, así que el lugar se liberó.`,
      `Podés volver a reservar desde la turnera. Recordá que dos turnos sin confirmar en una semana suspenden las reservas por siete días.`,
    ];
  } else {
    asunto = "Prueba de avisos de Labo Abierto UNPILAR";
    lineas = ["Este es un correo de prueba: los avisos de la turnera están funcionando."];
  }
  const saludo = nombre ? `Hola, ${nombre}.` : "Hola.";
  const texto = [saludo, "", ...lineas, site ? `\nTurnera: ${site}` : "", "\nLabo Abierto UNPILAR"].join("\n");
  const html = `<div style="font-family:Arial,sans-serif;max-width:520px;color:#12283d;line-height:1.5">` +
    `<p>${esc(saludo)}</p>${lineas.map((l) => `<p>${esc(l)}</p>`).join("")}` +
    (site ? `<p><a href="${esc(site)}" style="background:#00579e;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none">Abrir la turnera</a></p>` : "") +
    `<p style="color:#7b8a99;font-size:13px">Labo Abierto UNPILAR</p></div>`;
  return { asunto, texto, html };
}

Deno.serve(async () => {
  const user = Deno.env.get("SMTP_USER"), pass = Deno.env.get("SMTP_PASS");
  if (!user || !pass) {
    // Sin correo configurado no se procesa nada: así no se liberan turnos sin poder avisar.
    return json({ error: "Faltan los secretos SMTP_USER y SMTP_PASS. No se procesó nada." }, 500);
  }
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: proceso, error: e1 } = await sb.rpc("procesar_turnos");
  if (e1) return json({ error: e1.message }, 500);

  const { data: avisos, error: e2 } = await sb.rpc("reclamar_avisos", { p_max: 20 });
  if (e2) return json({ error: e2.message }, 500);
  if (!avisos || avisos.length === 0) return json({ proceso, enviados: 0 });

  const transporte = nodemailer.createTransport({
    host: Deno.env.get("SMTP_HOST") ?? "smtp.gmail.com",
    port: Number(Deno.env.get("SMTP_PORT") ?? 465),
    secure: true,
    auth: { user, pass },
  });
  const from = Deno.env.get("SMTP_FROM") ?? `"Labo Abierto UNPILAR" <${user}>`;
  const site = Deno.env.get("SITE_URL") ?? "";

  let enviados = 0, omitidos = 0, fallidos = 0;
  for (const a of avisos as Aviso[]) {
    try {
      // Si ya cambió la situación (confirmó, canceló), el aviso no tiene sentido
      if ((a.tipo === "recordatorio" || a.tipo === "lugar_ofrecido") && a.estado !== "reservado") {
        await sb.rpc("marcar_aviso", { p_id: a.id, p_ok: true, p_error: `omitido: la reserva está ${a.estado}` });
        omitidos++; continue;
      }
      const m = armarMensaje(a, site);
      await transporte.sendMail({ from, to: a.email, subject: m.asunto, text: m.texto, html: m.html });
      await sb.rpc("marcar_aviso", { p_id: a.id, p_ok: true, p_error: null });
      enviados++;
    } catch (err) {
      fallidos++;
      await sb.rpc("marcar_aviso", { p_id: a.id, p_ok: false, p_error: String((err as Error).message).slice(0, 300) });
    }
  }
  return json({ proceso, enviados, omitidos, fallidos });
});
