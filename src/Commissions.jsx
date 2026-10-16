// Onglet Commissions (direction, superviseur) : suivi des commissions par commercial, affectations (négociateur, apporteur,
// « loué par », « EDL fait par », validation des baux) et paramètres de rémunération (règles appliquées à tous).
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';
import { Tuiles } from './App.jsx';

const euro = (n) => (n == null ? '—' : Number(n).toLocaleString('fr-FR', { style: 'currency', currency: 'EUR' }));
const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const auj = () => new Date().toISOString().slice(0, 10);
const PHASES = { apport: 'Apport du mandat', mandat_signe: 'Mandat signé', dossier_complet: 'Dossier complet (GO)', bail_signe: 'Bail signé', edl_fait: 'État des lieux d’entrée fait' };
const BENEF = { apporteur: 'Apporteur du mandat', negociateur: 'Négociateur du mandat', loueur: 'Commercial qui a loué', edl: 'Auteur de l’EDL' };
const BASES = { gestion: 'Honoraires de gestion HT (N mois)', loc_total: 'Honoraires de location HT totaux', loc_bailleur: 'Honoraires de location HT bailleur',
  loc_locataire: 'Honoraires de location HT locataire', edl: 'Honoraires d’EDL HT (part locataire)', forfait: 'Forfait (montant fixe HT)' };
const BASES_PHASE = (p) => (p === 'edl_fait' ? ['loc_total', 'loc_bailleur', 'loc_locataire', 'edl', 'forfait'] : p === 'bail_signe' ? Object.keys(BASES) : ['gestion', 'forfait']);

export default function Commissions() {
  const [d, setD] = useState(null);
  const [mandats, setMandats] = useState(null);
  const [baux, setBaux] = useState([]);
  const [err, setErr] = useState('');
  const [vue, setVue] = useState('suivi');
  const [qui, setQui] = useState(null);
  const charger = () => Promise.all([rpc('pilotage_commissions'), rpc('pilotage_mandats'), rpc('pilotage_baux_a_valider')])
    .then(([c, m, b]) => { setD(c); setMandats(m); setBaux(b || []); }).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d || !mandats) return <p className="sub">Chargement…</p>;
  const agir = async (fn, args) => { setErr(''); try { await rpc(fn, args); await charger(); } catch (e) { setErr(e.message); } };
  const lignes = d.lignes || [];
  const membres = d.membres || [];
  const direction = d.mon_role === 'direction';
  const sansBenef = lignes.filter((l) => !l.beneficiaire).length;
  const aValider = mandats.mandats.filter((m) => m.suivi_commission && m.statut !== 'Retiré sans location' && !m.negociateur).length + baux.filter((b) => !b.valide_le || !b.loue_par).length;
  return <>
    <div className="entete"><div><h1>Commissions</h1>
      <p className="sub">Commissions des commerciaux sur les mandats et les baux depuis le 01/01/2026, calculées avec les règles de rémunération en vigueur.</p></div></div>
    {err && <div className="banner">{err}</div>}
    <Tuiles items={[[euro(lignes.filter((l) => l.du && !l.facture).reduce((t, l) => t + Number(l.montant || 0), 0)), 'Dues à facturer'],
      [euro(lignes.filter((l) => l.facture).reduce((t, l) => t + Number(l.facture.montant ?? l.montant ?? 0), 0)), 'Déjà facturé'],
      [euro(lignes.filter((l) => !l.du && !l.facture).reduce((t, l) => t + Number(l.montant || 0), 0)), 'À venir'],
      [aValider + sansBenef, 'Affectations à faire', aValider + sansBenef > 0]]} />
    <div className="bascule" style={{ marginBottom: 14 }}>{[['suivi', 'Suivi par commercial'], ['affectation', `Affectations et validations${aValider ? ' (' + aValider + ')' : ''}`], ['parametres', 'Paramètres de rémunération']].map(([k, l]) =>
      <button key={k} className={vue === k ? 'on' : ''} onClick={() => setVue(k)}>{l}</button>)}</div>
    {vue === 'suivi' && <Suivi lignes={lignes} membres={membres} qui={qui} setQui={setQui} agir={agir} />}
    {vue === 'affectation' && <Affectations mandats={mandats} baux={baux} membres={membres} lignes={lignes} agir={agir} role={d.mon_role} />}
    {vue === 'parametres' && <Parametres d={d} direction={direction} agir={agir} />}
  </>;
}

