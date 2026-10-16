import { createClient } from 'npm:@supabase/supabase-js@2.118.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json; charset=utf-8' } });
}

async function requireStaff(req: Request) {
  const auth = req.headers.get('authorization') || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) throw new Error('UNAUTHORIZED');
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData.user) throw new Error('UNAUTHORIZED');
  const { data: profile, error: profileError } = await admin.from('staff_profiles').select('role,active,deleted_at').eq('user_id', userData.user.id).maybeSingle();
  if (profileError || !profile || !profile.active || profile.deleted_at) throw new Error('FORBIDDEN');
  return { ...userData.user, staffRole: profile.role };
}

async function listStaff() {
  const { data: profiles, error } = await admin.from('staff_profiles').select('user_id,full_name,role,active,created_at,updated_at').is('deleted_at', null).order('created_at');
  if (error) throw error;
  const { data: usersData, error: usersError } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (usersError) throw usersError;
  const users = new Map(usersData.users.map((u) => [u.id, u]));
  return (profiles || []).map((p) => {
    const u = users.get(p.user_id);
    return { ...p, email: u?.email || '', last_sign_in_at: u?.last_sign_in_at || null };
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  try {
    const caller = await requireStaff(req);
    const body = await req.json().catch(() => ({}));
    const action = String(body.action || '');
    const managesUsers = ['admin', 'manager'].includes(caller.staffRole);
    if (action === 'my_password') {
      const password = String(body.password || '');
      const currentPassword = String(body.currentPassword || '');
      if (password.length < 8 || password.length > 128 || !currentPassword) return json({ error: 'Indica tu contraseña actual y una nueva de 8 a 128 caracteres' }, 400);
      const verifier = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
      const verified = await verifier.auth.signInWithPassword({ email: caller.email!, password: currentPassword });
      if (verified.error || verified.data.user?.id !== caller.id) return json({ error: 'La contraseña actual no es correcta' }, 400);
      await verifier.auth.signOut();
      const changed = await admin.auth.admin.updateUserById(caller.id, { password });
      if (changed.error) return json({ error: changed.error.message }, 400);
      return json({ ok: true });
    }
    if (!managesUsers) throw new Error('FORBIDDEN');

    if (action === 'list') return json({ users: await listStaff() });

    if (action === 'create') {
      const email = String(body.email || '').trim().toLowerCase();
      const password = String(body.password || '');
      const fullName = String(body.fullName || '').trim().toUpperCase();
      const role = String(body.role || 'employee');
      if (!email.includes('@')) return json({ error: 'Email no válido' }, 400);
      if (password.length < 8 || password.length > 128) return json({ error: 'La contraseña debe tener al menos 8 caracteres' }, 400);
      if (!['admin','manager','employee'].includes(role)) return json({ error: 'Rol no válido' }, 400);
      if (!fullName) return json({ error: 'Indica el nombre del empleado' }, 400);
      const { data: created, error: createError } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name: fullName } });
      if (createError || !created.user) return json({ error: createError?.message || 'No se pudo crear el usuario' }, 400);
      const { error: profileError } = await admin.from('staff_profiles').upsert({ user_id: created.user.id, full_name: fullName, role, active: true });
      if (profileError) {
        await admin.auth.admin.deleteUser(created.user.id).catch(() => {});
        return json({ error: profileError.message }, 400);
      }
      return json({ ok: true, user: { id: created.user.id, email, full_name: fullName, role, active: true } });
    }

    if (action === 'update') {
      const userId = String(body.userId || '');
      const role = String(body.role || '');
      if (typeof body.active !== 'boolean') return json({ error: 'Acceso no válido' }, 400);
      const active = body.active;
      const fullName = String(body.fullName || '').trim().toUpperCase();
      if (!userId || !['admin','manager','employee'].includes(role)) return json({ error: 'Datos no válidos' }, 400);
      if (userId === caller.id && (!active || role !== caller.staffRole)) return json({ error: 'No puedes quitarte tu propio acceso ni cambiar tu permiso' }, 400);
      if (!active || role !== 'admin') {
        const { count } = await admin.from('staff_profiles').select('*', { count: 'exact', head: true }).eq('role', 'admin').eq('active', true).neq('user_id', userId);
        const { data: target } = await admin.from('staff_profiles').select('role,active').eq('user_id', userId).maybeSingle();
        if (target?.role === 'admin' && target?.active && (count || 0) < 1) return json({ error: 'Debe quedar al menos un administrador activo' }, 400);
      }
      const { data: target, error: targetError } = await admin.from('staff_profiles').select('user_id').eq('user_id', userId).is('deleted_at', null).maybeSingle();
      if (targetError || !target) return json({ error: 'Usuario no disponible' }, 404);
      const { error } = await admin.from('staff_profiles').update({ full_name: fullName || null, role, active, updated_at: new Date().toISOString() }).eq('user_id', userId);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    if (action === 'delete') {
      const userId = String(body.userId || '');
      if (userId === caller.id) return json({ error: 'No puedes eliminar tu propio acceso' }, 400);
      const { data: target, error: targetError } = await admin.from('staff_profiles').select('user_id').eq('user_id', userId).is('deleted_at', null).maybeSingle();
      if (targetError || !target) return json({ error: 'Usuario no disponible' }, 404);
      const { error } = await admin.from('staff_profiles').update({ active: false, deleted_at: new Date().toISOString() }).eq('user_id', userId);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    if (action === 'set_password') {
      const userId = String(body.userId || '');
      const password = String(body.password || '');
      if (!userId || password.length < 8 || password.length > 128) return json({ error: 'La contraseña debe tener al menos 8 caracteres' }, 400);
      const { data: target, error: targetError } = await admin.from('staff_profiles').select('user_id').eq('user_id', userId).is('deleted_at', null).maybeSingle();
      if (targetError || !target) return json({ error: 'Usuario no disponible' }, 404);
      const { error } = await admin.auth.admin.updateUserById(userId, { password });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: 'Acción no válida' }, 400);
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Error';
    if (msg === 'UNAUTHORIZED') return json({ error: 'Sesión no válida' }, 401);
    if (msg === 'FORBIDDEN') return json({ error: 'Solo un administrador o gerente puede gestionar usuarios' }, 403);
    return json({ error: msg }, 500);
  }
});
