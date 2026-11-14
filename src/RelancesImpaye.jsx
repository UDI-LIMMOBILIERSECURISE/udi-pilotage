// Relances automatiques des impayés (163) : bloc du dossier d'impayé (étapes du mois, pause, mise en demeure à valider)
// et aperçu du mois dans l'onglet « À faire ce mois-ci » (ce qui part, ce qui est en pause, ce qui est écarté et pourquoi).
// Décisions de Nicolas du 13/11/2026 : le pilotage relance seul (Rivage coupé), SMS et mails automatiques, mise en demeure
// validée par Audrey, calendrier serré avant la déclaration Zelok. Délais et interrupteur : Règles de relance.
import React, { useEffect, useState } from 'react';
import { supabase, rpc } from './supabase.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const euro = (n) => (n == null ? '—' : Number(n).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €');
const ORIGINE = { virement: 'virement non reçu', rejet: 'prélèvement rejeté', prelevement: 'prélèvement non encaissé' };
const MARQUE = { fait: ['fait', '✓'], sautee: ['', '–'], due: ['alerte', '!'], erreur: ['alerte', '✗'], a_venir: ['', '•'], pause: ['', '‖'], annulee: ['', '–'] };

async function erreurFonction(data, error) {
  let msg = data?.error;
  if (!msg && error?.context?.json) { try { msg = (await error.context.json()).error; } catch { /* réponse illisible */ } }
  return msg || error?.message || 'Échec';
}

const heure = (d) => (d ? new Date(d).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }).replace(' ', ' à ') : '—');
// 166 : une ligne d'historique (envoi du pilotage ou changement de statut Rivage)
function LigneHistorique({ h }) {
  const MOYENS = { appel: 'appel', sms_portable: 'SMS du portable', mail: 'mail hors pilotage', courrier: 'courrier', recommande: 'recommandé', autre: 'autre moyen' };
  const quoi = h.source === 'rivage' ? h.texte
    : h.canal === 'note' ? `${h.etape === 'med' ? 'Mise en demeure' : 'Relance'} notée : ${MOYENS[h.moyen] || h.moyen}${h.par ? ' · ' + h.par : ''}${h.texte ? ' · ' + h.texte : ''}`
    : `${h.canal === 'sms' ? 'SMS' : 'Mail'} ${h.etape === 'med' ? '(mise en demeure)' : h.manuel ? 'à la main' : 'automatique'}${h.destinataire ? ' à ' + h.destinataire : ''}${h.par ? ' · ' + h.par : ''}`;
  const ko = h.statut === 'erreur';
  return <li className={'etape e-' + (ko ? 'alerte' : 'fait')} title={h.source === 'rivage' ? 'Information Rivage (statut du cycle d’impayé)' : (h.texte || '')}>
    <span className="etape-marque">{ko ? '✗' : h.source === 'rivage' ? 'R' : '✓'}</span>
    {heure(h.le)} · {quoi}{ko ? ' : non envoyé (' + (h.erreur || 'erreur') + ')' : h.statut !== 'transmis' ? ' : en cours' : ''}</li>;
}

// 166 : SMS à ce seul bail depuis la fiche (même texte et même envoi que la liste des relances)
function SmsBail({ bail, fini }) {
  const [texte, setTexte] = useState(SMS_DEFAUT);
  const [ap, setAp] = useState(null);
  const [msg, setMsg] = useState('');
  const [encours, setEncours] = useState(false);
  const voir = async () => { setMsg(''); try { setAp((await rpc('pilotage_relances_sms_textes', { p_baux: [bail], p_texte: texte }))[0]); } catch (e) { setMsg(e.message); } };
  const envoyer = async () => {
    setEncours(true); setMsg('');
    const { data, error } = await supabase.functions.invoke('pilotage-sms', { body: { bail, texte: ap.texte,
      cle: `rim:${bail}:${new Date().toISOString().slice(0, 10)}`, etape: 'sms_manuel', detail: 'Relance impayé envoyée à la main' } });
    setEncours(false);
    if (error || !data?.ok) { setMsg(await erreurFonction(data, error)); return; }
    fini(`SMS envoyé (${(data.resultats || []).filter((r) => r.ok).length}).`);
  };
  return <div style={{ marginTop: 8 }}>
    <textarea rows="3" style={{ width: '100%' }} value={texte} onChange={(e) => { setTexte(e.target.value); setAp(null); }} aria-label="Texte du SMS de relance" />
    {msg && <div className="err">{msg}</div>}
    {!ap ? <button className="btn plein" onClick={voir}>Voir le SMS avant l’envoi</button> : <>
      <div className="muted" style={{ fontSize: 13, margin: '4px 0' }}>{ap.portables ? `${ap.portables} portable${ap.portables > 1 ? 's' : ''} dans Rivage` : 'Aucun portable dans Rivage : pas d’envoi possible'}
        {(ap.manquants || []).length ? ` · champ non rempli : ${ap.manquants.join(', ')}` : ''}<br />{ap.texte}</div>
      <div className="row" style={{ gap: 8 }}><button className="btn plein" disabled={encours || !ap.portables || (ap.manquants || []).length > 0} onClick={envoyer}>{encours ? 'Envoi…' : 'Envoyer le SMS'}</button>
        <button className="lien" onClick={() => setAp(null)}>Modifier</button></div></>}
  </div>;
}