// ----- Suivi par commercial -----
function Suivi({ lignes, membres, qui, setQui, agir }) {
  const parQui = membres.map((m) => ({ ...m, lignes: lignes.filter((l) => l.beneficiaire === m.user_id) })).filter((m) => m.lignes.length || m.role === 'negociateur');
  const orphelines = lignes.filter((l) => !l.beneficiaire);
  const choisi = qui || parQui[0]?.user_id || (orphelines.length ? 'aucun' : null);
  const liste = choisi === 'aucun' ? orphelines : (parQui.find((m) => m.user_id === choisi)?.lignes || []);
  const tot = (arr) => arr.reduce((t, l) => t + Number(l.facture?.montant ?? l.montant ?? 0), 0);
  return <>
    <div className="row" style={{ marginBottom: 12 }}>
      {parQui.map((m) => <button key={m.user_id} className={'chip' + (choisi === m.user_id ? ' on' : '')} onClick={() => setQui(m.user_id)}>{m.prenom}<span className="n">{m.lignes.length}</span></button>)}
      {orphelines.length > 0 && <button className={'chip' + (choisi === 'aucun' ? ' on' : '')} onClick={() => setQui('aucun')} style={{ color: 'var(--red)' }}>Bénéficiaire à renseigner<span className="n">{orphelines.length}</span></button>}
    </div>
    <Tuiles items={[[euro(tot(liste.filter((l) => l.du && !l.facture))), 'À facturer maintenant'], [euro(tot(liste.filter((l) => l.facture))), 'Déjà facturé'], [euro(tot(liste.filter((l) => !l.du && !l.facture))), 'À venir']]} />
    <div className="table-wrap"><table>
      <thead><tr><th>Dossier</th><th>Phase</th><th>Calcul</th><th>Condition</th><th>Montant HT</th><th>État</th><th>N° de facture</th></tr></thead>
      <tbody>{liste.map((l) => <tr key={l.objet + l.regle} className={Number(l.montant) < 0 ? 'anomalie' : ''}>
        <td>{l.type === 'mandat' ? `Mandat n°${l.mandat_ref}` : `Bail ${l.bail_ref} · ${l.locataires || ''}`}<div className="muted">{l.bailleur}</div></td>
        <td>{l.phase_libelle}<div className="muted">{BENEF[l.beneficiaire_role]}{l.regle_perso ? ' · règle personnelle' : ''}</div></td>
        <td className="muted">{l.base === 'forfait' ? 'Forfait' : `${l.pourcentage} % × ${l.base_libelle} (${euro(l.base_montant)})`}</td>
        <td className="muted">{l.condition}</td>
        <td style={{ fontWeight: 700, color: Number(l.montant) < 0 ? 'var(--red)' : undefined }}>{euro(l.montant)}{Number(l.montant) < 0 && <div className="muted">reprise sur commissions à venir</div>}</td>
        <td>{l.facture ? <span className="etq ok">Facturé</span> : l.du ? <span className="etq encours">À facturer</span> : <span className="etq neutre">En attente</span>}</td>
        <td><input style={{ width: 110 }} defaultValue={l.facture?.facture || ''} key={'f' + l.objet + l.regle + (l.facture?.facture || '')} placeholder={l.du ? 'n° facture' : '—'} disabled={!l.du && !l.facture}
          onBlur={(e) => e.target.value !== (l.facture?.facture || '') && agir('pilotage_commission_facturer', { p_mandat: l.objet, p_versement: l.regle, p_facture: e.target.value, p_montant: l.montant })} /></td>
      </tr>)}
      {!liste.length && <tr><td colSpan="7" className="muted">Aucune commission.</td></tr>}</tbody></table></div>
    <p className="muted" style={{ fontSize: 12 }}>Une ligne devient « à facturer » quand sa condition est remplie et son bénéficiaire renseigné. La rentrée d’un mandat est calculée sur le loyer prévu, puis recalculée sur le loyer réel au bail signé ; la différence peut être négative (reprise sur les commissions à venir).</p>
  </>;
}

