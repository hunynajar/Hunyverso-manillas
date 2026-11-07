// Edge Function "cuentas": registro, ingreso, activación de cuentas antiguas y recuperación de contraseña.
// Usa la service role del entorno de la función (nunca llega al navegador).
import { createClient } from "jsr:@supabase/supabase-js@2";

const URL_SB = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const opciones = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(URL_SB, SERVICE, opciones);
const publico = () => createClient(URL_SB, ANON, opciones);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const responder = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...CORS, "Content-Type": "application/json" } });
const fallo = (mensaje: string, estado = 400) => responder({ error: mensaje }, estado);

const normUsuario = (u: unknown) => String(u ?? "").trim().replace(/^@+/, "").replace(/\s+/g, "").toLowerCase();
const normCodigo = (c: unknown) => String(c ?? "").trim().toUpperCase();
const esCorreo = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e);
const USUARIO_OK = /^[a-z0-9._@+-]{3,60}$/;
const TIPOS = ["Amor", "Abundancia", "Proteccion"];
const MSG_LOGIN = "Usuario o contraseña incorrectos.";

async function iniciarSesion(email: string, password: string) {
  const { data, error } = await publico().auth.signInWithPassword({ email, password });
  if (error || !data.session) return null;
  return { access_token: data.session.access_token, refresh_token: data.session.refresh_token };
}

async function buscarUsuario(username: string) {
  const { data } = await admin.from("usuarios").select("id, nombre, username, auth_id, codigo_manilla_usado")
    .eq("username", username).maybeSingle();
  return data;
}

async function correoDe(authId: string) {
  const { data } = await admin.auth.admin.getUserById(authId);
  return data?.user?.email ?? null;
}

// Límite de intentos fallidos con código de manilla (5 por hora por usuario)
async function bloqueado(username: string, maximo = 5) {
  const desde = new Date(Date.now() - 3600_000).toISOString();
  const { count } = await admin.from("intentos_recuperacion").select("id", { count: "exact", head: true })
    .eq("username", username).gte("creado_en", desde);
  return (count ?? 0) >= maximo;
}
async function registrarFallo(username: string) {
  await admin.from("intentos_recuperacion").insert({ username });
}
const MSG_BLOQUEO = "Demasiados intentos. Prueba de nuevo en una hora.";
const MSG_CODIGO = "No pudimos verificar tu cuenta con ese código.";

// ¿El código pertenece a este usuario? (código del registro o de cualquiera de sus manillas)
async function codigoDeUsuario(u: { id: string; codigo_manilla_usado: string | null }, codigo: string) {
  if ((u.codigo_manilla_usado ?? "").toUpperCase() === codigo) return true;
  const { data } = await admin.from("manillas_usuario").select("id").eq("usuario_id", u.id).eq("codigo_manilla", codigo).limit(1);
  return !!(data && data.length);
}

