import { createClient } from '@supabase/supabase-js';
export const supabase = createClient(import.meta.env.VITE_SUPABASE_URL, import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY);
export async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args || {});
  if (error) throw new Error(error.message);
  return data;
}

// Signal « Rivage a envoyé un webhook » (050) : canal Realtime privé « pilotage », réservé aux membres actifs.
// Le message ne contient que le type d'objet Rivage modifié (Incident, LeasingContract…), aucune donnée.
const ecouteurs = new Set();
let canal = null;
async function ouvrirCanal() {
  if (canal) return;
  canal = supabase.channel('pilotage', { config: { private: true } });
  await supabase.realtime.setAuth();
  canal.on('broadcast', { event: 'rivage' }, ({ payload }) => ecouteurs.forEach((f) => f(payload?.type)))
    .subscribe();
}
export function ecouterRivage(f) {
  ecouteurs.add(f);
  ouvrirCanal().catch(() => {});
  return () => ecouteurs.delete(f);
}