// ----- Affectations : négociateur, apporteur, apport direction, loyer prévu ; « loué par », « EDL fait par », validation du bail -----
function Affectations({ mandats, baux, membres, lignes, agir, role }) {
  const choix = (val, onChange, vide) => <select value={val || ''} onChange={(e) => onChange(e.target.value)}><option value="">{vide}</option>{membres.map((n) => <option key={n.user_id} value={n.user_id}>{n.prenom}</option>)}</select>;
  const apporteur = (id) => lignes.find((l) => l.mandat_id === id && l.beneficiaire_role === 'apporteur')?.beneficiaire;
  const edlPar = (id) => lignes.find((l) => l.bail_id === id && l.beneficiaire_role === 'edl')?.beneficiaire;
  const mm = mandats.mandats.filter((m) => m.suivi_commission);
  return <>
    <h2>Mandats depuis le 01/01/2026</h2>
    <div className="table-wrap"><table>
      <thead><tr><th>Mandat</th><th>Bailleur</th><th>Début</th><th>Négociateur</th><th>Apporteur</th><th>Apport direction</th><th>Loyer prévu (CC)</th><th>GO</th></tr></thead>
      <tbody>{mm.map((m) => <tr key={m.id}>
        <td>n°{m.reference}{m.nom ? ' · ' + m.nom : ''}</td><td>{m.bailleur}</td><td>{date(m.debut)}</td>
        <td>{choix(m.negociateur, (v) => agir('pilotage_mandat_maj', { p_mandat: m.id, p_champ: 'negociateur', p_valeur: v }), '— à attribuer —')}</td>
        <td>{choix(apporteur(m.id), (v) => agir('pilotage_remu_affecter', { p_type: 'mandat', p_id: m.id, p_champ: 'apporteur', p_valeur: v }), '— aucun —')}</td>
        <td><input type="checkbox" checked={m.apport_direction} onChange={(e) => agir('pilotage_mandat_maj', { p_mandat: m.id, p_champ: 'apport_direction', p_valeur: String(e.target.checked) })} /></td>
        <td><input style={{ width: 90 }} defaultValue={m.loyer_prevu_saisi ?? ''} key={'lp' + m.id + m.loyer_prevu_saisi} placeholder={m.loyer_prev != null ? String(m.loyer_prev) : 'CC'}
          onBlur={(e) => e.target.value !== String(m.loyer_prevu_saisi ?? '') && agir('pilotage_mandat_maj', { p_mandat: m.id, p_champ: 'loyer_prevu', p_valeur: e.target.value })} /></td>
        <td>{m.go_le ? `✓ ${date(m.go_le)}${m.go_par ? ' · ' + m.go_par : ''}` : <span className="muted">dans la fiche du mandat</span>}</td>
      </tr>)}
      {!mm.length && <tr><td colSpan="8" className="muted">Aucun mandat depuis le 01/01/2026.</td></tr>}</tbody></table></div>
    <p className="muted" style={{ fontSize: 12 }}>Le GO (dossier complet) se donne dans la fiche du mandat, une fois le contrôle d’entrée bouclé.</p>
    <h2 style={{ marginTop: 22 }}>Baux signés depuis le 01/01/2026</h2>
    <div className="table-wrap"><table>
      <thead><tr><th>Bail</th><th>Bailleur · mandat</th><th>Locataire</th><th>Signé le</th><th>Loyer CC</th><th>Honoraires location TTC</th><th>Loué par</th><th>EDL fait par</th><th>Validation</th></tr></thead>
      <tbody>{baux.map((b) => <tr key={b.id}>
        <td><a href={b.lien} target="_blank" rel="noreferrer">{b.reference}</a>{b.mise_en_location_du_mandat && <div className="muted">mise en location du mandat</div>}</td>
        <td>{b.bailleur}<div className="muted">{b.mandat}</div></td><td>{b.locataires}</td><td>{date(b.signe_le || b.debut)}</td><td>{euro(b.loyer_cc)}</td><td>{euro(b.honoraires_location_ttc)}</td>
        <td>{choix(b.loue_par, (v) => agir('pilotage_bail_maj', { p_bail: b.id, p_champ: 'loue_par', p_valeur: v }), '— à renseigner —')}</td>
        <td>{choix(edlPar(b.id), (v) => agir('pilotage_remu_affecter', { p_type: 'bail', p_id: b.id, p_champ: 'edl_par', p_valeur: v }), '— à renseigner —')}</td>
        <td>{b.valide_le ? <span>✓ {date(b.valide_le)}{b.valide_par ? ' · ' + b.valide_par : ''} <button className="lien" onClick={() => agir('pilotage_bail_maj', { p_bail: b.id, p_champ: 'valide', p_valeur: '' })}>annuler</button></span>
          : <button className="btn plein" onClick={() => agir('pilotage_bail_maj', { p_bail: b.id, p_champ: 'valide', p_valeur: auj() })}>Valider</button>}</td>
      </tr>)}
      {!baux.length && <tr><td colSpan="9" className="muted">Aucun bail signé depuis le 01/01/2026.</td></tr>}</tbody></table></div>
    {role === 'superviseur' && <p className="muted">Les paramètres de rémunération sont modifiables par la direction.</p>}
  </>;
}