function errorCreacion(msg: string) {
  return /already|registered|exists/i.test(msg) ? "Ese correo ya está en uso en otra cuenta." : "No se pudo crear la cuenta. Intenta de nuevo.";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fallo("Método no permitido", 405);

  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return fallo("Solicitud inválida"); }
  const accion = String(b.accion ?? "");

  try {
    // ---------- REGISTRO ----------
    if (accion === "registro") {
      const nombre = String(b.nombre ?? "").trim().slice(0, 80);
      const username = normUsuario(b.username);
      const email = String(b.email ?? "").trim().toLowerCase();
      const password = String(b.password ?? "");
      const codigo = normCodigo(b.codigo);
      const tipo = String(b.tipo ?? "");
      const intencion = String(b.intencion ?? "").trim().slice(0, 500);

      if (!nombre || !username || !email || !password || !codigo || !intencion) return fallo("Completa todos los campos.");
      if (!USUARIO_OK.test(username)) return fallo("El usuario solo puede tener letras, números y . _ - (mínimo 3).");
      if (!esCorreo(email)) return fallo("Escribe un correo válido.");
      if (password.length < 8) return fallo("La contraseña debe tener al menos 8 caracteres.");
      if (!TIPOS.includes(tipo)) return fallo("Elige el tipo de manilla.");

      if (await buscarUsuario(username)) return fallo("Ese usuario único ya está en uso. Elige otro.");
      const { data: cod } = await admin.from("codigos_manillas").select("codigo").eq("codigo", codigo).eq("usado", false).maybeSingle();
      if (!cod) return fallo("Código físico inválido o ya fue usado.");

      const { data: creado, error: errCrear } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      if (errCrear || !creado?.user) return fallo(errorCreacion(errCrear?.message ?? ""));

      const { error: errReg } = await admin.rpc("registrar_cuenta", {
        p_auth_id: creado.user.id, p_nombre: nombre, p_username: username, p_codigo: codigo, p_tipo: tipo, p_intencion: intencion,
      });
      if (errReg) {
        await admin.auth.admin.deleteUser(creado.user.id);
        const m = errReg.message || "";
        if (m.includes("USUARIO_EXISTE")) return fallo("Ese usuario único ya está en uso. Elige otro.");
        if (m.includes("CODIGO_INVALIDO")) return fallo("Código físico inválido o ya fue usado.");
        return fallo("No se pudo crear la cuenta. Intenta de nuevo.");
      }
      const session = await iniciarSesion(email, password);
      return session ? responder({ session }) : fallo("Tu cuenta se creó. Entra con tu usuario y contraseña.");
    }

    // ---------- INGRESO ----------
    if (accion === "login") {
      const usuario = normUsuario(b.usuario);
      const password = String(b.password ?? "");
      if (!usuario || !password) return fallo("Escribe tu usuario y tu contraseña.");
      const claveLogin = "login:" + usuario;
      if (await bloqueado(claveLogin, 10)) return fallo(MSG_BLOQUEO, 429);

      const u = await buscarUsuario(usuario);
      if (u) {
        if (!u.auth_id) return responder({ activar: true });
        const email = await correoDe(u.auth_id);
        const session = email ? await iniciarSesion(email, password) : null;
        if (session) return responder({ session });
        await registrarFallo(claveLogin);
        return fallo(MSG_LOGIN, 401);
      }
      if (esCorreo(usuario)) {
        const session = await iniciarSesion(usuario, password);
        if (session) return responder({ session });
      }
      await registrarFallo(claveLogin);
      return fallo(MSG_LOGIN, 401);
    }

    // ---------- ACTIVAR CUENTA ANTIGUA (crear contraseña con el código de la manilla) ----------
    if (accion === "activar") {
      const usuario = normUsuario(b.usuario);
      const codigo = normCodigo(b.codigo);
      const email = String(b.email ?? "").trim().toLowerCase();
      const password = String(b.password ?? "");
      if (!usuario || !codigo || !email || !password) return fallo("Completa todos los campos.");
      if (!esCorreo(email)) return fallo("Escribe un correo válido.");
      if (password.length < 8) return fallo("La contraseña debe tener al menos 8 caracteres.");

      if (await bloqueado(usuario)) return fallo(MSG_BLOQUEO, 429);
      const u = await buscarUsuario(usuario);
      if (!u || u.auth_id || !(await codigoDeUsuario(u, codigo))) { await registrarFallo(usuario); return fallo(MSG_CODIGO); }

      const { data: creado, error: errCrear } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      if (errCrear || !creado?.user) return fallo(errorCreacion(errCrear?.message ?? ""));
      const { data: enlazado, error: errUpd } = await admin.from("usuarios").update({ auth_id: creado.user.id })
        .eq("id", u.id).is("auth_id", null).select("id");
      if (errUpd || !enlazado?.length) {
        await admin.auth.admin.deleteUser(creado.user.id);
        return fallo("No pudimos activar tu cuenta. Intenta de nuevo.");
      }
      const session = await iniciarSesion(email, password);
      return session ? responder({ session }) : fallo("Tu contraseña quedó creada. Entra con tu usuario y contraseña.");
    }

    // ---------- RESTABLECER CONTRASEÑA CON EL CÓDIGO DE LA MANILLA ----------
    if (accion === "restablecer") {
      const usuario = normUsuario(b.usuario);
      const codigo = normCodigo(b.codigo);
      const password = String(b.password ?? "");
      if (!usuario || !codigo || !password) return fallo("Completa todos los campos.");
      if (password.length < 8) return fallo("La contraseña debe tener al menos 8 caracteres.");
      if (await bloqueado(usuario)) return fallo(MSG_BLOQUEO, 429);

      const u = await buscarUsuario(usuario);
      if (!u || !(await codigoDeUsuario(u, codigo))) { await registrarFallo(usuario); return fallo(MSG_CODIGO); }
      if (!u.auth_id) return responder({ activar: true });

      const { data: upd, error: errUpd } = await admin.auth.admin.updateUserById(u.auth_id, { password });
      if (errUpd || !upd?.user?.email) return fallo("No se pudo cambiar la contraseña. Intenta de nuevo.");
      const session = await iniciarSesion(upd.user.email, password);
      return session ? responder({ session }) : fallo("Tu contraseña cambió. Entra con tu usuario y contraseña nueva.");
    }

    // ---------- RECUPERAR CONTRASEÑA POR CORREO (enlace) ----------
    if (accion === "recuperar") {
      const usuario = normUsuario(b.usuario);
      const redirectTo = String(b.redirectTo ?? "") || undefined;
      let email: string | null = null;
      const u = usuario ? await buscarUsuario(usuario) : null;
      if (u?.auth_id) email = await correoDe(u.auth_id);
      else if (esCorreo(usuario)) email = usuario;
      if (email) await publico().auth.resetPasswordForEmail(email, { redirectTo });
      return responder({ ok: true });
    }

    return fallo("Acción desconocida");
  } catch (_e) {
    return fallo("Ocurrió un error. Intenta de nuevo.", 500);
  }
});
