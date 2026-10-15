// Lecture d'un export Excel Monday du tableau « Suivi IMPAYES » (onglet 1 : éléments, onglet 2 : mises à jour).
// Même logique que la reprise faite le 15/10 : groupes, colonnes par position, sous-éléments, commentaires et réponses.
const GROUPES = [['DOSSIERS SUIVI IMPAYES - GLI ZELOK', 'GLI ZELOK'], ['TRANSFERT MILA', 'TRANSFERT MILA'], ['SMARTGARANT', 'SMARTGARANT'],
  ['HUISSIER - COMMANDEMENT DE PAYER', 'HUISSIER'], ["DOSSIER EN COURS CHEZ L'AVOCAT", 'AVOCAT'], ['DOSSIERS SUIVI IMPAYES - GARANTIE VISALE', 'VISALE'],
  ['DOSSIER CLOTURE', 'Clôturé'], ['LIQUIDATION JUDICIAIRE', 'LIQUIDATION']];
const MOIS = { january: 0, february: 1, march: 2, april: 3, may: 4, june: 5, july: 6, august: 7, september: 8, october: 9, november: 10, december: 11 };
const vide = (v) => v === null || v === undefined || v === '';
const txt = (v) => { if (vide(v)) return null; if (v instanceof Date) return iso(v); const t = String(v).trim(); return t || null; };
const iso = (dt) => `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
// Dates Excel lues comme numéros de série (jours depuis le 30/12/1899) : indépendant du fuseau du navigateur
const serie = (n) => { const dt = new Date(Date.UTC(1899, 11, 30) + Math.round(n) * 86400000); return dt.toISOString().slice(0, 10); };
const dateJ = (v) => { if (typeof v === 'number') return serie(v); if (v instanceof Date) return iso(v); const t = txt(v); const m = t && t.match(/^(\d{4}-\d{2}-\d{2})/); return m ? m[1] : null; };
const nombre = (v) => {
  if (vide(v)) return null; if (typeof v === 'number') return Math.round(v * 100) / 100;
  const n = Number(String(v).replace(/[\s €]/g, '').replace(',', '.')); return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
};

export async function lireExportMonday(fichier, membres) {
  const XLSX = await import('xlsx');
  const wb = XLSX.read(await fichier.arrayBuffer(), { cellDates: false });
  const [f1, f2] = wb.SheetNames;
  const lignes = XLSX.utils.sheet_to_json(wb.Sheets[f1], { header: 1, raw: true, defval: null });
  const parNom = Object.fromEntries((membres || []).map((m) => [m.prenom.toLowerCase(), m.user_id]));
  const items = []; let groupe = null, dernier = null, enSous = false;
  for (const l0 of lignes.slice(1)) {
    const r = [...l0, ...Array(40).fill(null)];
    const c0 = r[0];
    if (vide(c0) && enSous && !vide(r[1])) { if (dernier) dernier.actions.push({ libelle: txt(r[1]), statut: txt(r[3]), le: dateJ(r[4]) }); continue; }
    if (vide(c0)) { enSous = false; continue; }
    if (c0 === 'Name') { enSous = false; continue; }
    if (c0 === 'Subitems') { enSous = true; continue; }
    enSous = false;
    if (typeof c0 === 'number' || c0 instanceof Date || /^\d{4}-\d{2}-\d{2}( to .*)?$/.test(String(c0))) continue; // lignes de synthèse
    const nonVides = r.filter((c) => !vide(c)).length;
    if (nonVides <= 1) { const t = String(c0).trim(); groupe = (GROUPES.find(([k]) => t.startsWith(k)) || [t, t])[1]; continue; }
    const pers = txt(r[3]) || '';
    const resp = pers.split(',').map((p) => parNom[p.trim().split(' ')[0].toLowerCase()]).find(Boolean) || null;
    const it = { monday_id: Number(r[32] || r[30]), groupe, titre: txt(c0), cause: txt(r[2]), intervenants: txt(r[3]), responsable: resp,
      notif_bailleur: txt(r[4]), declaration_le: dateJ(r[5]), garantie_bail: txt(r[6]), garantie: txt(r[7]), procedure: txt(r[8]),
      audience_le: dateJ(r[9]), maj_assureur_le: dateJ(r[10]), prise_en_charge: txt(r[11]), montant_impaye: nombre(r[12]),
      indemnisation_recue: txt(r[13]), indemnite_versee_bailleur: txt(r[14]), dette_remb_loc: txt(r[15]),
      solde_a_rembourser_assureur: nombre(r[16]), indemnisation_a_rembourser: txt(r[17]), observations: txt(r[18]), commandement_le: dateJ(r[19]),
      bailleur_civilite: txt(r[21]), bailleur_nom: txt(r[22]), nature_bien: txt(r[23]), adresse: txt(r[24]), mail_bailleur_1: txt(r[25]),
      mail_bailleur_2: txt(r[26]), locataire_civilite: txt(r[27]), locataire_nom: txt(r[28]), tel_locataire: txt(r[29]), actions: [] };
    if (!it.monday_id) continue;
    items.push(it); dernier = it;
  }
  const notes = [];
  if (f2) {
    const u = XLSX.utils.sheet_to_json(wb.Sheets[f2], { header: 1, raw: true, defval: null });
    for (const r of u.slice(2)) {
      if (!r || vide(r[0])) continue;
      let le = null;
      if (r[5] instanceof Date) le = r[5];
      else {
        const m = String(r[5] || '').replace(/\s+/g, ' ').trim().match(/^(\d{1,2})\/([A-Za-z]+)\/(\d{4}) (\d{1,2}):(\d{2}):(\d{2}) (AM|PM)$/);
        if (m) { let h = Number(m[4]) % 12; if (m[7] === 'PM') h += 12; le = new Date(Number(m[3]), MOIS[m[2].toLowerCase()], Number(m[1]), h, Number(m[5]), Number(m[6])); }
      }
      if (!le) continue;
      const p = (n) => String(n).padStart(2, '0');
      notes.push({ monday_id: Number(r[0]), post_id: Number(r[9]), parent_post_id: vide(r[10]) ? null : Number(r[10]), auteur: txt(r[4]),
        le: `${le.getFullYear()}-${p(le.getMonth() + 1)}-${p(le.getDate())}T${p(le.getHours())}:${p(le.getMinutes())}:${p(le.getSeconds())}`,
        contenu: String(r[6] || '').trim(), pj: String(r[8] || '').split(',').filter((x) => x.trim()).length });
    }
  }
  const ids = new Set(items.map((i) => i.monday_id));
  return { items, notes: notes.filter((n) => ids.has(n.monday_id)), orphelines: notes.filter((n) => !ids.has(n.monday_id)).length };
}