// ----- Paramètres de rémunération : règles générales et règles par commercial -----
function Parametres({ d, direction, agir }) {
  const vide = { phase: 'mandat_signe', beneficiaire: 'negociateur', pourcentage: '', base: 'gestion', forfait: '', mois: '' };
  const [n, setN] = useState(vide);
  const [qui, setQui] = useState('');   // '' = règles générales, sinon user_id du commercial
  const params = d.parametres || [];
  const membres = d.membres || [];
  const regles = (d.regles || []).filter((r) => (r.membre || '') === qui);
  const avecPerso = new Set((d.regles || []).filter((r) => r.membre && r.actif).map((r) => r.membre));
  const nom = (id) => membres.find((m) => m.user_id === id)?.prenom || '—';
  const copierGenerales = async () => {
    for (const r of (d.regles || []).filter((x) => !x.membre && x.actif)) {
      await agir('pilotage_regle_remu', { p_id: null, p_phase: r.phase, p_beneficiaire: r.beneficiaire, p_pourcentage: r.pourcentage, p_base: r.base, p_forfait: r.forfait,
        p_actif: true, p_supprimer: false, p_membre: qui, p_mois: r.mois ?? null });
    }
  };
  return <>
    <h2>Règles de rémunération</h2>
    <div className="row" style={{ marginBottom: 8 }}>
      <button className={'chip' + (qui === '' ? ' on' : '')} onClick={() => setQui('')}>Règles générales</button>
      {membres.map((m) => <button key={m.user_id} className={'chip' + (qui === m.user_id ? ' on' : '')} onClick={() => setQui(m.user_id)}>
        {m.prenom}{avecPerso.has(m.user_id) && <span className="n">perso</span>}</button>)}
    </div>
    <p className="muted">{qui === '' ? <>Appliquées à tous les commerciaux qui n’ont pas de règles personnelles{avecPerso.size ? ` (règles personnelles : ${[...avecPerso].map(nom).join(', ')})` : ''}.</>
      : avecPerso.has(qui) ? <>{nom(qui)} est payé(e) uniquement selon les règles ci-dessous (les règles générales ne s’appliquent plus à lui ou elle).</>
      : <>{nom(qui)} est payé(e) selon les règles générales. Ajouter une règle ici, ou copier les règles générales pour les ajuster, crée son barème personnel.</>}
      {' '}Une modification recalcule les montants non encore facturés ; les versements déjà facturés gardent leur montant.</p>
    {direction && qui !== '' && !avecPerso.has(qui) && <button className="btn" onClick={copierGenerales}>Copier les règles générales pour {nom(qui)}</button>}
    <div className="table-wrap"><table>
      <thead><tr><th>Phase</th><th>Bénéficiaire</th><th>%</th><th>Calculé sur</th><th>Mois</th><th>Forfait HT</th><th>Active</th><th></th></tr></thead>
      <tbody>{regles.map((r) => <Regle key={r.id} r={r} direction={direction} agir={agir} />)}
        {!regles.length && <tr><td colSpan="8" className="muted">{qui === '' ? 'Aucune règle générale.' : 'Pas de règle personnelle.'}</td></tr>}</tbody></table></div>
    {direction && <div className="row" style={{ gap: 6, marginTop: 8 }}>
      <b>Ajouter une règle {qui === '' ? 'générale' : 'pour ' + nom(qui)} :</b>
      <select value={n.phase} onChange={(e) => setN({ ...n, phase: e.target.value, base: BASES_PHASE(e.target.value)[0] })}>{Object.entries(PHASES).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
      <select value={n.beneficiaire} onChange={(e) => setN({ ...n, beneficiaire: e.target.value })}>{Object.entries(BENEF).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
      <select value={n.base} onChange={(e) => setN({ ...n, base: e.target.value })}>{BASES_PHASE(n.phase).map((k) => <option key={k} value={k}>{BASES[k]}</option>)}</select>
      {n.base === 'forfait' ? <input placeholder="Montant HT" inputMode="decimal" value={n.forfait} onChange={(e) => setN({ ...n, forfait: e.target.value })} style={{ width: 100 }} />
        : <input placeholder="%" inputMode="decimal" value={n.pourcentage} onChange={(e) => setN({ ...n, pourcentage: e.target.value })} style={{ width: 70 }} />}
      {n.base === 'gestion' && <input placeholder="Mois (défaut)" inputMode="decimal" value={n.mois} onChange={(e) => setN({ ...n, mois: e.target.value })} style={{ width: 100 }} />}
      <button className="btn plein" onClick={async () => { await agir('pilotage_regle_remu', { p_id: null, p_phase: n.phase, p_beneficiaire: n.beneficiaire, p_pourcentage: n.pourcentage === '' ? null : Number(n.pourcentage.replace(',', '.')),
        p_base: n.base, p_forfait: n.forfait === '' ? null : Number(n.forfait.replace(',', '.')), p_actif: true, p_supprimer: false, p_membre: qui || null, p_mois: n.mois === '' ? null : Number(n.mois.replace(',', '.')) }); setN(vide); }}>Ajouter</button>
    </div>}
    <h2 style={{ marginTop: 22 }}>Paramètres généraux</h2>
    <div className="table-wrap"><table><tbody>{params.map((p) => <tr key={p.cle}><td>{p.libelle}</td>
      <td><input style={{ width: 80 }} defaultValue={p.valeur} key={p.cle + p.valeur} disabled={!direction}
        onBlur={(e) => e.target.value !== String(p.valeur) && agir('pilotage_param_remu', { p_cle: p.cle, p_valeur: Number(e.target.value.replace(',', '.')) })} /></td></tr>)}</tbody></table></div>
    <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>
      <p>Bases : les honoraires viennent de Rivage, convertis en HT (÷ 1,2). Honoraires de gestion = loyer charges comprises × taux de gestion TTC ÷ 1,2, multiplié par le nombre de mois de la règle (à défaut, le paramètre général ; réduit dans la même proportion si le mandat est apporté par la direction).
        Les bases location et EDL ne sont connues qu’au bail signé : une ligne est calculée pour chaque bail signé (mise en location et relocations).</p>
      <p>Limite Rivage : seule la part locataire des honoraires d’état des lieux est transmise ; la part bailleur n’est pas détaillée (elle est comprise dans les honoraires bailleur).</p>
    </div>
  </>;
}

function Regle({ r, direction, agir }) {
  const [v, setV] = useState({ phase: r.phase, beneficiaire: r.beneficiaire, pourcentage: r.pourcentage ?? '', base: r.base, forfait: r.forfait ?? '', mois: r.mois ?? '' });
  const modifie = v.phase !== r.phase || v.beneficiaire !== r.beneficiaire || String(v.pourcentage) !== String(r.pourcentage ?? '') || v.base !== r.base || String(v.forfait) !== String(r.forfait ?? '') || String(v.mois) !== String(r.mois ?? '');
  const enreg = (actif, supprimer = false) => agir('pilotage_regle_remu', { p_id: r.id, p_phase: v.phase, p_beneficiaire: v.beneficiaire,
    p_pourcentage: v.pourcentage === '' ? null : Number(String(v.pourcentage).replace(',', '.')), p_base: v.base, p_forfait: v.forfait === '' ? null : Number(String(v.forfait).replace(',', '.')), p_actif: actif, p_supprimer: supprimer,
    p_membre: r.membre || null, p_mois: v.base === 'gestion' && v.mois !== '' ? Number(String(v.mois).replace(',', '.')) : null });
  if (!direction) return <tr style={{ opacity: r.actif ? 1 : 0.5 }}><td>{PHASES[r.phase]}</td><td>{BENEF[r.beneficiaire]}</td><td>{r.pourcentage ?? '—'}</td><td>{BASES[r.base]}</td><td>{r.base === 'gestion' ? (r.mois ?? 'défaut') : '—'}</td><td>{euro(r.forfait)}</td><td>{r.actif ? 'Oui' : 'Non'}</td><td></td></tr>;
  return <tr style={{ opacity: r.actif ? 1 : 0.5 }}>
    <td><select value={v.phase} onChange={(e) => setV({ ...v, phase: e.target.value, base: BASES_PHASE(e.target.value).includes(v.base) ? v.base : BASES_PHASE(e.target.value)[0] })}>{Object.entries(PHASES).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></td>
    <td><select value={v.beneficiaire} onChange={(e) => setV({ ...v, beneficiaire: e.target.value })}>{Object.entries(BENEF).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></td>
    <td>{v.base === 'forfait' ? '—' : <input style={{ width: 60 }} inputMode="decimal" value={v.pourcentage} onChange={(e) => setV({ ...v, pourcentage: e.target.value })} />}</td>
    <td><select value={v.base} onChange={(e) => setV({ ...v, base: e.target.value })}>{BASES_PHASE(v.phase).map((k) => <option key={k} value={k}>{BASES[k]}</option>)}</select></td>
    <td>{v.base === 'gestion' ? <input style={{ width: 60 }} placeholder="défaut" inputMode="decimal" value={v.mois} onChange={(e) => setV({ ...v, mois: e.target.value })} /> : '—'}</td>
    <td>{v.base === 'forfait' ? <input style={{ width: 80 }} inputMode="decimal" value={v.forfait} onChange={(e) => setV({ ...v, forfait: e.target.value })} /> : '—'}</td>
    <td><input type="checkbox" checked={r.actif} onChange={(e) => enreg(e.target.checked)} /></td>
    <td className="row" style={{ gap: 6 }}>{modifie && <button className="btn plein" onClick={() => enreg(r.actif)}>Enregistrer</button>}
      <button className="lien" onClick={() => window.confirm('Supprimer cette règle ?') && enreg(r.actif, true)}>Supprimer</button></td>
  </tr>;
}