function texteEtape(e) {
  const quand = e.statut === 'fait' ? `fait le ${date(e.fait_le)}` : e.statut === 'sautee' ? 'non envoyé (étape suivante déjà due)'
    : e.statut === 'erreur' ? 'non envoyé : voir l’alerte' : e.statut === 'annulee' ? 'annulé' : e.statut === 'pause' ? 'en pause'
    : e.statut === 'due' ? (e.auto ? 'part ce matin' : 'à faire depuis le ' + date(e.le)) : 'prévu le ' + date(e.le);
  return `${e.libelle}${e.auto ? '' : ' (Audrey)'} · ${quand}`;
}

// Bloc du dossier d'impayé
export function RelancesBail({ bail, dossier, apres }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [motif, setMotif] = useState('');
  const [pause, setPause] = useState(false);
  const [med, setMed] = useState(null);
  const [envoi, setEnvoi] = useState('');
  const [sms, setSms] = useState(false);
  const [noter, setNoter] = useState(null);
  const [ok, setOk] = useState('');
  const charger = () => rpc('pilotage_relances_impaye', { p_bail: bail }).then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, [bail]);
  if (!d) return err ? <div className="err">{err}</div> : null;
  const c = d.cycle && !d.cycle.clos_le ? d.cycle : null;
  const agir = async (fn, args) => { setErr(''); try { await rpc(fn, args); setPause(false); setMotif(''); await charger(); apres && apres(); } catch (e) { setErr(e.message); } };
  const preparerMed = async () => { setErr(''); try { setMed(await rpc('pilotage_relance_impaye_med', { p_bail: bail })); } catch (e) { setErr(e.message); } };
  const envoyerMed = async () => {
    setEnvoi('Envoi…'); setErr('');
    const { data, error } = await supabase.functions.invoke('pilotage-mail', { body: { bail, to: med.to, objet: med.objet, corps: med.corps,
      cle: med.cle, etape: 'med', detail: 'Mise en demeure envoyée par mail' } });
    if (error || !data?.ok) { setEnvoi(''); setErr(await erreurFonction(data, error)); return; }
    setEnvoi('Mail envoyé. Envoie aussi la lettre recommandée avec le même texte.'); await charger(); apres && apres();
  };
  const medDue = c && (c.etapes || []).some((e) => e.etape === 'med' && e.statut === 'due');
  return <div className="panneau" style={{ margin: '10px 0' }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <b>Relances</b>
      <span className="row" style={{ gap: 8 }}>{d.peut_sms && !sms && <button className="btn" onClick={() => { setSms(true); setNoter(null); setOk(''); }}>Envoyer un SMS</button>}
        {d.peut && dossier && !noter && <button className="btn gris" onClick={() => { setNoter({ quoi: 'relance', moyen: 'appel', note: '' }); setSms(false); setOk(''); }}>Noter une relance faite</button>}
        <span className="muted" style={{ fontSize: 12 }}>automatiques {d.actif ? 'actives' : 'désactivées'}</span></span>
    </div>
    {err && <div className="err">{err}</div>}
    {ok && <div className="mini-alerte normale" role="status">✓ {ok}</div>}
    {noter && <div className="row" style={{ gap: 8, flexWrap: 'wrap', marginTop: 8, alignItems: 'flex-end' }}>
      <label className="champ-imp"><span>Quoi</span><select value={noter.quoi} onChange={(e) => setNoter({ ...noter, quoi: e.target.value })}>
        <option value="relance">Relance</option><option value="med">Mise en demeure</option></select></label>
      <label className="champ-imp"><span>Par</span><select value={noter.moyen} onChange={(e) => setNoter({ ...noter, moyen: e.target.value })}>
        {[['appel', 'Appel'], ['sms_portable', 'SMS du portable'], ['mail', 'Mail hors pilotage'], ['courrier', 'Courrier'], ['recommande', 'Recommandé'], ['autre', 'Autre']].map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select></label>
      <label className="champ-imp" style={{ flex: '1 1 220px' }}><span>Note (facultatif)</span><input value={noter.note} onChange={(e) => setNoter({ ...noter, note: e.target.value })} placeholder="Ex. promet de payer vendredi" /></label>
      <button className="btn plein" onClick={async () => { setErr(''); try { await rpc('pilotage_relance_noter', { p_dossier: dossier, p_quoi: noter.quoi, p_moyen: noter.moyen, p_note: noter.note });
        setNoter(null); setOk('Relance notée.'); await charger(); apres && apres(); } catch (e) { setErr(e.message); } }}>Enregistrer</button>
      <button className="lien" onClick={() => setNoter(null)}>Annuler</button>
    </div>}
    {sms && <SmsBail bail={bail} fini={async (m) => { setSms(false); setOk(m); await charger(); apres && apres(); }} />}
    {(d.historique || []).length > 0 ? <ul className="etapes" style={{ flexDirection: 'column', gap: 2, marginTop: 6 }} aria-label="Relances déjà faites">
        {d.historique.slice(0, 12).map((h, i) => <LigneHistorique key={i} h={h} />)}</ul>
      : <p className="muted" style={{ margin: '4px 0' }}>Aucune relance envoyée depuis 3 mois (ni par le pilotage, ni par Rivage).</p>}
    {!c && d.candidat?.motif && <p className="muted" style={{ margin: '4px 0', fontSize: 12 }}>Relances automatiques : {d.candidat.motif}.</p>}
    {c && <>
      <div className="muted" style={{ fontSize: 13, marginTop: 6 }}><b>Relances automatiques</b> depuis le {date(c.j0)} ({ORIGINE[c.origine] || c.origine}{c.rejet_le ? ' le ' + date(c.rejet_le) : ''}), dette de départ {euro(c.dette_initiale)}.
        {c.pause_le ? ` En pause depuis le ${date(c.pause_le)}${c.pause_par ? ' (' + c.pause_par + ')' : ''} : ${c.pause_motif}.` : ''}</div>
      <ul className="etapes" style={{ flexDirection: 'column', gap: 2 }} aria-label="Étapes des relances automatiques">
        {(c.etapes || []).map((e) => { const [cl, m] = MARQUE[e.statut] || ['', '•'];
          return <li key={e.etape} className={'etape e-' + cl} title={e.detail || ''}><span className="etape-marque">{m}</span>{texteEtape(e)}</li>; })}
      </ul>
      {d.peut && <div className="row" style={{ gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
        {medDue && !med && <button className="btn plein" onClick={preparerMed}>Préparer la mise en demeure</button>}
        {c.pause_le ? <button className="btn" onClick={() => agir('pilotage_relance_impaye_pause', { p_bail: bail, p_pause: false, p_motif: null })}>Reprendre les relances</button>
          : !pause ? <button className="btn gris" onClick={() => setPause(true)}>Mettre en pause</button>
            : <><input value={motif} onChange={(e) => setMotif(e.target.value)} placeholder="Motif (plan d’apurement, erreur Rivage…)" style={{ flex: '1 1 220px' }} aria-label="Motif de la pause" />
              <button className="btn plein" disabled={!motif.trim()} onClick={() => agir('pilotage_relance_impaye_pause', { p_bail: bail, p_pause: true, p_motif: motif })}>Confirmer la pause</button>
              <button className="lien" onClick={() => setPause(false)}>Annuler</button></>}
      </div>}
      {med && <div style={{ marginTop: 10 }}>
        {(med.manquants || []).length > 0 && <div className="err">Champs non remplis : {med.manquants.join(', ')}</div>}
        <div className="muted" style={{ fontSize: 13 }}>À : {(med.to || []).join(', ') || 'aucune adresse e-mail du locataire dans Rivage'}
          {(med.garants || []).length > 0 ? ` · garant(s) : ${med.garants.map((g) => g.nom).join(', ')} (à informer par courrier, pas en copie du mail)` : ''}</div>
        <label className="champ-imp" style={{ display: 'block' }}><span>Objet</span><input value={med.objet || ''} onChange={(e) => setMed({ ...med, objet: e.target.value })} /></label>
        <textarea rows="14" style={{ width: '100%' }} value={med.corps || ''} onChange={(e) => setMed({ ...med, corps: e.target.value })} aria-label="Texte de la mise en demeure" />
        <div className="row" style={{ gap: 8 }}>
          <button className="btn plein" disabled={!!envoi || !(med.to || []).length} onClick={envoyerMed}>Envoyer le mail</button>
          <button className="btn gris" onClick={() => navigator.clipboard?.writeText(med.corps || '')}>Copier le texte (lettre recommandée)</button>
          <button className="lien" onClick={() => { setMed(null); setEnvoi(''); }}>Fermer</button>
        </div>
        {envoi && <p className="muted">{envoi}</p>}
      </div>}
    </>}
  </div>;
}

// Aperçu du mois (onglet « À faire ce mois-ci »)
// 165 (13/11, Nicolas : « on peut tout sélectionner ou juste un et envoyer les SMS, le message est éditable ») : envoi manuel des SMS de
// relance, sans attendre les relances automatiques. Texte de départ ci-dessous, modifiable avant l'envoi ; {nom} est remplacé pour chaque
// locataire, {dette}, {adresse}, {constat_sms}… pour chaque bail. Envoi par pilotage-sms (Twilio, UDI GESTION), noté dans le dossier.
// Recherche (13/11, Nicolas) : sans accents ni majuscules, tous les mots tapés, sur le nom, le n° de bail et la dette
const sansAccents = (t) => String(t || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
const trouve = (l, q) => { if (!q) return true; const h = sansAccents([l.locataires, l.reference, 'bail ' + (l.reference || ''), euro(l.dette), l.dette].join(' '));
  return sansAccents(q).split(/\s+/).filter(Boolean).every((m) => h.includes(m)); };
const SMS_DEFAUT = 'Bonjour {nom}, {constat_sms}. Il reste {dette} à régler pour le logement {adresse}. Merci de faire le virement aujourd’hui ou de nous contacter si vous rencontrez une difficulté. UDI Gestion';

async function erreurEnvoi(data, error) { return erreurFonction(data, error); }

export function ApercuRelances() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [sel, setSel] = useState(() => new Set());
  const [texte, setTexte] = useState('');
  const [apercus, setApercus] = useState(null);
  const [etat, setEtat] = useState({});
  const [encours, setEncours] = useState(false);
  const [q, setQ] = useState('');
  const [filtre, setFiltre] = useState('tous');
  const charger = () => rpc('pilotage_relances_impayes_apercu').then(setD).catch((e) => setErr(e.message));
  useEffect(() => {
    charger();
    setTexte((t) => t || SMS_DEFAUT);   // pas le modèle automatique (J0), qui renvoie au mail envoyé en même temps
  }, []);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return null;
  const lignes = d.lignes || [];
  const vues = lignes.filter((l) => trouve(l, q) && (filtre === 'tous' || (filtre === 'jamais' ? !l.envois && !l.rivage_relance_le : (l.envois || l.rivage_relance_le))));
  const enCours = vues.filter((l) => l.cycle && !l.cycle.pause_motif);
  const pause = vues.filter((l) => l.cycle?.pause_motif);
  const relancables = vues.filter((l) => !l.cycle && !l.motif);
  const ecartes = vues.filter((l) => !l.cycle && l.motif);
  const basculer = (id) => { setApercus(null); setSel((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; }); };
  // 166 : « tout sélectionner » laisse de côté les baux relancés par le pilotage depuis moins de 48 h (cochables à la main)
  const tous = (liste, oui) => { setApercus(null); setSel((s) => { const n = new Set(s); liste.forEach((l) => (oui ? (!l.envois_48h && n.add(l.bail_id)) : n.delete(l.bail_id))); return n; }); };
  const nom = (id) => lignes.find((l) => l.bail_id === id)?.locataires || id;
  const verifier = async () => {
    setErr('');
    try { setApercus(await rpc('pilotage_relances_sms_textes', { p_baux: [...sel], p_texte: texte })); } catch (e) { setErr(e.message); }
  };
  const envoyer = async () => {
    setEncours(true); setErr('');
    const jour = new Date().toISOString().slice(0, 10);
    for (const a of apercus || []) {
      if (!a.portables || (a.manquants || []).length || etat[a.bail_id]?.ok) continue;
      setEtat((e) => ({ ...e, [a.bail_id]: { txt: 'Envoi…' } }));
      const { data, error } = await supabase.functions.invoke('pilotage-sms', { body: { bail: a.bail_id, texte: a.texte,
        cle: `rim:${a.bail_id}:${jour}`, etape: 'sms_manuel', detail: 'Relance impayé envoyée à la main' } });
      if (error || !data?.ok) { const m = await erreurEnvoi(data, error); setEtat((e) => ({ ...e, [a.bail_id]: { ko: true, txt: m } })); }
      else setEtat((e) => ({ ...e, [a.bail_id]: { ok: true, txt: `envoyé (${(data.resultats || []).filter((r) => r.ok).length} SMS)` } }));
    }
    setEncours(false);
  };
  const ligne = (l, info, cochable = true) => <label key={l.bail_id} className="row" style={{ justifyContent: 'space-between', gap: 8, padding: '3px 0', borderBottom: '1px solid var(--line)', cursor: cochable ? 'pointer' : 'default' }}>
    <span>{cochable && <input type="checkbox" checked={sel.has(l.bail_id)} onChange={() => basculer(l.bail_id)} style={{ marginRight: 6 }} aria-label={'Sélectionner ' + (l.locataires || l.bail_id)} />}
      {l.locataires || l.bail_id}{l.reference ? <span className="muted"> · bail {l.reference}</span> : null} · {euro(l.dette)} · {ORIGINE[l.origine] || l.origine}</span>
    <span className="muted" style={{ fontSize: 12, textAlign: 'right' }}>{etat[l.bail_id] ? <b style={{ color: etat[l.bail_id].ko ? 'var(--red)' : 'var(--teal)' }}>{etat[l.bail_id].txt}</b>
      : <>{dernier(l)}{dernier(l) ? <br /> : null}{info}</>}</span></label>;
  const dernier = (l) => {
    const p = l.derniere;
    const pilot = l.envois ? `${l.envois} envoi${l.envois > 1 ? 's' : ''} ce mois` + (p && p.source === 'pilotage' ? ` · dernier : ${p.canal === 'sms' ? 'SMS' : 'mail'} le ${heure(p.le)}` : '') : '';
    const riv = l.rivage_relance_le ? `Rivage a relancé le ${heure(l.rivage_relance_le)}` : '';
    const txt = [pilot, riv].filter(Boolean).join(' · ');
    return txt ? <b style={{ color: l.envois_48h ? '#B45309' : 'var(--teal)' }}>{l.envois_48h ? '⚠ relancé il y a moins de 48 h · ' : ''}{txt}</b> : '';
  };
  const tousCoches = (liste) => liste.some((l) => !l.envois_48h) && liste.every((l) => l.envois_48h || sel.has(l.bail_id));
  const entete = (titre, liste) => <summary style={{ cursor: 'pointer' }}><b>{titre} ({liste.length})</b>
    {liste.length > 0 && <button className="lien" onClick={(e) => { e.preventDefault(); tous(liste, !tousCoches(liste)); }}>{tousCoches(liste) ? 'tout désélectionner' : 'tout sélectionner'}</button>}</summary>;
  const prets = (apercus || []).filter((a) => a.portables && !(a.manquants || []).length && !etat[a.bail_id]?.ok);
  return <section className="card" style={{ marginBottom: 14 }}>
    <h2 style={{ fontSize: 17, margin: '0 0 6px' }}>Relances des impayés</h2>
    {err && <div className="banner">{err}</div>}
    <p className="muted" style={{ margin: '0 0 6px' }}>Coche un, plusieurs ou tous les locataires, ajuste le message, puis envoie : SMS de UDI GESTION aux portables connus dans Rivage, noté dans le dossier d’impayé.
      {d.actif ? ' Relances automatiques actives en plus (chaque matin vers 9 h).' : ' Relances automatiques (sans clic) : désactivées, voir Règles de relance.'}</p>
    {lignes.length > 0 && <div className="row" style={{ gap: 8, margin: '4px 0 8px' }}>
      <input className="recherche" type="search" value={q} onChange={(e) => setQ(e.target.value)} style={{ flex: '1 1 260px', maxWidth: 460 }}
        placeholder="Rechercher un locataire : nom, n° de bail, montant…" aria-label="Rechercher un locataire dans les relances" />
      <span className="row" style={{ gap: 4 }} role="group" aria-label="Filtrer les relances">
        {[['tous', 'Tous'], ['jamais', 'Jamais relancés'], ['deja', 'Déjà relancés']].map(([k, t]) =>
          <button key={k} className={'btn' + (filtre === k ? ' plein' : '')} style={{ padding: '4px 10px' }} onClick={() => setFiltre(k)}>{t}</button>)}</span>
      {(q || filtre !== 'tous') && <span className="muted" style={{ fontSize: 12 }}>{vues.length} sur {lignes.length}{sel.size ? ` · ${sel.size} coché(s) en tout` : ''}</span>}
    </div>}
    {enCours.length > 0 && <details open>{entete('Relances automatiques en cours', enCours)}
      {enCours.map((l) => ligne(l, l.cycle.prochaine ? `${l.cycle.prochaine.libelle} : ${l.cycle.prochaine.statut === 'erreur' ? 'non envoyé' : date(l.cycle.prochaine.le)}` : 'plus rien de prévu ce mois-ci'))}</details>}
    {pause.length > 0 && <details open={!!q}>{entete('En pause', pause)}{pause.map((l) => ligne(l, l.cycle.pause_motif))}</details>}
    {relancables.length > 0 && <details open>{entete('Impayés du mois', relancables)}
      {relancables.map((l) => ligne(l, 'impayé depuis le ' + date(l.j0)))}</details>}
    {ecartes.length > 0 && <details open={!!q}>{entete('Dettes suivies à la main (anciennes, en procédure, plus de 2 mois)', ecartes)}{ecartes.map((l) => ligne(l, l.motif))}</details>}
    {!lignes.length && <p className="muted">Aucun bail en dette au-delà du seuil.</p>}
    {lignes.length > 0 && q && !vues.length && <p className="muted">Aucun locataire ne correspond à « {q} ».</p>}

    {sel.size > 0 && <div className="panneau" style={{ marginTop: 10, position: 'sticky', bottom: 8, zIndex: 5, background: '#fff', boxShadow: '0 -6px 20px rgba(16,24,40,.15)' }}>
      <b>SMS à {sel.size} bail{sel.size > 1 ? 'x' : ''}</b>
      <textarea rows="4" style={{ width: '100%', marginTop: 6 }} value={texte} onChange={(e) => { setTexte(e.target.value); setApercus(null); }} aria-label="Texte du SMS" />
      <div className="muted" style={{ fontSize: 12 }}>{texte.length} caractères · champs remplis pour chaque bail : {'{nom}'} (chaque locataire), {'{dette}'}, {'{adresse}'}, {'{constat_sms}'}, {'{reference}'}.</div>
      {!apercus ? <button className="btn plein" style={{ marginTop: 6 }} onClick={verifier}>Voir les SMS avant l’envoi</button> : <>
        <div className="stack" style={{ gap: 4, maxHeight: 260, overflow: 'auto', marginTop: 6 }}>
          {apercus.map((a) => <div key={a.bail_id} style={{ fontSize: 13, borderBottom: '1px solid var(--line)', padding: '4px 0' }}>
            <b>{nom(a.bail_id)}</b>{!a.portables ? <span style={{ color: 'var(--red)' }}> · aucun portable dans Rivage : pas d’envoi</span>
              : (a.manquants || []).length ? <span style={{ color: 'var(--red)' }}> · champ non rempli : {a.manquants.join(', ')}</span> : <span className="muted"> · {a.portables} portable{a.portables > 1 ? 's' : ''}</span>}
            <div className="muted">{a.texte}</div></div>)}
        </div>
        <div className="row" style={{ gap: 8, marginTop: 6 }}>
          <button className="btn plein" disabled={encours || !prets.length} onClick={envoyer}>{encours ? 'Envoi en cours…' : `Envoyer ${prets.length} SMS`}</button>
          <button className="lien" disabled={encours} onClick={() => setApercus(null)}>Modifier</button>
          <button className="lien" disabled={encours} onClick={() => { setSel(new Set()); setApercus(null); setEtat({}); charger(); }}>Terminer</button>
        </div></>}
    </div>}
  </section>;
}
