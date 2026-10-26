import { nature, Parties, Carte, texteRecherche, correspond, normaliser } from './cartes.jsx';
// Suivi des baux et obligations : contrôle d'entrée, échéances et congés, suivis récurrents, paliers, actes.
import React, { useEffect, useMemo, useState } from 'react';
import { supabase, rpc } from './supabase.js';
import { ResumeIA, Tuiles, Filtres } from './App.jsx';
import { Compteurs } from './SuiviMandat.jsx';
import { Circuit } from './Circuit.jsx';
import { preparer, SMS, nomSms, smsFactures, lienGmail, TYPES_BAIL, DECISIONS, CONSEQUENCES } from './mails.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const auj = () => new Date().toISOString().slice(0, 10);
const jours = (d) => (d ? Math.round((new Date(d) - new Date(auj())) / 86400000) : null);
const SEV = { critique: 'Critique', haute: 'Haute', normale: 'Normale' };
const BLOCS = { pieces: 'Pièces du dossier', rivage: 'Croisement avec Rivage', clauses: 'Clauses et suivis' };
export const NATURES = {
  assurance: 'Assurance', entretien: 'Entretien d\'équipement', compteur: 'Relevé de compteurs', garantie: 'Expiration de garantie', caution: 'Fin d\'engagement de la caution',
  dpe: 'Validité du DPE', tsb: 'Taxe sur les bureaux', surprime: 'Surprime d\'assurance', charges_regul: 'Régularisation des charges', etat_travaux: 'État prévisionnel des travaux',
  tertiaire: 'Décret tertiaire (OPERAT)', destination: 'Contrôle de la destination', dg_ajust: 'Ajustement du dépôt de garantie',
};
const PERIODE = { assurance: 12, entretien: 12, compteur: 6, tsb: 12, surprime: 12, charges_regul: 12, etat_travaux: 36, tertiaire: 12, destination: 12, dg_ajust: 12 };
const ETATS = {
  a_venir: 'À venir', a_informer: 'Bailleur à informer', attente_bailleur: 'Réponse du bailleur attendue', reconduit: 'Reconduit (sans réponse)', decide: 'Décision prise',
  conge_a_delivrer: 'Congé à délivrer', conge_en_cours: 'Congé en préparation', conge_depose: 'Congé déposé dans Rivage, à enregistrer', conge_delivre: 'Congé délivré', hors_delai: 'Délai dépassé', fin_auto: 'Fin automatique', info: 'Contrat à vérifier',
  derogatoire_terme: 'Opposition urgente', derogatoire_depasse: 'Dérogatoire dépassé', incomplet: 'Fiche incomplète',
};
// Catégorie Rivage où déposer le justificatif d'un suivi : le dépôt fait passer le suivi à l'échéance suivante (027)
const CATEG_JUSTIF = { assurance: 'Attestation d’assurance habitation', entretien: 'Attestation d’entretien de chaudière ou Contrats d’entretien', dpe: 'Diagnostic de Performance Énergétique',
  garantie: 'Acte de caution ou Documents de caution', caution: 'Acte de caution ou Documents de caution', charges_regul: 'Avis de régularisation de charges' };
const CANAL = { mail_locataire: 'Mail au locataire', mail_bailleur: 'Mail au bailleur', sms: 'SMS au locataire', sms_rivage: 'SMS au locataire', lrar: 'Recommandé', tache: 'Tâche' };

function useEmail() {
  const [e, setE] = useState('');
  useEffect(() => { supabase.auth.getSession().then(({ data }) => setE(data?.session?.user?.email || '')); }, []);
  return e;
}

export default function SuiviBaux({ moi }) {
  const [infos, setInfos] = useState({});
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [filtre, setFiltre] = useState('traiter');
  const [sel, setSel] = useState(null);
  const [cherche, setCherche] = useState('');
  const charger = () => { rpc('pilotage_infos_cartes').then((x) => setInfos(x?.baux || {})).catch(() => {}); return rpc('pilotage_baux').then(setD).catch((e) => setErr(e.message)); };
  useEffect(() => { charger(); }, []);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;

  const baux = d.baux;
  const aFaire = (b) => !!b.echeance?.action || b.obligations.some((o) => o.a_faire || o.en_retard);
  const grave = (b) => b.echeance?.gravite === 'critique' || b.obligations.some((o) => o.gravite === 'critique') || !!b.echeance?.alerte_derogatoire;
  // Seuls les baux nouveaux (après la date de référence de la reprise) passent par le contrôle d'entrée ; le stock va à l'audit (Reprise)
  const aValider = (b) => !!b.controle?.soumis && !b.controle?.go_le;
  const commercial = (b) => ['commercial', 'derogatoire', 'professionnel'].includes(b.echeance?.type);
  const dans12 = (b) => { const j = jours(b.echeance?.echeance); return j != null && j <= 365; };
  const tests = { traiter: (b) => aFaire(b) || grave(b), valider: aValider, douze: dans12, commerciaux: commercial, tous: () => true };
  const q = normaliser(cherche);
  // Recherche sur tout : n° de bail et de mandat, locataires, bailleurs, adresse, type de bien, téléphones, e-mails ; elle porte sur tous les baux, quel que soit le filtre
  const vus = (q ? baux : baux.filter(tests[filtre])).filter((b) => !q || correspond(texteRecherche(b.reference, b.locataires, b.adresse, b.bailleur, b.mandat,
    infos[b.bail_id]?.adresse, nature(infos[b.bail_id]?.nature), infos[b.bail_id]?.parties), q));
  const s = baux.find((b) => b.bail_id === sel);

  return <>
    <div className="entete"><div><h1>Suivi des baux et obligations</h1>
      <p className="sub">Au {date(auj())} · contrôle d’entrée, échéances et congés, relances (assurance, entretien, compteurs, garanties, taxes), paliers et actes.</p></div></div>
    {err && <div className="banner">{err}</div>}
    <Tuiles items={[[baux.filter(aFaire).length, 'Actions à faire'], [baux.filter(grave).length, 'Urgent', true],
      [baux.filter(aValider).length, 'Contrôle d’entrée à valider', true], [baux.filter(dans12).length, 'Échéance dans les 12 mois'], [baux.filter(commercial).length, 'Baux commerciaux']]} />
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <Filtres val={filtre} set={setFiltre} items={[['traiter', 'À traiter', baux.filter(tests.traiter).length], ['valider', 'Contrôle à valider', baux.filter(aValider).length],
        ['douze', 'Échéance < 12 mois', baux.filter(dans12).length], ['commerciaux', 'Commerciaux', baux.filter(commercial).length], ['tous', 'Tous', baux.length]]} />
      <input className="recherche" placeholder="Rechercher : nom, adresse, téléphone, e-mail, n° de bail" value={cherche} onChange={(e) => setCherche(e.target.value)} aria-label="Rechercher un bail" />
    </div>
    {s ? <section className="panneau" style={{ marginTop: 8 }}>
      <button className="btn" onClick={() => setSel(null)}>← Retour à la liste</button>
      <div style={{ maxWidth: 980, marginTop: 10 }}><DossierBail b={s} peut={d.peut} moi={moi} apres={charger} /></div>
    </section> : <>
      <div className="grille-cartes grille-baux">{vus.map((b) => {
        const e = b.echeance || {}; const g = grave(b) ? 'critique' : aFaire(b) ? 'haute' : 'normale';
        const prochaine = e.action_libelle || b.obligations.find((o) => o.a_faire)?.a_faire?.libelle;
        return <Carte key={b.bail_id} className={'kcarte ' + (sel === b.bail_id ? 'sel ' : '') + g} onClick={() => { setSel(b.bail_id); window.scrollTo({ top: 0, behavior: 'smooth' }); }}>
          <div className="row" style={{ justifyContent: 'space-between' }}>
            <span className="mono muted">Bail {b.reference} · {TYPES_BAIL[e.type] || 'type ?'}{e.type && !e.type_confirme ? ' (suggéré)' : ''}</span>
            {b.controle?.go_le ? <span className="sev normale">GO</span> : b.controle?.soumis ? <span className="sev haute">À valider</span> : <span className="muted" title="Bail repris : contrôlé par l’audit (onglet Reprise)">Reprise</span>}
          </div>
          <div className="kcarte-titre">{b.locataires || '—'}</div>
          <div className="muted">{nature(infos[b.bail_id]?.nature)}{infos[b.bail_id]?.surface ? ` · ${infos[b.bail_id].surface} m²` : ''} · {infos[b.bail_id]?.adresse || b.adresse}</div>
          <Parties titre="Locataires" liste={infos[b.bail_id]?.parties?.locataires} />
          <Parties titre="Bailleurs" liste={infos[b.bail_id]?.parties?.bailleurs} max={1} />
          <div className="grid2" style={{ marginTop: 6 }}>
            <span className="muted">Bailleur</span><span>{b.bailleur || '—'}</span>
            <span className="muted">Échéance</span><span>{e.echeance ? date(e.echeance) + (e.mode === 'prolongation' ? ' (prolongation)' : '') : '—'}</span>
            <span className="muted">Situation</span><span>{ETATS[e.etat] || e.etat || '—'}</span>
          </div>
          {prochaine && <div style={{ marginTop: 6, fontSize: 13, color: g === 'critique' ? 'var(--red)' : 'var(--amber)' }}>→ {prochaine}</div>}
          {!b.controle?.go_le && b.controle?.restant > 0 && <div className="muted" style={{ marginTop: 4 }}>{b.controle.restant} point(s) de contrôle à traiter</div>}
        </Carte>; })}</div>
      {q && <div className="muted" style={{ margin: '6px 0' }}>{vus.length} bail(s) trouvé(s) sur tous les baux.</div>}
      {!vus.length && <div className="card">Aucun bail avec ce filtre.</div>}
    </>}
  </>;
}

// ===== Détail d'un bail =====

export function DossierBail({ b, peut, moi, apres }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [mail, setMail] = useState(null); // { m, etape: { cle, etape, detail } }
  const [parametrer, setParametrer] = useState(false);
  const email = useEmail();
  const charger = () => rpc('pilotage_bail_dossier', { p_bail: b.bail_id }).then(setD).catch((e) => setErr(e.message));
  useEffect(() => { setD(null); setMail(null); setParametrer(false); charger(); }, [b.bail_id]);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;

  // Après chaque action, le calcul du bail est refait tout de suite pour la liste (cache 032)
  const agir = async (fn, args) => { setErr(''); try { await rpc(fn, args); await rpc('pilotage_bail_rafraichir', { p_bail: b.bail_id }).catch(() => {}); await charger(); apres(); } catch (e) { setErr(e.message); } };
  const ech = d.echeance || {}; const fiche = d.fiche || {};
  const ctx = { bail: b, fiche, ech, contacts: d.contacts, moi: { prenom: moi.prenom, email } };
  // Relances, suivis, échéance, paliers et actes : pilotés par la gestion. Le commercial (circuit) ne garde la main que sur le contrôle d'entrée.
  const gere = peut && (!moi?.role || ['direction', 'superviseur', 'gestionnaire'].includes(moi.role));
  const ouvrirMail = (code, extra, etape) => {
    const m = preparer(code, { ...ctx, ...extra });
    if (m) setMail({ m, etape });
  };
  // Journal : étapes de suivi + écarts bail / Rivage justifiés (cause et justificatif).
  const journal = [...(d.journal || []), ...((d.controle?.items) || [])
    .filter((i) => i.repondu && i.auto === 'anomalie' && i.statut === 'ok' && i.commentaire)
    .map((i) => ({ le: i.le, detail: `Écart justifié · ${i.libelle} : ${i.detail} · justification : ${i.commentaire}`, par: i.par }))]
    .sort((x, y) => new Date(y.le) - new Date(x.le));
  // Deux modes : contrôle d'entrée tant qu'il n'est pas bouclé ; ensuite synthèse du bail, avec « Modifier le paramétrage ».
  // Contrôle non requis (habitation antérieure au contrôle d'entrée) : synthèse directement.
  const soumis = ['commercial', 'derogatoire', 'professionnel'].includes(ech.type) || (b.debut && b.debut >= '2026-10-16');
  const synthese = !parametrer && (!!d.controle?.go_le || !soumis);
  const etapeFaite = (cle, etape, detail) => agir('pilotage_suivi_etape', { p_cle: cle, p_etape: etape, p_detail: detail, p_annuler: false });

  // Actions du moment : échéance + obligations
  const actions = [];
  if (ech.action) actions.push({ k: 'ech', grav: ech.gravite, libelle: ech.action_libelle, ech: true });
  (d.obligations || []).filter((o) => o.actif && o.a_faire).forEach((o) => actions.push({ k: 'o' + o.id, grav: o.gravite, libelle: o.a_faire.libelle, ob: o }));

  return <>
    <div className="muted">Bail {b.reference} · {TYPES_BAIL[ech.type] || 'type à préciser'}{ech.type && !ech.type_confirme ? ' (suggéré, à confirmer)' : ''}</div>
    <h2>{b.locataires}</h2>
    <div className="muted">{b.adresse} · {b.mandat} · Bailleur : {b.bailleur || '—'}</div>
    {err && <div className="banner">{err}</div>}
    <ResumeIA type="bail" id={b.bail_id} />
    {soumis && <Circuit objet="bail" id={b.bail_id} apres={async () => { await rpc('pilotage_bail_rafraichir', { p_bail: b.bail_id }).catch(() => {}); await charger(); apres && apres(); }} />}
    {ech.alerte_derogatoire && <div className="mini-alerte critique">{ech.alerte_derogatoire}</div>}

    <h3>À faire maintenant</h3>
    {!actions.length && <p className="muted">Rien à faire aujourd’hui sur ce bail.</p>}
    {actions.map((a) => <div key={a.k} className={'mini-alerte ' + (a.grav || 'normale')}>
      <b>{SEV[a.grav] || 'Normale'}</b> · {a.libelle}
      {a.ob && <div className="muted">{a.ob.libelle} · échéance le {date(a.ob.prochaine)} · {CANAL[a.ob.a_faire.canal]} prévu le {date(a.ob.a_faire.date)}</div>}
      {a.ob && CATEG_JUSTIF[a.ob.nature] && <div className="muted" style={{ fontSize: 12 }}>Justificatif reçu : le déposer dans Rivage, catégorie « {CATEG_JUSTIF[a.ob.nature]} » (sur le bail ou le lot) ; le suivi passe alors à l’échéance suivante.</div>}
      {gere && <div className="row" style={{ marginTop: 6 }}>
        {a.ech && ech.action === 'informer' && <button className="btn plein" onClick={() => ouvrirMail('echeance_info', {}, { cle: ech.cle, etape: 'informe', detail: 'Bailleur informé' })}>Préparer le mail au bailleur</button>}
        {a.ech && ech.action === 'relancer' && <button className="btn plein" onClick={() => ouvrirMail('echeance_relance', {}, { cle: ech.cle, etape: 'relance', detail: 'Bailleur relancé' })}>Préparer la relance</button>}
        {a.ech && ech.action === 'lrar_silence' && <button className="btn plein" onClick={() => ouvrirMail('echeance_lrar', {}, { cle: ech.cle, etape: 'lrar', detail: 'LRAR envoyée au bailleur' })}>Préparer la LRAR</button>}
        {a.ech && ['fin_auto', 'verifier_contrat'].includes(ech.action) && <button className="btn" onClick={() => etapeFaite(ech.cle, 'vu', 'Vu')}>C’est noté</button>}
        {a.ob && a.ob.a_faire.modele && !['sms', 'sms_rivage'].includes(a.ob.a_faire.canal) && <button className="btn plein" onClick={() => ouvrirMail(a.ob.a_faire.modele, { ob: a.ob }, { cle: a.ob.cle, etape: String(a.ob.a_faire.ordre), detail: a.ob.a_faire.libelle })}>
          {a.ob.a_faire.canal === 'lrar' ? 'Préparer le recommandé' : 'Préparer le mail'}</button>}
        {a.ob && ['sms', 'sms_rivage'].includes(a.ob.a_faire.canal) && <SmsRivage texte={SMS[a.ob.a_faire.modele]?.({ ...ctx, ob: a.ob })} tels={(d.contacts?.locataires || []).map((l) => l.telephone).filter(Boolean)} noms={(d.contacts?.locataires || []).filter((l) => l.telephone).map((l) => nomSms(l.nom))}
          envoi={{ bail: b.bail_id, cle: a.ob.cle, etape: String(a.ob.a_faire.ordre), detail: a.ob.a_faire.libelle }} apres={async () => { await charger(); apres(); }}
          fait={() => etapeFaite(a.ob.cle, String(a.ob.a_faire.ordre), 'SMS envoyé au locataire')} />}
        {a.ob && <button className="btn" onClick={() => etapeFaite(a.ob.cle, String(a.ob.a_faire.ordre), a.ob.a_faire.libelle)}>Marquer fait</button>}
        {a.ob && a.ob.nature === 'assurance' && !['commercial', 'derogatoire', 'professionnel'].includes(ech.type) && <ChoixAssurance ob={a.ob} agir={agir} />}
        {a.ob && <Realise ob={a.ob} agir={agir} />}
      </div>}
    </div>)}
    {mail && <EditeurMail mail={mail} email={email} fermer={() => setMail(null)} marquer={async () => { await etapeFaite(mail.etape.cle, mail.etape.etape, mail.etape.detail); setMail(null); }} peut={gere} />}

    {synthese ? <>
      {/* Mode synthèse (même présentation que le mandat) : la fiche d'abord, le détail replié en dessous */}
      <Synthese d={d} b={b} peut={gere} soumis={soumis} parametrer={() => setParametrer(true)} />
      <details className="replie" open={!!ech.action || ['a_informer', 'attente_bailleur', 'conge_a_delivrer', 'conge_en_cours', 'conge_depose', 'hors_delai'].includes(ech.etat)} style={{ marginTop: 14 }}>
        <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Échéance du bail · {date(ech.echeance)}{ETATS[ech.etat] ? ' · ' + ETATS[ech.etat] : ''}</summary>
        <Echeance d={d} b={b} peut={gere} agir={agir} ouvrirMail={ouvrirMail} />
      </details>
      <details className="replie" style={{ marginTop: 10 }} open={(d.obligations || []).some((o) => o.actif && (o.a_faire || o.en_retard))}>
        <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Suivis et relances ({(d.obligations || []).filter((o) => o.actif).length})</summary>
        <Suivis d={d} b={b} peut={gere} agir={agir} />
      </details>
      <Paliers d={d} b={b} peut={gere} agir={agir} ouvrirMail={ouvrirMail} />
      <Actes d={d} b={b} peut={gere} agir={agir} />
      {journal.length > 0 && <details className="replie" style={{ marginTop: 10 }}>
        <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Journal ({journal.length})</summary>
        <ol className="histo">{journal.slice(0, 30).map((j, i) =>
          <li key={i}><span className="muted">{new Date(j.le).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' })}</span><span>{j.detail || j.etape}{j.par ? ' · ' + j.par : ''}</span></li>)}</ol>
      </details>}
    </> : <>
      <Echeance d={d} b={b} peut={gere} agir={agir} ouvrirMail={ouvrirMail} />
      {(d.controle?.go_le || !soumis) && <div className="row" style={{ justifyContent: 'flex-end', marginTop: 12 }}><button className="btn plein" onClick={() => setParametrer(false)}>Retour à la synthèse du bail</button></div>}
      <Controle d={d} b={b} peut={peut} agir={agir} ouvrirMail={ouvrirMail} recharger={async () => { await charger(); apres(); }} />
      <Suivis d={d} b={b} peut={gere} agir={agir} />
      <Paliers d={d} b={b} peut={gere} agir={agir} ouvrirMail={ouvrirMail} />
      <Actes d={d} b={b} peut={gere} agir={agir} />
      {journal.length > 0 && <><h3>Journal</h3><ol className="histo">{journal.slice(0, 30).map((j, i) =>
        <li key={i}><span className="muted">{new Date(j.le).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' })}</span><span>{j.detail || j.etape}{j.par ? ' · ' + j.par : ''}</span></li>)}</ol></>}
    </>}
    <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={b.lien} target="_blank" rel="noreferrer">Ouvrir le bail dans Rivage</a></div>
  </>;
}

// SMS au locataire (065, 066) : envoi direct par le pilotage (Zapier → Twilio, expéditeur UDI GESTION) au numéro Rivage du locataire,
// texte modifiable avant l'envoi. À défaut, copie du texte pour un envoi depuis le téléphone de l'agence.
export function SmsRivage({ texte, fait, tels = [], noms = [], envoi, apres }) {
  const [t, setT] = useState(texte || '');
  const [etat, setEtat] = useState({ charge: false, err: '', ok: '' });
  const [vu, setVu] = useState(false);
  useEffect(() => { setT(texte || ''); }, [texte]);
  const envoyer = async () => {
    setEtat({ charge: true, err: '', ok: '' });
    const { data, error } = await supabase.functions.invoke('pilotage-sms', { body: { ...envoi, texte: t } });
    if (error || !data?.ok) {
      let msg = data?.error;
      if (!msg && error?.context?.json) { try { msg = (await error.context.json()).error; } catch { /* réponse illisible */ } }
      setEtat({ charge: false, err: msg || 'SMS non envoyé', ok: '' }); return;
    }
    setEtat({ charge: false, err: '', ok: `SMS envoyé au ${data.resultats.filter((r) => r.ok).map((r) => r.telephone).join(', ')}` });
    apres && await apres();
  };
  return <div style={{ width: '100%' }}>
    <textarea rows={3} style={{ width: '100%', fontFamily: 'inherit', fontSize: 14 }} value={t} onChange={(e) => setT(e.target.value)} />
    {t.includes('{nom}') && <div className="muted" style={{ fontSize: 12 }}>« {'{nom}'} » sera remplacé par le nom de chaque locataire{noms.length ? ` : ${noms.join(', ')}` : ''}.</div>}
    {(() => { const f = smsFactures(t.split('{nom}').join(noms[0] || 'Prénom NOM')); return <div className="muted" style={{ fontSize: 12, color: f.n > 1 ? 'var(--red)' : undefined }}>
      {f.longueur} caractères{f.unicode ? ' (caractère spécial : ê, ç, « »… le message passe en Unicode)' : ''} · {f.n} SMS facturé{f.n > 1 ? 's' : ''}</div>; })()}
    <div className="muted" style={{ fontSize: 12 }}>Destinataire : {tels.length ? tels.join(', ') : 'aucun numéro du locataire dans Rivage'}</div>
    <div className="row" style={{ marginTop: 4 }}>
      {envoi && tels.length > 0 && <button className="btn plein" disabled={etat.charge || !t.trim()} onClick={envoyer}>{etat.charge ? 'Envoi…' : 'Envoyer le SMS (UDI GESTION)'}</button>}
      <button className="btn" onClick={() => { navigator.clipboard?.writeText(t.split('{nom}').join(noms[0] || '')); setVu(true); }}>Copier le texte</button>
      {vu && <button className="btn" onClick={fait}>Envoyé depuis un téléphone</button>}
    </div>
    {etat.err && <div className="err">{etat.err}</div>}
    {etat.ok && <div style={{ color: 'var(--teal)', fontSize: 13 }}>{etat.ok}</div>}
  </div>;
}

export function Realise({ ob, agir }) {
  const [ouvert, setOuvert] = useState(false);
  const [le, setLe] = useState(auj());
  const [proch, setProch] = useState('');
  if (!ouvert) return <button className="btn" onClick={() => setOuvert(true)}>Justificatif reçu</button>;
  return <span className="row">
    <label className="muted">Réalisé le <input type="date" value={le} onChange={(e) => setLe(e.target.value)} /></label>
    <label className="muted">Prochaine échéance <input type="date" value={proch} onChange={(e) => setProch(e.target.value)} placeholder={ob.periodicite_mois ? `+${ob.periodicite_mois} mois` : ''} /></label>
    <button className="btn plein" onClick={() => agir('pilotage_obligation_realisee', { p_id: ob.id, p_le: le, p_prochaine: proch || null })}>Valider</button>
    <span className="muted" style={{ fontSize: 12 }}>{ob.periodicite_mois ? `Sans date, la prochaine échéance sera dans ${ob.periodicite_mois} mois.` : 'Sans date, le suivi sera clos.'}</span>
  </span>;
}

export function EditeurMail({ mail, email, fermer, marquer, peut }) {
  const [objet, setObjet] = useState(mail.m.objet);
  const [corps, setCorps] = useState(mail.m.corps);
  const [to, setTo] = useState((mail.m.to || []).join(', '));
  const m = { ...mail.m, objet, corps, to: to.split(',').map((x) => x.trim()).filter(Boolean) };
  return <div className="card" style={{ marginTop: 10 }}>
    <div className="row" style={{ justifyContent: 'space-between' }}><b>{mail.m.courrier ? 'Courrier recommandé à envoyer' : 'Mail à relire avant envoi'}</b><button className="lien" onClick={fermer}>Fermer</button></div>
    {!mail.m.courrier && <label className="muted" style={{ display: 'block', marginTop: 8 }}>Destinataire ({mail.m.dest})
      <input style={{ width: '100%' }} value={to} onChange={(e) => setTo(e.target.value)} /></label>}
    {!mail.m.courrier && !m.to.length && <div className="mini-alerte haute">Aucune adresse e-mail dans Rivage pour ce {mail.m.dest} : à compléter.</div>}
    <label className="muted" style={{ display: 'block', marginTop: 8 }}>Objet<input style={{ width: '100%' }} value={objet} onChange={(e) => setObjet(e.target.value)} /></label>
    <label className="muted" style={{ display: 'block', marginTop: 8 }}>Texte<textarea rows={12} style={{ width: '100%', fontFamily: 'inherit', fontSize: 14 }} value={corps} onChange={(e) => setCorps(e.target.value)} /></label>
    <div className="row" style={{ marginTop: 8 }}>
      {!mail.m.courrier && <a className="btn plein" href={lienGmail(m, email)} target="_blank" rel="noreferrer">Ouvrir dans Gmail</a>}
      <button className="btn" onClick={() => navigator.clipboard?.writeText(mail.m.courrier ? corps : `${objet}\n\n${corps}`)}>Copier</button>
      {peut && <button className="btn" onClick={marquer}>{mail.m.courrier ? 'Recommandé envoyé' : 'Mail envoyé'}</button>}
    </div>
    <p className="muted" style={{ fontSize: 12 }}>{mail.m.courrier ? 'À envoyer en recommandé avec accusé de réception (Rivage ou envoi en ligne). Conservez la preuve de dépôt.' : 'Le brouillon s’ouvre dans votre boîte Gmail : relisez, envoyez, puis cliquez sur « Mail envoyé ».'}</p>
  </div>;
}

// ----- Échéance et congé -----
function Echeance({ d, b, peut, agir, ouvrirMail }) {
  const ech = d.echeance || {}; const fiche = d.fiche || {};
  const [choix, setChoix] = useState(ech.choix || '');
  const [conge, setConge] = useState(''); const [mode, setMode] = useState('');
  const [prop, setProp] = useState('');
  useEffect(() => { setChoix(ech.choix || ''); }, [ech.choix, b.bail_id]);
  const habitation = ['vide', 'meuble', 'mixte'].includes(ech.type);
  const congeChoisi = ech.choix && !['reconduire', 'ne_rien_faire', 'laisser_commercial', 'renouveler_loyer'].includes(ech.choix);
  const [voir65, setVoir65] = useState(false);
  const age = d.rivage?.locataire_65;
  const ageRivage = age?.connu && fiche.locataire_65 == null;
  // Avant la date d'information du bailleur, rien à décider : on affiche seulement l'échéance et la prochaine étape
  const enAttente = ech.etat === 'a_venir' && !ech.informe_le && !ech.choix && !ech.manquee;
  if (ech.etat !== 'incomplet' && enAttente) return <>
    <h3>Échéance du bail</h3>
    <div className="echeance"><div><b>Échéance</b>
      <div className="muted">Rien à faire avant le {date(ech.info)} : information du bailleur ce jour-là{ech.type === 'commercial' ? ' (12 mois avant)' : ''}.</div></div>
      <div className="echeance-n">{date(ech.echeance)}</div></div>
    {ech.douze_ans && <p className="muted">12 ans de durée le {date(ech.douze_ans)} : au-delà, déplafonnement possible du loyer du bail renouvelé.</p>}
    {ech.triennale && <p className="muted">Prochaine fin de période triennale : {date(ech.triennale)} (faculté de congé du preneur avec 6 mois de préavis).</p>}
  </>;
  return <>
    <h3>Échéance du bail</h3>
    {ech.etat === 'incomplet' ? <div className="mini-alerte haute">{ech.raison}</div> : <>
      <div className="echeance"><div><b>{ech.mode === 'prolongation' ? 'En tacite prolongation depuis le' : ech.mode === 'fin_auto' ? 'Fin du bail' : 'Échéance'}</b>
        <div className="muted">{ETATS[ech.etat] || ech.etat}{ech.manquee ? ` · délai de congé dépassé pour l’échéance du ${date(ech.manquee)}` : ''}</div></div>
        <div className="echeance-n">{date(ech.echeance)}</div></div>
      <ol className="etapes">{[
        ['Information du bailleur', ech.info, ech.informe_le, 'informe'],
        ['Relance', ech.relance, ech.relance_le, 'relance'],
        ['Décision attendue, sinon LRAR', ech.decision, ech.lrar_le || ech.choix_le, ech.lrar_le ? 'lrar' : null],
        ['Date limite du congé', ech.limite, ech.conge_le, null],
      ].filter((x) => x[1] || x[2]).map(([l, pr, fait, code]) => <li key={l} className={fait ? 'fait' : pr && pr < auj() ? 'retard' : ''}>
        <span className="puce">{fait ? '✓' : ''}</span><span>{l}<span className="muted"> · prévu le {date(pr)}{fait ? ` · fait le ${date(fait)}` : ''}</span>
        {peut && fait && code && <button className="lien" style={{ marginLeft: 8 }} onClick={() => agir('pilotage_suivi_etape', { p_cle: ech.cle, p_etape: code, p_detail: null, p_annuler: true })}>Annuler</button>}</span></li>)}</ol>
      {ech.mode === 'prolongation' && <p className="muted">Un congé délivré aujourd’hui prendrait effet au plus tôt le {date(ech.effet_conge_au_plus_tot)} (6 mois, pour le dernier jour d’un trimestre civil).</p>}
      {ech.douze_ans && <p className="muted">12 ans de durée le {date(ech.douze_ans)} : au-delà, déplafonnement possible du loyer du bail renouvelé.</p>}
      {ech.triennale && <p className="muted">Prochaine fin de période triennale : {date(ech.triennale)} (faculté de congé du preneur avec 6 mois de préavis).</p>}
      {(ech.blocages || []).map((x, i) => <div key={i} className="mini-alerte critique">{x}</div>)}
      {habitation && d.rivage?.locataire_65?.detail && <p className="muted" style={{ margin: '6px 0 0' }}>Âge d’après Rivage : {d.rivage.locataire_65.detail}.{fiche.locataire_65 == null && d.rivage.locataire_65.connu ? ' Utilisé tant que la fiche n’est pas renseignée.' : ''}</p>}
      {habitation && ageRivage && !voir65 && peut && <button className="lien" onClick={() => setVoir65(true)}>Corriger l’âge (Rivage incomplet ou erroné)</button>}
      {habitation && (!ageRivage || voir65) && <div className="row" style={{ marginTop: 6 }}>
        <ChampFiche b={b} fiche={fiche} champ="locataire_65" libelle="Locataire de plus de 65 ans à l’échéance" peut={peut} agir={agir} />
        {fiche.locataire_65 && <ChampFiche b={b} fiche={fiche} champ="ressources_sous_plafond" libelle="Ressources sous le plafond" peut={peut} agir={agir} />}
      </div>}
      {(ech.options || []).length > 0 && <>
        <div className="muted" style={{ marginTop: 8 }}>Décision du bailleur</div>
        {(ech.options || []).map((o) => <label key={o} className="champ-imp" style={{ display: 'block', margin: '4px 0' }}>
          <input type="radio" name={'dec' + b.bail_id} checked={choix === o} onChange={() => setChoix(o)} disabled={!peut} /> {DECISIONS[o]}
          <div className="muted" style={{ fontSize: 12, marginLeft: 22 }}>{CONSEQUENCES[o]}</div></label>)}
        {peut && <div className="row">
          <button className="btn plein" disabled={!choix || choix === ech.choix} onClick={() => agir('pilotage_echeance_decision', { p_bail: b.bail_id, p_decision: choix, p_proposition: null, p_conge: null, p_conge_mode: null })}>Enregistrer la décision</button>
          {ech.choix && <button className="btn gris" onClick={() => agir('pilotage_echeance_decision', { p_bail: b.bail_id, p_decision: '', p_proposition: null, p_conge: null, p_conge_mode: null })}>Annuler la décision</button>}
        </div>}
      </>}
      {peut && ech.choix === 'renouveler_loyer' && !ech.proposition_le && <div className="row" style={{ marginTop: 6 }}>
        <label className="muted">Proposition envoyée le <input type="date" value={prop} onChange={(e) => setProp(e.target.value)} /></label>
        <button className="btn" disabled={!prop} onClick={() => agir('pilotage_echeance_decision', { p_bail: b.bail_id, p_decision: null, p_proposition: prop, p_conge: null, p_conge_mode: null })}>Enregistrer</button></div>}
      {peut && congeChoisi && !ech.conge_le && <div className="row" style={{ marginTop: 6 }}>
        <label className="muted">Congé délivré le <input type="date" value={conge} onChange={(e) => setConge(e.target.value)} /></label>
        <select value={mode} onChange={(e) => setMode(e.target.value)} aria-label="Mode de délivrance">
          <option value="">Mode de délivrance</option><option value="commissaire">Commissaire de justice</option><option value="lrar">LRAR</option><option value="remise">Remise contre émargement</option></select>
        <button className="btn" disabled={!conge || !mode} onClick={() => agir('pilotage_echeance_decision', { p_bail: b.bail_id, p_decision: null, p_proposition: null, p_conge: conge, p_conge_mode: mode })}>Enregistrer</button></div>}
      {ech.etat === 'conge_en_cours' && <p className="muted">Congé décidé le {date(ech.choix_le)} : acte en préparation. Relance automatique le {date(ech.relance_conge)} si le congé n’est ni enregistré ici ni déposé dans Rivage (document dont le nom contient « congé »).</p>}
      {ech.conge_le && <p>Congé délivré le {date(ech.conge_le)} ({ech.conge_mode}) : enregistré aussi dans « Actes et notifications ».</p>}
      {peut && !ech.action && ech.etat !== 'a_venir' && <button className="lien" onClick={() => ouvrirMail('echeance_info', {}, { cle: ech.cle, etape: 'informe', detail: 'Bailleur informé' })}>Préparer à nouveau le mail d’information au bailleur</button>}
    </>}
  </>;
}

// ----- Champ de la fiche (édition inline) -----
const CHAMPS = {
  type_bail: { type: 'select', options: TYPES_BAIL },
  situation: { type: 'select', options: { en_cours: 'En cours', tacite_prolongation: 'Tacite prolongation', renouvele: 'Renouvelé' } },
  terme: { type: 'select', options: { avance: 'D’avance', echu: 'À terme échu' } },
  locataire_65: { type: 'bool' }, ressources_sous_plafond: { type: 'bool' },
  date_origine: { type: 'date' }, date_signature: { type: 'date' }, date_acquisition: { type: 'date' }, garantie_fin: { type: 'date' },
  exec_substitutive_jours: { type: 'number' }, garantie_montant: { type: 'number' },
};
function ChampFiche({ b, fiche, champ, libelle, peut, agir }) {
  const def = CHAMPS[champ] || { type: 'text' };
  const v = fiche?.[champ];
  const [val, setVal] = useState(v == null ? '' : String(v));
  useEffect(() => { setVal(v == null ? '' : String(v)); }, [v, b.bail_id]);
  const enr = (x) => agir('pilotage_fiche_bail_maj', { p_bail: b.bail_id, p_champ: champ, p_valeur: x });
  if (!peut) return <span>{libelle ? libelle + ' : ' : ''}{def.options?.[v] || (def.type === 'bool' ? (v === true ? 'Oui' : v === false ? 'Non' : '—') : v ?? '—')}</span>;
  const lab = libelle ? <span className="muted">{libelle} </span> : null;
  if (def.type === 'select') return <label>{lab}<select value={val} onChange={(e) => { setVal(e.target.value); enr(e.target.value); }}>
    <option value="">—</option>{Object.entries(def.options).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>;
  if (def.type === 'bool') return <label>{lab}<select value={val} onChange={(e) => { setVal(e.target.value); enr(e.target.value); }}>
    <option value="">Non vérifié</option><option value="true">Oui</option><option value="false">Non</option></select></label>;
  return <label>{lab}<input type={def.type === 'date' ? 'date' : def.type === 'number' ? 'number' : 'text'} value={val} onChange={(e) => setVal(e.target.value)}
    onBlur={() => { if (val !== (v == null ? '' : String(v))) enr(val); }} style={def.type === 'text' ? { minWidth: 260 } : undefined} /></label>;
}

// Qui fournit chaque pièce du contrôle d'entrée (064) : bailleur, locataire ou agence (pièces établies par UDI Gestion)
let fournisseursP = null;
export function useFournisseurs() {
  const [f, setF] = useState({});
  useEffect(() => { (fournisseursP = fournisseursP || rpc('pilotage_pieces_fournisseurs').catch(() => { fournisseursP = null; return {}; })).then((x) => setF(x || {})); }, []);
  return f;
}
export const FOURNI_PAR = { bailleur: 'à fournir par le bailleur', locataire: 'à fournir par le locataire', agence: 'à établir par l’agence' };

// ----- Contrôle d'entrée -----
function Controle({ d, b, peut, agir, ouvrirMail, recharger }) {
  const fourn = useFournisseurs();
  const c = d.controle || { items: [] };
  const [ouvert, setOuvert] = useState(true); // après le GO, on n'arrive ici que par « Modifier le paramétrage »
  const [lecture, setLecture] = useState({ charge: false, err: '' });
  useEffect(() => { setOuvert(true); }, [b.bail_id]);
  const manquantsDe = (qui) => c.items.filter((i) => i.bloc === 'pieces' && i.statut !== 'ok' && i.statut !== 'sans_objet' && (fourn[i.cle] || 'bailleur') === qui).map((i) => i.libelle);
  const manqBailleur = manquantsDe('bailleur'); const manqLocataire = manquantsDe('locataire'); const manqAgence = manquantsDe('agence');
  // Écarts détectés (Rivage vide, différence avec le bail lu, incohérence légale) : restent visibles même une fois répondus.
  const ecarts = c.items.filter((i) => i.auto === 'anomalie' && i.bloc !== 'pieces');
  const ficheRivage = 'https://rivage.immo/leasing_contracts?leasing_contract_id=' + b.bail_id;
  // Réglé = conforme d'office, non exigé, ou répondu conforme / sans objet (un écart justifié passe au journal).
  const regle = (i) => i.statut === 'ok' || i.statut === 'sans_objet';
  const ecartsOuverts = ecarts.filter((i) => !regle(i));
  const piecesManquantes = c.items.filter((i) => i.bloc === 'pieces' && !regle(i));
  const piecesFaites = c.items.filter((i) => i.bloc === 'pieces' && regle(i));
  const rivageOuverts = c.items.filter((i) => i.bloc === 'rivage' && !regle(i));
  const rivageFaits = c.items.filter((i) => i.bloc === 'rivage' && regle(i));
  const repondrePiece = async (i, statut) => {
    await agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: statut, p_suivi: statut ? (i.mode === 'document' || i.bloc === 'rivage' ? 'rivage' : 'backoffice') : null, p_valeur: null, p_commentaire: null });
  };
  const lire = async (fichier) => {
    setLecture({ charge: true, err: '' });
    let body = { bail_id: b.bail_id };
    if (fichier) {
      const buf = await fichier.arrayBuffer(); let bin = ''; const u = new Uint8Array(buf);
      for (let i = 0; i < u.length; i += 0x8000) bin += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000));
      body = { ...body, pdf: btoa(bin), nom: fichier.name };
    }
    const { data, error } = await supabase.functions.invoke('pilotage-lecture-bail', { body });
    if (error || data?.error) setLecture({ charge: false, err: data?.error || 'Lecture impossible pour le moment.' });
    else { setLecture({ charge: false, err: '' }); await recharger(); }
  };
  return <>
    <div className="row" style={{ justifyContent: 'space-between', marginTop: 18 }}>
      <h3 style={{ margin: 0 }}>Contrôle d’entrée {c.portee === 'commercial' ? '(bail commercial)' : '(habitation)'}</h3>
      <button className="lien" onClick={() => setOuvert(!ouvert)}>{ouvert ? 'Replier' : 'Déplier'}</button>
    </div>
    <div className={'mini-alerte ' + (c.go_le ? 'normale' : c.restant ? 'haute' : 'normale')}>
      {c.go_le ? <>GO donné le {date(c.go_le)} par {c.go_par || '—'}{c.anomalies ? ` · ${c.anomalies} anomalie(s) acceptée(s)` : ''}</>
        : <>{c.restant} point(s) à traiter · {c.anomalies} anomalie(s){d.lecture ? ` · bail lu par l’IA le ${date(d.lecture.le)}` : ''}</>}
      {peut && <div className="row" style={{ marginTop: 6 }}>
        {!c.go_le && <button className="btn plein" disabled={c.restant > 0} onClick={() => agir('pilotage_bail_go', { p_bail: b.bail_id, p_oui: true })}>Donner le GO</button>}
        {c.go_le && <button className="btn gris" onClick={() => agir('pilotage_bail_go', { p_bail: b.bail_id, p_oui: false })}>Retirer le GO</button>}
        {/* Bail lu une seule fois : plus de bouton de lecture une fois la lecture enregistrée */}
        {!d.lecture && <button className="btn" disabled={lecture.charge} onClick={() => lire(null)}>{lecture.charge ? 'Lecture en cours…' : 'Lire le bail déposé dans Rivage (IA)'}</button>}
        {!d.lecture && <label className="btn">Lire un PDF (IA)<input type="file" accept="application/pdf" hidden onChange={(e) => e.target.files[0] && lire(e.target.files[0])} /></label>}
        {manqBailleur.length > 0 && <button className="btn" onClick={() => ouvrirMail('pieces_manquantes', { manquants: manqBailleur }, { cle: 'e:' + b.bail_id + ':pieces', etape: auj(), detail: 'Pièces demandées au bailleur' })}>Demander les pièces au bailleur ({manqBailleur.length})</button>}
        {manqLocataire.length > 0 && <button className="btn" onClick={() => ouvrirMail('pieces_manquantes_locataire', { manquants: manqLocataire }, { cle: 'e:' + b.bail_id + ':pieces_locataire', etape: auj(), detail: 'Pièces demandées au locataire' })}>Demander les pièces au locataire ({manqLocataire.length})</button>}
      </div>}
      {manqAgence.length > 0 && <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>À établir et déposer dans Rivage par l’agence (pas de demande au bailleur ni au locataire) : {manqAgence.join(', ')}.</div>}
      {lecture.err && <div className="err">{lecture.err}</div>}
    </div>
    {ecartsOuverts.length > 0 && <div className="mini-alerte critique">
      <b>⚠ {ecartsOuverts.length} écart(s) à traiter entre le bail, Rivage et la loi</b>
      <ul style={{ margin: '4px 0 0', paddingLeft: 18 }}>{ecartsOuverts.map((i) => <li key={i.cle}>
        <a href={'#q-' + i.cle} onClick={() => setOuvert(true)} style={{ color: 'inherit' }}>{i.libelle}</a> · {i.detail}
        {i.repondu && i.statut === 'anomalie' ? <b> → anomalie signalée par {i.par || '—'} : {i.commentaire}</b> : null}
      </li>)}</ul>
      <div className="row" style={{ marginTop: 6 }}>
        <a className="btn plein" href={ficheRivage} target="_blank" rel="noreferrer">Corriger dans Rivage ↗</a>
        <button className="btn gris" onClick={() => recharger()}>Revérifier après correction</button>
      </div>
      <div style={{ fontSize: 12, marginTop: 4 }}>Corrigé dans Rivage : le point disparaît. Écart voulu (avenant, indexation…) : « Conforme » avec la justification, il passe au journal.</div>
    </div>}
    {d.lecture && <LectureIA l={d.lecture} />}
    {ouvert && <>
      <div className="groupe-tete" style={{ marginTop: 10 }}><b>{BLOCS.pieces}</b></div>
      {piecesManquantes.length === 0
        ? <div style={{ color: 'var(--teal)', fontSize: 13, padding: '6px 0' }}>✓ Toutes les pièces exigées pour ce bail sont au dossier.</div>
        : <div className="mini-alerte haute">
          <b>{piecesManquantes.length} pièce(s) manquante(s)</b>
          {piecesManquantes.map((i) => <div key={i.cle} className="row" style={{ justifyContent: 'space-between', borderTop: '1px solid rgba(0,0,0,.08)', padding: '5px 0', color: 'var(--ink)' }}>
            <div style={{ flex: 1, minWidth: 220 }}>{i.libelle}
              {i.aide && <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div>}
              {i.statut === 'anomalie' && i.commentaire && <div style={{ fontSize: 12, color: 'var(--red)' }}>{i.commentaire}</div>}</div>
            <div className="row">
              <a className="btn" href={ficheRivage} target="_blank" rel="noreferrer">Déposer dans Rivage ↗</a>
              {peut && <button className="lien" onClick={() => repondrePiece(i, 'sans_objet')}>Sans objet</button>}
            </div>
          </div>)}
          <div style={{ fontSize: 12, marginTop: 4 }}>Une pièce déposée dans Rivage disparaît de cette liste à la prochaine mise à jour : elle est reconnue par sa catégorie Rivage ou par son nom (même approximatif).</div>
        </div>}
      {piecesFaites.length > 0 && <details style={{ padding: '4px 0' }}>
        <summary style={{ cursor: 'pointer', color: 'var(--muted)', fontSize: 13 }}>{piecesFaites.length} pièce(s) au dossier, sans objet ou non exigée(s)</summary>
        <ul style={{ margin: '4px 0', paddingLeft: 18, fontSize: 13 }}>{piecesFaites.map((i) => <li key={i.cle}>{i.libelle} · {
          i.repondu ? (i.statut === 'ok' ? (i.commentaire || 'reçue') : 'sans objet') + ` (${i.par || '—'}, ${date(i.le)})` : i.detail}
          {peut && i.auto === 'ok' && i.piece?.par_nom && !i.repondu && <VerifPiece i={i} b={b} agir={agir} />}
          {peut && i.repondu && <button className="lien" style={{ marginLeft: 8 }} onClick={() => repondrePiece(i, null)}>Revenir</button>}</li>)}</ul></details>}
      {piecesFaites.some((i) => i.auto === 'ok' && i.piece?.par_nom && !i.repondu) && <div className="muted" style={{ fontSize: 12 }}>Pièces reconnues par leur nom : en cas de doute, « Vérifier avec l’IA » lit le document et confirme le dépôt.</div>}

      <div className="groupe-tete" style={{ marginTop: 10 }}><b>{BLOCS.rivage}</b></div>
      {rivageOuverts.length === 0 && <div style={{ color: 'var(--teal)', fontSize: 13, padding: '6px 0' }}>✓ Aucun point à traiter.</div>}
      {rivageOuverts.sort((x, y) => (y.auto === 'anomalie') - (x.auto === 'anomalie')).map((i) => <Question key={i.cle} i={i} d={d} b={b} peut={peut} agir={agir} />)}
      {rivageFaits.length > 0 && <details style={{ borderTop: '1px solid var(--line)', padding: '6px 0' }}>
        <summary style={{ cursor: 'pointer', color: 'var(--teal)', fontSize: 13 }}>✓ {rivageFaits.length} point(s) conforme(s)</summary>
        <ul style={{ margin: '4px 0', paddingLeft: 18, fontSize: 13 }}>{rivageFaits.map((i) => <li key={i.cle}>{i.libelle} · {i.detail}
          {i.repondu && <span className="muted"> · {i.statut === 'sans_objet' ? 'sans objet' : i.auto === 'anomalie' ? 'écart justifié : ' + (i.commentaire || '—') : 'validé'} ({i.par || '—'}, {date(i.le)})</span>}
          {peut && (i.repondu
            ? <button className="lien" style={{ marginLeft: 8 }} onClick={() => repondrePiece(i, null)}>Revenir</button>
            : <button className="lien" style={{ marginLeft: 8 }} onClick={() => { const m = window.prompt('Qu’est-ce qui ne va pas ? (obligatoire)'); if (m && m.trim()) agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: 'anomalie', p_suivi: 'rivage', p_valeur: null, p_commentaire: m.trim() }); }}>Contester</button>)}</li>)}</ul></details>}

      <div className="groupe-tete" style={{ marginTop: 10 }}><b>{BLOCS.clauses}</b></div>
      {/* Clauses : seules celles à traiter restent ouvertes ; les réponses données sont résumées sur une ligne chacune */}
      {c.items.filter((i) => i.bloc === 'clauses' && !i.repondu && !(i.auto === 'ok' && i.mode !== 'fiche') && i.auto !== 'sans_objet')
        .map((i) => <Question key={i.cle} i={i} d={d} b={b} peut={peut} agir={agir} />)}
      {(() => { const faites = c.items.filter((i) => i.bloc === 'clauses' && i.repondu);
        return faites.length > 0 && <details style={{ borderTop: '1px solid var(--line)', padding: '6px 0' }}>
          <summary style={{ cursor: 'pointer', color: 'var(--teal)', fontSize: 13 }}>✓ {faites.length} clause(s) traitée(s)</summary>
          <div style={{ marginTop: 4 }}>{faites.map((i) => <div key={i.cle} style={{ display: 'grid', gridTemplateColumns: 'minmax(160px, 38%) 1fr auto', gap: 10, padding: '3px 0', borderTop: '1px solid var(--line)', fontSize: 13 }}>
            <span>{i.statut === 'anomalie' ? '⚠ ' : i.statut === 'sans_objet' ? '– ' : '✓ '}{i.libelle}</span>
            <span>{[i.mode === 'fiche' ? court(i.detail) : null, i.genere ? i.valeur : null, i.commentaire !== i.valeur ? i.commentaire : null].filter(Boolean).join(' · ') || (i.statut === 'sans_objet' ? 'Sans objet' : 'Oui')}
              <span className="muted"> ({i.par || '—'}, {date(i.le)})</span></span>
            {peut && <button className="lien" onClick={() => agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: null, p_suivi: null, p_valeur: null, p_commentaire: null })}>Revenir</button>}
          </div>)}</div></details>; })()}
      {(() => { const so = c.items.filter((i) => i.bloc === 'clauses' && i.auto === 'sans_objet' && !i.repondu);
        return so.length > 0 && <details style={{ borderTop: '1px solid var(--line)', padding: '6px 0' }}>
          <summary style={{ cursor: 'pointer', color: 'var(--muted)', fontSize: 13 }}>– {so.length} point(s) non exigé(s) à la date de ce bail</summary>
          <ul style={{ margin: '4px 0', paddingLeft: 18, fontSize: 13 }}>{so.map((i) => <li key={i.cle}>{i.libelle} · {i.detail}</li>)}</ul></details>; })()}
    </>}
  </>;
}

// ----- Synthèse du bail (contrôle bouclé) : conditions paramétrées, lisibles d'un coup d'œil -----
const court = (t) => (t || '').split(' · ')[0];
function Synthese({ d, b, peut, soumis, parametrer }) {
  const c = d.controle || { items: [] };
  const ech = d.echeance || {};
  const regle = (i) => i.statut === 'ok' || i.statut === 'sans_objet';
  const ficheRivage = 'https://rivage.immo/leasing_contracts?leasing_contract_id=' + b.bail_id;
  const aRevoir = c.items.filter((i) => (i.bloc === 'rivage' && !regle(i) && i.auto === 'anomalie'));
  const pieces = c.items.filter((i) => i.bloc === 'pieces' && !regle(i));
  const conditions = c.items.filter((i) => i.bloc === 'rivage' && i.statut !== 'sans_objet' && i.detail);
  const clauses = c.items.filter((i) => i.bloc === 'clauses' && i.statut && i.statut !== 'sans_objet' && i.auto !== 'sans_objet');
  const obs = (d.obligations || []).filter((o) => o.actif);
  const ligne = { display: 'grid', gridTemplateColumns: 'minmax(160px, 34%) 1fr', gap: 10, padding: '4px 0', borderTop: '1px solid var(--line)', fontSize: 13 };
  return <>
    <div className="row" style={{ justifyContent: 'space-between', marginTop: 18 }}>
      <h3 style={{ margin: 0 }}>Synthèse du bail</h3>
      {peut && <button className="btn" onClick={parametrer}>Modifier le paramétrage</button>}
    </div>
    <div className="muted" style={{ fontSize: 12 }}>{c.go_le ? `Contrôle d’entrée validé (GO) le ${date(c.go_le)} par ${c.go_par || '—'}.` : soumis ? '' : 'Contrôle d’entrée non requis pour ce bail. « Modifier le paramétrage » permet de le compléter.'}</div>
    {(aRevoir.length > 0 || pieces.length > 0) && <div className="mini-alerte haute">
      {aRevoir.length > 0 && <div><b>À revoir depuis le dernier contrôle :</b> {aRevoir.map((i) => `${i.libelle} (${i.detail})`).join(' ; ')}</div>}
      {pieces.length > 0 && <div><b>Pièces manquantes :</b> {pieces.map((i) => i.libelle).join(', ')}</div>}
      <div className="row" style={{ marginTop: 6 }}>
        <a className="btn" href={ficheRivage} target="_blank" rel="noreferrer">Corriger dans Rivage ↗</a>
        {peut && <button className="btn gris" onClick={parametrer}>Traiter</button>}</div>
    </div>}
    <div style={{ marginTop: 8 }}>
      <div style={ligne}><b>Type de bail</b><span>{TYPES_BAIL[ech.type] || '—'}</span></div>
      {ech.echeance && <div style={ligne}><b>Échéance</b><span>{ech.mode === 'prolongation' ? `Tacite prolongation depuis le ${date(ech.echeance)}` : date(ech.echeance)}
        {ech.limite ? ` · congé au plus tard le ${date(ech.limite)}` : ''}{ech.triennale ? ` · prochaine triennale ${date(ech.triennale)}` : ''}{ech.douze_ans ? ` · 12 ans le ${date(ech.douze_ans)}` : ''}</span></div>}
      {conditions.map((i) => <div key={i.cle} style={ligne}><b>{i.libelle}</b><span>{court(i.detail)}
        {i.repondu && i.auto === 'anomalie' && i.statut === 'ok' && <span className="muted"> · écart justifié : {i.commentaire}</span>}</span></div>)}
      {clauses.map((i) => <div key={i.cle} style={ligne}><b>{i.libelle}</b><span>{i.statut === 'anomalie' ? '⚠ ' : ''}{[i.mode === 'fiche' ? court(i.detail) : null, i.genere ? i.valeur : null, i.commentaire !== i.valeur ? i.commentaire : null].filter(Boolean).join(' · ') || 'Oui'}</span></div>)}
      {(d.paliers || []).length > 0 && <div style={ligne}><b>Paliers et franchises</b><span>{d.paliers.map((p) => `${p.nature === 'franchise' ? 'Franchise' : 'Palier'} du ${date(p.debut)}${p.fin ? ' au ' + date(p.fin) : ''}`).join(' ; ')}</span></div>}
      {obs.length ? obs.map((o) => <div key={o.id} style={ligne}><b>Suivi · {NATURES[o.nature] || o.nature}</b><span>{o.libelle} · prochaine échéance le {date(o.prochaine)}{o.periodicite_mois ? ` · tous les ${o.periodicite_mois} mois` : ''}{o.derniere_le ? ` · dernier le ${date(o.derniere_le)}` : ''}
        {o.en_retard ? <b style={{ color: 'var(--red)' }}> · en retard</b> : o.a_faire ? <span style={{ color: 'var(--amber)' }}> · {o.a_faire.libelle}</span> : null}</span></div>)
        : <div style={ligne}><b>Suivis</b><span>Aucun suivi en place</span></div>}
      {(d.actes || []).length > 0 && <div style={ligne}><b>Actes</b><span>{d.actes.map((a) => `${ACTES[a.nature]} du ${a.auteur} le ${date(a.signifie_le)}`).join(' ; ')}</span></div>}
    </div>
  </>;
}

// Vérification par l'IA d'une pièce reconnue seulement par son nom dans Rivage.
function VerifPiece({ i, b, agir }) {
  const [etat, setEtat] = useState({ charge: false, r: null, err: '' });
  const verifier = async () => {
    setEtat({ charge: true, r: null, err: '' });
    const { data, error } = await supabase.functions.invoke('pilotage-lecture-bail', { body: { bail_id: b.bail_id, upload_id: i.piece.id, piece: i.libelle } });
    if (error || data?.error) { setEtat({ charge: false, r: null, err: data?.error || 'Vérification impossible pour le moment.' }); return; }
    if (data.conforme) {
      await agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: 'ok', p_suivi: 'rivage', p_valeur: null,
        p_commentaire: `Confirmé par l’IA : « ${i.piece.libelle} » est ${data.type_document || 'la pièce attendue'}${data.date ? ' du ' + date(data.date) : ''}` });
      setEtat({ charge: false, r: null, err: '' });
    } else {
      // Pas la bonne pièce : elle repasse en manquante, avec ce que l'IA a lu ; un nouveau dépôt la fait recontrôler.
      await agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: 'anomalie', p_suivi: 'rivage', p_valeur: null,
        p_commentaire: `Selon l’IA, « ${i.piece.libelle} » n’est pas la pièce attendue : ${data.type_document || 'document différent'}${data.raison ? ' (' + data.raison + ')' : ''}` });
      setEtat({ charge: false, r: null, err: '' });
    }
  };
  return <>
    <button className="lien" style={{ marginLeft: 8 }} disabled={etat.charge} onClick={verifier}>{etat.charge ? 'Lecture…' : 'Vérifier avec l’IA'}</button>
    {etat.err && <span className="err" style={{ marginLeft: 8 }}>{etat.err}</span>}
  </>;
}

function LectureIA({ l }) {
  const r = l.resultat || {};
  const an = Array.isArray(r.anomalies) ? r.anomalies : []; const rf = Array.isArray(r.refacturations) ? r.refacturations : [];
  if (!an.length && !rf.length) return null;
  return <details className="resume-ia" style={{ marginTop: 8 }}>
    <summary style={{ cursor: 'pointer' }}><span className="resume-ia-titre">✦ Lecture du bail</span> <span className="muted">({l.source}, le {date(l.le)} · {an.length} point(s) signalé(s), {rf.length} somme(s) refacturable(s))</span></summary>
    {an.length > 0 && <><div style={{ marginTop: 4 }}><b>Points signalés</b></div><ul style={{ margin: '2px 0 6px', paddingLeft: 18 }}>{an.map((x, k) => <li key={k}>{String(x)}</li>)}</ul></>}
    {rf.length > 0 && <><div><b>Sommes refacturables selon le bail</b></div><ul style={{ margin: '2px 0 6px', paddingLeft: 18 }}>{rf.map((x, k) => <li key={k}>{x.nature}{x.article ? ` (art. ${x.article})` : ''}{x.page ? `, page ${x.page}` : ''}</li>)}</ul></>}
    <div className="muted" style={{ fontSize: 12 }}>Proposition de l’IA à vérifier sur le document : chaque point se valide dans le questionnaire.</div>
  </details>;
}

function Question({ i, d, b, peut, agir }) {
  const [com, setCom] = useState(i.commentaire || '');
  // Où se fait le suivi : déduit de la question, plus de choix à faire. Pièce déposée ou champ du bail -> Rivage ;
  // le reste (pièces sans emplacement dans Rivage, clauses, échéances) -> back-office.
  const suivi = i.mode === 'document' || i.bloc === 'rivage' ? 'rivage' : 'backoffice';
  const [motif, setMotif] = useState(null);
  const [creer, setCreer] = useState(false);
  const [corriger, setCorriger] = useState(false);
  // Point déjà connu par Rivage (DPE du lot, âge des locataires) : validé d'office, la valeur Rivage est affichée
  const parRivage = !i.repondu && i.auto === 'ok' && i.bloc !== 'rivage' && i.mode !== 'document' && /^Rivage : /.test(i.detail || '') && !corriger;
  useEffect(() => { setCom(i.commentaire || ''); }, [i.commentaire]);
  const [errJ, setErrJ] = useState('');
  const ecart = i.auto === 'anomalie' && i.bloc !== 'pieces';
  const typeEcart = !ecart ? '' : /non renseigné/.test(i.detail || '') ? 'Non renseigné dans Rivage' : /le bail indique/.test(i.detail || '') ? 'Écart entre le bail et Rivage' : 'Incohérence légale';
  // Valider conforme un écart détecté exige une justification (avenant, indexation, erreur de lecture…).
  // Le commentaire n'apparaît que lorsqu'il est requis : anomalie, ou validation d'un écart détecté.
  const repondre = (statut) => {
    if ((statut === 'anomalie' || (ecart && statut === 'ok')) && !com.trim()) {
      if (motif !== statut) { setMotif(statut); setErrJ(''); return; }
      setErrJ(statut === 'ok' ? 'Indiquez pourquoi l’écart est conforme (avenant, indexation, mauvais document lu…).' : 'Décrivez l’anomalie.'); return;
    }
    setErrJ(''); setMotif(null);
    return agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: statut, p_suivi: suivi || null, p_valeur: null, p_commentaire: com || null });
  };
  const couleur = i.statut === 'ok' ? 'var(--teal)' : i.statut === 'anomalie' ? 'var(--red)' : i.statut === 'sans_objet' ? 'var(--muted)' : 'var(--amber)';
  const suiviExiste = i.genere && (d.obligations || []).some((o) => o.nature === i.genere && o.actif);
  // Revenir sur une réponse : la question redevient à traiter ; les suivis qu'elle a créés peuvent être arrêtés ;
  // le GO reste acquis : modifier le paramétrage fait partie de la vie du bail.
  const revenir = async () => {
    const crees = i.genere ? (d.obligations || []).filter((o) => o.nature === i.genere && o.actif) : [];
    const arreter = crees.length > 0 && window.confirm(`Arrêter aussi les suivis créés par cette réponse ?\n${crees.map((o) => '- ' + o.libelle).join('\n')}\n\nOK : les arrêter · Annuler : les garder`);
    try {
      for (const o of arreter ? crees : []) await rpc('pilotage_bail_obligation', { p_bail: b.bail_id, p_id: o.id, p_nature: o.nature, p_libelle: null, p_periodicite: o.periodicite_mois, p_prochaine: null, p_actif: false });
    } catch { /* l'erreur éventuelle s'affiche au rechargement */ }
    await agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: null, p_suivi: null, p_valeur: null, p_commentaire: null });
  };
  const cadre = ecart ? { borderTop: '1px solid var(--line)', borderLeft: '4px solid var(--red)', background: 'var(--red-bg)', padding: '8px 10px', margin: '6px 0', borderRadius: 6 } : { borderTop: '1px solid var(--line)', padding: '8px 0' };
  return <div id={'q-' + i.cle} style={cadre}>
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
      <div style={{ flex: 1, minWidth: 220 }}>
        {ecart && <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--red)', textTransform: 'uppercase', letterSpacing: '.03em' }}>⚠ {typeEcart}{i.repondu ? (i.statut === 'ok' ? ' · validé conforme' : i.statut === 'anomalie' ? ' · anomalie confirmée' : ' · sans objet') : ' · à traiter'}</div>}
        <span style={{ color: couleur, fontWeight: 700 }}>{i.statut === 'ok' ? '✓' : i.statut === 'anomalie' ? '!' : i.statut === 'sans_objet' ? '–' : '○'}</span> {i.libelle}
        {suivi === 'backoffice'
          ? <span style={{ marginLeft: 8, fontSize: 11, fontWeight: 700, color: 'var(--blue)', background: 'var(--blue-bg)', borderRadius: 10, padding: '1px 8px', whiteSpace: 'nowrap' }}>Suivi back-office</span>
          : <span className="muted" style={{ marginLeft: 8, fontSize: 11, whiteSpace: 'nowrap' }}>· géré dans Rivage</span>}
        {i.aide && <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div>}
        {parRivage && <div style={{ fontSize: 13 }}>D’après {i.detail.replace(/^Rivage : /, 'Rivage : ')}{peut && <button className="lien" onClick={() => setCorriger(true)}>Corriger</button>}</div>}
        {i.detail && i.mode !== 'fiche' && !parRivage && <div style={{ fontSize: 13 }}>{i.mode === 'rivage' ? 'Rivage : ' : ''}{i.detail}</div>}
        {i.ia && (i.bloc !== 'rivage' || ecart) && !(i.bloc === 'pieces' && !i.ia.valeur) && <div style={{ fontSize: 13, background: 'var(--blue-bg)', padding: '4px 8px', borderRadius: 6, marginTop: 4 }}>
          ✦ Lu dans le bail : {i.ia.valeur || (i.ia.trouve === false ? 'non trouvé' : '—')}{i.ia.page ? ` (page ${i.ia.page})` : ''}
          {i.ia.extrait && <div className="muted" style={{ fontSize: 12 }}>« {i.ia.extrait} »</div>}</div>}
        {i.mode === 'fiche' && !parRivage && <div style={{ marginTop: 4 }}><ChampFiche b={b} fiche={d.fiche} champ={i.ref} peut={peut} agir={agir} /></div>}
        {i.repondu && <div className="muted" style={{ fontSize: 12 }}>Répondu par {i.par || '—'} le {date(i.le)}{i.commentaire ? ' · ' + i.commentaire : ''}</div>}
        {i.repondu && ecart && i.statut === 'ok' && !i.commentaire && <div style={{ fontSize: 12, color: 'var(--red)', fontWeight: 600 }}>Écart validé sans justification : revenez sur la réponse pour l’expliquer ou corriger Rivage.</div>}
        {errJ && <div className="err">{errJ}</div>}
      </div>
      {peut && i.repondu && <div className="row" style={{ justifyContent: 'flex-end' }}><button className="btn gris" onClick={() => revenir()}>Revenir sur ma réponse</button></div>}
      {!peut && !i.repondu && (i.mode === 'document' || i.bloc === 'rivage') && <div className="row" style={{ justifyContent: 'flex-end' }}>
        <a className="btn" href={'https://rivage.immo/leasing_contracts?leasing_contract_id=' + b.bail_id} target="_blank" rel="noreferrer">{i.mode === 'document' ? 'Déposer dans Rivage ↗' : 'Corriger dans Rivage ↗'}</a></div>}
      {peut && !i.repondu && !parRivage && !(i.genere && i.genere !== 'garantie') && <div className="row" style={{ justifyContent: 'flex-end' }}>
        {i.mode === 'document'
          ? <><a className="btn" href={'https://rivage.immo/leasing_contracts?leasing_contract_id=' + b.bail_id} target="_blank" rel="noreferrer">Déposer dans Rivage ↗</a>
              <button className="btn gris" onClick={() => repondre('sans_objet')}>Sans objet</button></>
          : <>
            {motif && <input autoFocus placeholder={motif === 'ok' ? 'Cause de l’écart et justificatif (avenant du…, indexation…)' : 'Quelle anomalie ?'} value={com} onChange={(e) => setCom(e.target.value)} style={{ width: 280 }} />}
            {i.bloc === 'rivage' && !motif && <a className={'btn' + (ecart ? ' plein' : '')} href={'https://rivage.immo/leasing_contracts?leasing_contract_id=' + b.bail_id} target="_blank" rel="noreferrer">Corriger dans Rivage ↗</a>}
            {(!motif || motif === 'ok') && <button className="btn" onClick={() => repondre('ok')}>{motif === 'ok' ? 'Valider conforme' : 'Conforme'}</button>}
            {i.bloc !== 'rivage' && (!motif || motif === 'anomalie') && <button className="btn" onClick={() => repondre('anomalie')}>{motif === 'anomalie' ? 'Valider l’anomalie' : 'Anomalie'}</button>}
            {motif ? <button className="lien" onClick={() => { setMotif(null); setErrJ(''); }}>Annuler</button>
              : <button className="btn gris" onClick={() => repondre('sans_objet')}>Sans objet</button>}
          </>}
      </div>}
    </div>
    {peut && i.genere && i.genere !== 'garantie' && !i.repondu && !parRivage && <QuestionSuivi i={i} d={d} b={b} agir={agir} />}
    {suiviExiste && <div className="muted" style={{ fontSize: 12 }}>Suivi « {NATURES[i.genere]} » en place : {(d.obligations || []).filter((o) => o.nature === i.genere && o.actif).map((o) => `${o.libelle} (échéance ${date(o.prochaine)})`).join(' · ')}</div>}
    {peut && i.genere && i.repondu && i.statut !== 'sans_objet' && (creer
      ? <NouveauSuivi b={b} nature={i.genere} agir={agir} fini={() => setCreer(false)} />
      : <button className="lien" onClick={() => setCreer(true)}>+ Ajouter un autre suivi « {NATURES[i.genere]} »</button>)}
  </div>;
}

// ----- Questions de suivi selon la nature de l'obligation : la réponse crée directement les suivis et leurs relances -----
const EQUIPEMENTS_HAB = ['Chaudière gaz', 'Chaudière fioul', 'Pompe à chaleur', 'Ballon thermodynamique', 'Cheminée ou insert', 'Fosse septique', 'Citerne gaz'];
const EQUIPEMENTS_COM = ['Chaudière ou chaufferie', 'Climatisation', 'Extincteurs', 'Portes et rideaux métalliques', 'Système de sécurité incendie', 'Séparateur d’hydrocarbures', 'Ventilation, extraction'];
const COMPTEURS = ['Eau froide', 'Eau chaude', 'Chauffage', 'Électricité', 'Gaz'];
const plus = (iso, mois) => { const x = new Date(iso); x.setMonth(x.getMonth() + mois); return x.toISOString().slice(0, 10); };
const prochainRelevé = () => { const a = new Date(); const y = a.getFullYear(); const juin = `${y}-06-30`, dec = `${y}-12-31`; return auj() <= juin ? juin : dec; };
const prochainMars = () => { const y = new Date().getFullYear(); return auj() < `${y}-03-01` ? `${y}-03-01` : `${y + 1}-03-01`; };
const prochainSept = () => { const y = new Date().getFullYear(); return auj() < `${y}-09-30` ? `${y}-09-30` : `${y + 1}-09-30`; };

function QuestionSuivi({ i, d, b, agir }) {
  const commercial = d.controle?.portee === 'commercial';
  const n = i.genere;
  const rv = d.rivage || {};
  // Pré-remplissage depuis Rivage : chauffage individuel gaz, fioul ou pompe à chaleur, dernier entretien de chaudière
  const [v, setV] = useState(() => {
    if (n !== 'entretien' || rv.type_chauffage === 'collective') return {};
    const eq = { gas: commercial ? 'Chaudière ou chaufferie' : 'Chaudière gaz', fuel: commercial ? 'Chaudière ou chaufferie' : 'Chaudière fioul', fuel_oil: commercial ? 'Chaudière ou chaufferie' : 'Chaudière fioul',
      oil: commercial ? 'Chaudière ou chaufferie' : 'Chaudière fioul', heat_pump: commercial ? 'Climatisation' : 'Pompe à chaleur' }[rv.chauffage];
    return eq ? { ['eq_' + eq]: true, ['d_' + eq]: rv.entretien_chaudiere || '' } : {};
  });
  const [err, setErr] = useState('');
  const maj = (k, x) => setV((o) => ({ ...o, [k]: x }));
  // Équipements et compteurs saisis au contrôle du mandat pour ce lot : repris ici (cases pré-cochées, date du dernier entretien)
  const [dumandat, setDumandat] = useState([]);
  useEffect(() => {
    if (n !== 'entretien' && n !== 'compteur') return;
    rpc('pilotage_bail_equipements', { p_bail: b.bail_id }).then((l) => {
      const liste = (l || []).filter((e) => e.nature === (n === 'entretien' ? 'equipement' : 'compteur'));
      setDumandat(liste);
      if (!liste.length) return;
      setV((o) => {
        const x = { ...o };
        const connus = n === 'entretien' ? (commercial ? EQUIPEMENTS_COM : EQUIPEMENTS_HAB) : COMPTEURS;
        liste.forEach((e) => {
          const nom = connus.find((c) => c.toLowerCase() === e.libelle.toLowerCase()) || e.libelle;
          if (n === 'compteur') { if (connus.includes(nom)) x['c_' + nom] = true; return; }
          if (!connus.includes(nom) && !x.autre) x.autre = nom;
          x['eq_' + nom] = true;
          if (e.dernier_entretien && !x['d_' + nom]) x['d_' + nom] = e.dernier_entretien;
        });
        return x;
      });
    }).catch(() => {});
  }, [b.bail_id, n]);
  const repris = dumandat.length > 0 && <div style={{ fontSize: 12, color: 'var(--blue)' }}>Repris du contrôle du mandat : {dumandat.map((e) => e.libelle + (e.contrat_entretien ? ` (contrat d’entretien${e.prestataire ? ' ' + e.prestataire : ''})` : '')).join(', ')}.</div>;
  const CHAUF = { gas: 'gaz', electric: 'électrique', fuel: 'fioul', fuel_oil: 'fioul', oil: 'fioul', heat_pump: 'pompe à chaleur', wood: 'bois' };
  const infoRivage = rv.chauffage ? `Rivage : chauffage ${rv.type_chauffage === 'collective' ? 'collectif' : rv.type_chauffage === 'individual' ? 'individuel' : ''} ${CHAUF[rv.chauffage] || rv.chauffage}${rv.entretien_chaudiere ? ', dernier entretien de chaudière le ' + date(rv.entretien_chaudiere) : ''}.` : 'Rivage : mode de chauffage non renseigné pour ce lot.';
  const creer = async (liste, statut, resume) => {
    setErr('');
    try {
      for (const o of liste) await rpc('pilotage_bail_obligation', { p_bail: b.bail_id, p_id: null, p_nature: n, p_libelle: o.libelle, p_periodicite: o.per ?? null, p_prochaine: o.date, p_actif: true });
      await agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: statut, p_suivi: liste.length ? 'backoffice' : null, p_valeur: resume, p_commentaire: statut === 'anomalie' ? resume : null });
    } catch (e) { setErr(e.message); }
  };
  const boite = (contenu) => <div style={{ margin: '6px 0', background: 'var(--bg)', padding: 10, borderRadius: 8, fontSize: 14 }}>{contenu}{err && <div className="err">{err}</div>}</div>;

  if (n === 'assurance') return boite(<>
    <div className="row"><b>Assurance du {commercial ? 'preneur' : 'locataire'}</b></div>
    <div className="row" style={{ marginTop: 6 }}>
      <label>Échéance de l’attestation en cours <input type="date" value={v.date || ''} onChange={(e) => maj('date', e.target.value)} /></label>
      <button className="btn plein" disabled={!v.date} onClick={() => creer([{ libelle: 'Attestation d’assurance', date: v.date, per: 12 }], 'ok', 'Attestation valable jusqu’au ' + date(v.date))}>Valider et suivre</button>
      <button className="btn" onClick={() => creer([{ libelle: 'Attestation d’assurance', date: auj(), per: 12 }], 'anomalie', 'Aucune attestation reçue : relance immédiate')}>Pas d’attestation reçue</button>
    </div></>);

  if (n === 'entretien') {
    const liste = commercial ? EQUIPEMENTS_COM : EQUIPEMENTS_HAB;
    const coches = liste.concat(v.autre ? [v.autre] : []).filter((e) => v['eq_' + e]);
    return boite(<>
      <div><b>Équipements à entretenir à la charge du {commercial ? 'preneur' : 'locataire'}</b> <span className="muted">(un suivi annuel par équipement)</span></div>
      {repris}
      <div className="muted" style={{ fontSize: 12 }}>{infoRivage}{rv.type_chauffage === 'collective' ? ' Chauffage collectif : son entretien relève de la copropriété, pas du locataire.' : ''}</div>
      {liste.map((e) => <div key={e} className="row" style={{ marginTop: 4 }}>
        <label style={{ minWidth: 220 }}><input type="checkbox" checked={!!v['eq_' + e]} onChange={(x) => maj('eq_' + e, x.target.checked)} /> {e}</label>
        {v['eq_' + e] && <label className="muted">Dernier entretien le <input type="date" value={v['d_' + e] || ''} onChange={(x) => maj('d_' + e, x.target.value)} /></label>}
      </div>)}
      <div className="row" style={{ marginTop: 4 }}><input placeholder="Autre équipement" value={v.autre || ''} onChange={(e) => maj('autre', e.target.value)} />
        {v.autre && <label><input type="checkbox" checked={!!v['eq_' + v.autre]} onChange={(x) => maj('eq_' + v.autre, x.target.checked)} /> suivre</label>}
        {v.autre && v['eq_' + v.autre] && <label className="muted">Dernier entretien le <input type="date" value={v['d_' + v.autre] || ''} onChange={(x) => maj('d_' + v.autre, x.target.value)} /></label>}</div>
      <p className="muted" style={{ fontSize: 12, margin: '4px 0' }}>Sans date du dernier entretien, le justificatif est demandé tout de suite.</p>
      <div className="row">
        <button className="btn plein" disabled={!coches.length} onClick={() => creer(coches.map((e) => ({ libelle: 'Entretien ' + e.toLowerCase(), date: v['d_' + e] ? plus(v['d_' + e], 12) : plus(auj(), 1), per: 12 })), 'ok', 'Équipements suivis : ' + coches.join(', '))}>Valider et suivre</button>
        <button className="btn gris" onClick={() => creer([], 'sans_objet', 'Aucun équipement à entretenir')}>Aucun équipement</button>
      </div></>);
  }

  if (n === 'compteur') {
    const coches = COMPTEURS.filter((c) => v['c_' + c]);
    return boite(<>
      <div><b>Compteurs du logement</b></div>
      {repris}
      <div className="row" style={{ marginTop: 6 }}>
        <button className="btn gris" onClick={() => creer([], 'sans_objet', 'Compteurs individuels : rien à relever')}>Tous individuels</button>
        <span className="muted">ou compteurs divisionnaires :</span>
        {COMPTEURS.map((c) => <label key={c}><input type="checkbox" checked={!!v['c_' + c]} onChange={(x) => maj('c_' + c, x.target.checked)} /> {c}</label>)}
      </div>
      {coches.length > 0 && <div className="row" style={{ marginTop: 6 }}>
        <label>Prochain relevé le <input type="date" value={v.date || prochainRelevé()} onChange={(e) => maj('date', e.target.value)} /></label>
        <span className="muted" style={{ fontSize: 12 }}>Tous les 6 mois, calé sur la régularisation des charges.</span>
        <button className="btn plein" onClick={async () => {
          // Les compteurs cochés sont créés sur le lot s'ils n'y sont pas encore (situation et relevés se saisissent ensuite dans le suivi)
          try {
            const lc = await rpc('pilotage_bail_compteurs', { p_bail: b.bail_id });
            for (const nom of coches) if (lc?.lot && !(lc.compteurs || []).some((x) => x.libelle.toLowerCase() === nom.toLowerCase()))
              await rpc('pilotage_lot_equipement', { p_asset: lc.lot, p_id: null, p_nature: 'compteur', p_libelle: nom, p_contrat: null, p_prestataire: null, p_dernier: null, p_commentaire: null, p_supprimer: false });
          } catch { /* les compteurs pourront être ajoutés depuis le suivi */ }
          await creer([{ libelle: 'Relevé ' + coches.join(', ').toLowerCase(), date: v.date || prochainRelevé(), per: 6 }], 'ok', 'Divisionnaires : ' + coches.join(', '));
        }}>Valider et suivre</button>
      </div>}</>);
  }

  if (n === 'caution') return boite(<>
    <div><b>Caution</b></div>
    <div className="row" style={{ marginTop: 6 }}>
      <button className="btn gris" onClick={() => creer([], 'sans_objet', 'Pas de caution')}>Pas de caution</button>
      <button className="btn" onClick={() => creer([], 'ok', 'Caution à durée indéterminée')}>Durée indéterminée</button>
      <label>Engagement limité jusqu’au <input type="date" value={v.date || ''} onChange={(e) => maj('date', e.target.value)} /></label>
      <button className="btn plein" disabled={!v.date} onClick={() => creer([{ libelle: 'Fin d’engagement de la caution', date: v.date, per: null }], 'ok', 'Caution jusqu’au ' + date(v.date))}>Valider et suivre</button>
    </div></>);

  if (n === 'dpe') return boite(<>
    <div><b>Diagnostic de performance énergétique</b></div>
    <div className="row" style={{ marginTop: 6 }}>
      <label>Classe <select value={v.classe || ''} onChange={(e) => maj('classe', e.target.value)}><option value="">—</option>{['A', 'B', 'C', 'D', 'E', 'F', 'G'].map((c) => <option key={c}>{c}</option>)}</select></label>
      <label>Fin de validité <input type="date" value={v.date || ''} onChange={(e) => maj('date', e.target.value)} /></label>
      <button className="btn plein" disabled={!v.date || (!commercial && !v.classe)} onClick={() => creer([{ libelle: 'Validité du DPE' + (v.classe ? ' (classe ' + v.classe + ')' : ''), date: v.date, per: null }],
        !commercial && ['F', 'G'].includes(v.classe) ? 'anomalie' : 'ok', (v.classe ? 'Classe ' + v.classe + ', ' : '') + 'valide jusqu’au ' + date(v.date) + (!commercial && ['F', 'G'].includes(v.classe) ? ' : loyer gelé à la révision' : ''))}>Valider et suivre</button>
      <button className="btn" onClick={() => creer([], 'anomalie', 'Pas de DPE au dossier')}>Pas de DPE</button>
    </div></>);

  if (n === 'tsb') return boite(<>
    <div><b>Taxe sur les bureaux (Île-de-France)</b></div>
    <div className="row" style={{ marginTop: 6 }}>
      <button className="btn gris" onClick={() => creer([], 'sans_objet', 'Lot non concerné')}>Lot non concerné</button>
      <button className="btn" onClick={() => creer([], 'ok', 'Lot concerné, refacturation non prévue au bail')}>Concerné, non refacturable</button>
      <button className="btn plein" onClick={() => creer([{ libelle: 'Taxe sur les bureaux à refacturer', date: prochainMars(), per: 12 }], 'ok', 'Concerné et refacturable au preneur')}>Concerné et refacturable : suivre</button>
    </div></>);

  if (n === 'surprime') return boite(<>
    <div><b>Surprime d’assurance liée à l’activité du preneur</b></div>
    <div className="row" style={{ marginTop: 6 }}>
      <button className="btn gris" onClick={() => creer([], 'sans_objet', 'Pas de clause de surprime')}>Pas de clause</button>
      <label>Renouvellement du contrat d’assurance de l’immeuble le <input type="date" value={v.date || ''} onChange={(e) => maj('date', e.target.value)} /></label>
      <button className="btn plein" disabled={!v.date} onClick={() => creer([{ libelle: 'Surprime d’assurance à vérifier et refacturer', date: v.date, per: 12 }], 'ok', 'Clause de surprime refacturable')}>Valider et suivre</button>
    </div></>);

  if (n === 'tertiaire') return boite(<>
    <div><b>Décret tertiaire</b></div>
    <div className="row" style={{ marginTop: 6 }}>
      <button className="btn gris" onClick={() => creer([], 'sans_objet', 'Moins de 1 000 m² tertiaires')}>Non concerné</button>
      <button className="btn plein" onClick={() => creer([{ libelle: 'Déclaration OPERAT', date: prochainSept(), per: 12 }], 'ok', 'Concerné : déclaration annuelle')}>Concerné : suivre</button>
    </div></>);

  // Régularisation des charges, état des travaux, destination : une échéance et une périodicité
  const PAR_DEFAUT = { charges_regul: ['Régularisation des charges et état récapitulatif', 12], etat_travaux: ['État prévisionnel des travaux', 36], destination: ['Contrôle de la destination des lieux', 12],
    dg_ajust: ['Ajustement du dépôt de garantie à la révision (prochaine date de révision)', 12] };
  const [lib, per] = PAR_DEFAUT[n] || [NATURES[n], PERIODE[n] ?? 12];
  return boite(<div className="row">
    <b>{lib}</b>
    <label>Prochaine échéance <input type="date" value={v.date || ''} onChange={(e) => maj('date', e.target.value)} /></label>
    <button className="btn plein" disabled={!v.date} onClick={() => creer([{ libelle: lib, date: v.date, per }], 'ok', lib + ' : prochaine échéance le ' + date(v.date))}>Valider et suivre</button>
    <button className="btn gris" onClick={() => creer([], 'sans_objet', 'Non prévu au bail')}>Non prévu au bail</button>
  </div>);
}

function NouveauSuivi({ b, nature: n0, agir, fini }) {
  const [nature, setNature] = useState(n0 || 'assurance');
  const [libelle, setLibelle] = useState(NATURES[n0 || 'assurance']);
  const [per, setPer] = useState(PERIODE[n0 || 'assurance'] ?? '');
  const [proch, setProch] = useState(nature === 'tsb' ? `${new Date().getFullYear() + 1}-03-01` : '');
  return <div className="row" style={{ margin: '6px 0', background: 'var(--bg)', padding: 8, borderRadius: 8 }}>
    {!n0 && <select value={nature} onChange={(e) => { setNature(e.target.value); setLibelle(NATURES[e.target.value]); setPer(PERIODE[e.target.value] ?? ''); }} aria-label="Nature du suivi">
      {Object.entries(NATURES).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>}
    <input value={libelle} onChange={(e) => setLibelle(e.target.value)} placeholder="Libellé (ex. chaudière gaz)" aria-label="Libellé" />
    <label className="muted">Échéance <input type="date" value={proch} onChange={(e) => setProch(e.target.value)} /></label>
    <label className="muted">Tous les <input type="number" value={per} onChange={(e) => setPer(e.target.value)} style={{ width: 60 }} /> mois</label>
    <button className="btn plein" disabled={!proch} onClick={async () => { await agir('pilotage_bail_obligation', { p_bail: b.bail_id, p_id: null, p_nature: nature, p_libelle: libelle, p_periodicite: per === '' ? null : Number(per), p_prochaine: proch, p_actif: true }); fini(); }}>Créer</button>
    <button className="lien" onClick={fini}>Annuler</button>
  </div>;
}

// Assurance (habitation) : choix du bailleur avant la mise en demeure, que la loi oblige à annoncer (art. 7 g)
function ChoixAssurance({ ob, agir, lien }) {
  const choisir = (c) => agir('pilotage_assurance_choix', { p_cle: ob.cle, p_choix: c });
  const cls = lien ? 'lien' : 'btn';
  return <>
    {' '}<button className={cls} style={lien ? { marginLeft: 8 } : null} disabled={ob.choix === 'compte'} onClick={() => choisir('compte')}>Bailleur : souscription pour compte</button>
    {' '}<button className={cls} style={lien ? { marginLeft: 8 } : null} disabled={ob.choix === 'commandement'} onClick={() => choisir('commandement')}>Bailleur : commandement</button>
  </>;
}

// ----- Suivis récurrents -----
function Suivis({ d, b, peut, agir }) {
  const [ajout, setAjout] = useState(false);
  const obs = d.obligations || [];
  return <>
    <h3>Suivis et relances</h3>
    {!obs.length && <p className="muted">Aucun suivi pour ce bail. Ils se créent depuis le contrôle d’entrée ou ici.</p>}
    {obs.map((o) => <details key={o.id} className={'mini-alerte ' + (o.actif ? o.gravite : 'normale')} style={{ opacity: o.actif ? 1 : 0.6 }}>
      <summary style={{ cursor: 'pointer' }}><b>{o.libelle}</b> · {NATURES[o.nature]} · échéance le {date(o.prochaine)}{o.periodicite_mois ? ` · tous les ${o.periodicite_mois} mois` : ''}{!o.actif ? ' · clos' : o.en_retard ? ' · en retard' : ''}</summary>
      <ol className="etapes">{(o.etapes || []).map((e) => <li key={e.ordre} className={e.fait_le ? 'fait' : e.du ? 'retard' : ''}>
        <span className="puce">{e.fait_le ? '✓' : ''}</span><span>{e.libelle}<span className="muted"> · {date(e.date)}{e.fait_le ? ' · fait le ' + date(e.fait_le) : ''}</span>
        {peut && e.fait_le && <button className="lien" style={{ marginLeft: 8 }} onClick={() => agir('pilotage_suivi_etape', { p_cle: o.cle, p_etape: String(e.ordre), p_detail: null, p_annuler: true })}>Annuler</button>}</span></li>)}</ol>
      {o.nature === 'assurance' && <div className="muted">Choix du bailleur si l’attestation manque : {o.choix === 'commandement' ? 'commandement par commissaire de justice' : o.choix === 'compte' ? 'souscription pour compte du locataire' : 'non donné (souscription pour compte par défaut)'}{peut && o.actif && <ChoixAssurance ob={o} agir={agir} lien />}</div>}
      {o.derniere_le && <div className="muted">Dernière réalisation : {date(o.derniere_le)}</div>}
      {o.nature === 'compteur' && <RelevesBail b={b} ob={o} peut={peut} agir={agir} />}
      {CATEG_JUSTIF[o.nature] && <div className="muted" style={{ fontSize: 12 }}>Justificatif à déposer dans Rivage, catégorie « {CATEG_JUSTIF[o.nature]} » : reconnu automatiquement (passage toutes les 30 minutes).</div>}
      {peut && <div className="row" style={{ marginTop: 6 }}>
        {o.nature === 'charges_regul' && o.actif ? <ControleRelevesRegul b={b} obs={obs} ob={o} agir={agir} /> : <Realise ob={o} agir={agir} />}
        <button className="btn gris" onClick={() => agir('pilotage_bail_obligation', { p_bail: b.bail_id, p_id: o.id, p_nature: o.nature, p_libelle: null, p_periodicite: o.periodicite_mois, p_prochaine: null, p_actif: !o.actif })}>{o.actif ? 'Arrêter ce suivi' : 'Réactiver'}</button>
      </div>}
    </details>)}
    {peut && (ajout ? <NouveauSuivi b={b} agir={agir} fini={() => setAjout(false)} /> : <button className="lien" onClick={() => setAjout(true)}>+ Ajouter un suivi (assurance, équipement, compteurs…)</button>)}
  </>;
}

// Garde-fou de la régularisation des charges : si le lot a des compteurs divisionnaires, chaque compteur doit avoir un relevé
// à la dernière date fixe de relevé (tolérance 7 jours avant, pour un relevé fait dès le mail de prévenance).
// Sans relevé, la régul ne peut être validée qu'en cochant explicitement qu'elle est faite sans relevé (estimation).
const moinsMois = (x, n) => { const t = new Date(x); t.setMonth(t.getMonth() - n); return t.toISOString().slice(0, 10); };
const moinsJours = (x, n) => { const t = new Date(x); t.setDate(t.getDate() - n); return t.toISOString().slice(0, 10); };
function ControleRelevesRegul({ b, obs, ob, agir }) {
  const [c, setC] = useState(null); const [err, setErr] = useState(''); const [force, setForce] = useState(false);
  useEffect(() => { rpc('pilotage_bail_compteurs', { p_bail: b.bail_id }).then(setC).catch((e) => setErr(e.message)); }, [b.bail_id]);
  if (err) return <><div className="err">Contrôle des relevés impossible : {err}</div><Realise ob={ob} agir={agir} /></>;
  if (!c) return <span className="muted">Vérification des relevés de compteurs…</span>;
  const compteurs = c.compteurs || [];
  if (!compteurs.length) return <Realise ob={ob} agir={agir} />;
  const auj0 = auj();
  const suivi = obs.find((x) => x.nature === 'compteur' && x.actif);
  // Dernière date fixe de relevé déjà atteinte : l'échéance du suivi si elle est passée, sinon celle d'avant
  const derniereDate = suivi?.prochaine ? (suivi.prochaine <= auj0 ? suivi.prochaine : moinsMois(suivi.prochaine, suivi.periodicite_mois || 6)) : null;
  const manquants = derniereDate
    ? compteurs.filter((x) => !(x.releves || []).some((r) => r.le >= moinsJours(derniereDate, 7)))
    : compteurs;
  if (!manquants.length) return <><span className="muted" style={{ fontSize: 12 }}>Relevés du {date(derniereDate)} saisis pour tous les compteurs.</span><Realise ob={ob} agir={agir} /></>;
  return <div style={{ width: '100%' }}>
    <div className="err">
      {suivi ? <>Relevé du {date(derniereDate)} manquant pour : {manquants.map((x) => x.libelle).join(', ')}.</>
        : <>Le lot a des compteurs divisionnaires mais aucun suivi « Relevé des compteurs » n’est actif sur ce bail.</>}
      {' '}La régularisation partirait sur une estimation : saisir d’abord les relevés dans le suivi des compteurs.
    </div>
    <label className="muted" style={{ fontSize: 12 }}><input type="checkbox" checked={force} onChange={(e) => setForce(e.target.checked)} /> Régularisation faite sans ces relevés, en connaissance de cause</label>
    {force && <div style={{ marginTop: 4 }}><Realise ob={ob} agir={agir} /></div>}
  </div>;
}

// Relevés des compteurs divisionnaires du lot, depuis le suivi du bail : saisie, consommation entre relevés, montant à refacturer.
function RelevesBail({ b, ob, peut, agir }) {
  const [c, setC] = useState(null); const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_bail_compteurs', { p_bail: b.bail_id }).then(setC).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, [b.bail_id]);
  if (!c) return err ? <div className="err">{err}</div> : null;
  const auj0 = auj();
  const relevesDuJour = (c.compteurs || []).filter((x) => (x.releves || []).some((r) => r.le === auj0)).length;
  return <div style={{ marginTop: 6 }}>
    {err && <div className="err">{err}</div>}
    {c.lot ? <Compteurs asset={c.lot} compteurs={c.compteurs || []} bail={b.bail_id} typeDefaut="periodique" recharger={charger} onErreur={setErr} />
      : <div className="muted">Lot du bail inconnu dans Rivage.</div>}
    {peut && (c.compteurs || []).length > 0 && <div className="row" style={{ marginTop: 4 }}>
      <button className="btn plein" disabled={!relevesDuJour} onClick={() => agir('pilotage_obligation_realisee', { p_id: ob.id, p_le: auj0, p_prochaine: null })}>
        Relevé fait : passer à l’échéance suivante</button>
      {!relevesDuJour && <span className="muted" style={{ fontSize: 12 }}>Saisir d’abord au moins un relevé du jour.</span>}</div>}
  </div>;
}

// ----- Paliers et franchises -----
function Paliers({ d, b, peut, agir, ouvrirMail }) {
  const [f, setF] = useState({ nature: 'palier', debut: '', fin: '', loyer: '', com: '' });
  const ps = d.paliers || [];
  const lus = (d.lecture?.resultat?.paliers || []).filter((x) => x?.debut && !ps.some((p) => p.debut === x.debut));
  const [form, setForm] = useState(false);
  // Rien à afficher : un simple bouton, le formulaire ne s'ouvre qu'à la demande.
  if (!ps.length && !lus.length && !form) return peut ? <div style={{ marginTop: 10 }}><button className="lien" onClick={() => setForm(true)}>+ Ajouter un palier ou une franchise de loyer</button></div> : null;
  return <>
    <h3>Paliers et franchises de loyer</h3>
    {peut && lus.map((x, k) =>
      <div key={k} className="mini-alerte normale">✦ Lu dans le bail : {x.nature === 'franchise' ? 'franchise' : 'palier'} du {date(x.debut)}{x.fin ? ' au ' + date(x.fin) : ''}{x.loyer_annuel_ht != null ? `, loyer annuel ${Number(x.loyer_annuel_ht).toLocaleString('fr-FR')} € HT` : ''}{x.page ? ` (page ${x.page})` : ''}
        <button className="lien" style={{ marginLeft: 8 }} onClick={() => { setForm(true); setF({ nature: x.nature === 'franchise' ? 'franchise' : 'palier', debut: x.debut, fin: x.fin || '', loyer: '', com: 'Lu dans le bail' + (x.page ? ', page ' + x.page : '') }); }}>Reprendre (saisir le montant Rivage)</button></div>)}
    {ps.length > 0 && <div className="table-wrap"><table className="table-imp"><thead><tr><th>Nature</th><th>Du</th><th>Au</th><th>Loyer attendu dans Rivage</th><th>Programmé dans Rivage</th><th>Note</th><th></th></tr></thead><tbody>
      {ps.map((p) => <tr key={p.id}><td>{p.nature === 'franchise' ? 'Franchise' : 'Palier'}</td><td>{date(p.debut)}</td><td>{date(p.fin)}</td>
        <td>{p.loyer_rivage != null ? Number(p.loyer_rivage).toLocaleString('fr-FR', { style: 'currency', currency: 'EUR' }) : '—'}</td>
        <td style={{ color: p.programme_rivage ? 'var(--teal)' : 'var(--amber)' }}>{p.programme_rivage ? '✓ ligne d’appel trouvée' : 'Non trouvé'}</td><td>{p.commentaire}</td>
        <td>{peut && <><button className="lien" onClick={() => ouvrirMail('palier_locataire', { palier: p }, { cle: 'e:' + b.bail_id + ':palier' + p.id, etape: 'info', detail: 'Locataire informé du palier' })}>Mail locataire</button>{' '}
          <button className="lien" onClick={() => agir('pilotage_bail_palier', { p_bail: b.bail_id, p_id: p.id, p_nature: null, p_debut: null, p_fin: null, p_loyer: null, p_commentaire: null, p_supprimer: true })}>Supprimer</button></>}</td></tr>)}
    </tbody></table></div>}
    {peut && !form && <button className="lien" onClick={() => setForm(true)}>+ Ajouter un palier ou une franchise</button>}
    {peut && form && <p className="muted" style={{ fontSize: 12 }}>Le montant attendu est saisi dans la même unité que le loyer de Rivage (par appel). Le pilotage rappelle la mise à jour 30 jours avant et signale tout écart avec Rivage une fois le palier commencé.</p>}
    {peut && form && <div className="row">
      <select value={f.nature} onChange={(e) => setF({ ...f, nature: e.target.value })} aria-label="Nature"><option value="palier">Palier</option><option value="franchise">Franchise</option></select>
      <label className="muted">Du <input type="date" value={f.debut} onChange={(e) => setF({ ...f, debut: e.target.value })} /></label>
      <label className="muted">Au <input type="date" value={f.fin} onChange={(e) => setF({ ...f, fin: e.target.value })} /></label>
      <input type="number" placeholder="Loyer attendu" value={f.loyer} onChange={(e) => setF({ ...f, loyer: e.target.value })} style={{ width: 130 }} aria-label="Loyer attendu dans Rivage" />
      <input placeholder="Note (article du bail)" value={f.com} onChange={(e) => setF({ ...f, com: e.target.value })} aria-label="Note" />
      <button className="btn" disabled={!f.debut} onClick={async () => { await agir('pilotage_bail_palier', { p_bail: b.bail_id, p_id: null, p_nature: f.nature, p_debut: f.debut, p_fin: f.fin || null, p_loyer: f.loyer === '' ? (f.nature === 'franchise' ? 0 : null) : Number(f.loyer), p_commentaire: f.com || null, p_supprimer: false }); setF({ nature: 'palier', debut: '', fin: '', loyer: '', com: '' }); setForm(false); }}>Ajouter</button>
      <button className="lien" onClick={() => setForm(false)}>Annuler</button>
    </div>}
  </>;
}

// ----- Actes -----
const ACTES = { demande_renouvellement: 'Demande de renouvellement', conge: 'Congé', refus_renouvellement: 'Refus de renouvellement', reponse: 'Réponse', avenant: 'Avenant', commandement: 'Commandement', autre: 'Autre' };
function Actes({ d, b, peut, agir }) {
  const vide = { nature: 'demande_renouvellement', auteur: 'preneur', signifie: '', forme: 'acte', ref: '', effet: '', com: '' };
  const [f, setF] = useState(vide);
  const as = d.actes || [];
  const [form, setForm] = useState(false);
  if (!as.length && !form) return peut ? <div style={{ marginTop: 4 }}><button className="lien" onClick={() => setForm(true)}>+ Enregistrer un acte reçu (demande de renouvellement, congé du preneur…)</button></div> : null;
  return <>
    <h3>Actes et notifications</h3>
    {as.map((a) => <div key={a.id} className="mini-alerte normale">
      <b>{ACTES[a.nature]}</b> du {a.auteur} · signifié le {date(a.signifie_le)}{a.forme ? ` (${a.forme === 'acte' ? 'acte de commissaire de justice' : a.forme})` : ''}{a.reference ? ` · réf. ${a.reference}` : ''}
      {a.effet_le && <div className="muted">Prise d’effet : {date(a.effet_le)}</div>}
      {a.nature === 'demande_renouvellement' && a.auteur === 'preneur' && <div className={a.reponse_le ? 'muted' : ''} style={{ color: a.reponse_le ? undefined : 'var(--red)' }}>
        {a.reponse_le ? `Réponse du bailleur le ${date(a.reponse_le)}` : `Réponse du bailleur à signifier avant le ${date(new Date(new Date(a.signifie_le).setMonth(new Date(a.signifie_le).getMonth() + 3)))}, sinon il est réputé accepter le principe du renouvellement.`}</div>}
      {a.commentaire && <div className="muted">{a.commentaire}</div>}
      {peut && <div className="row" style={{ marginTop: 4 }}>
        {a.nature === 'demande_renouvellement' && !a.reponse_le && <button className="lien" onClick={() => { const r = prompt('Date de la réponse du bailleur (AAAA-MM-JJ)', auj()); if (r) agir('pilotage_bail_acte', { p_bail: b.bail_id, p_id: a.id, p_nature: a.nature, p_auteur: a.auteur, p_signifie: a.signifie_le, p_forme: a.forme, p_reference: a.reference, p_effet: a.effet_le, p_reponse: r, p_commentaire: a.commentaire, p_supprimer: false }); }}>Réponse faite</button>}
        <button className="lien" onClick={() => agir('pilotage_bail_acte', { p_bail: b.bail_id, p_id: a.id, p_nature: null, p_auteur: null, p_signifie: null, p_forme: null, p_reference: null, p_effet: null, p_reponse: null, p_commentaire: null, p_supprimer: true })}>Supprimer</button>
      </div>}
    </div>)}
    {peut && !form && <button className="lien" onClick={() => setForm(true)}>+ Enregistrer un acte</button>}
    {peut && form && <div className="row">
      <select value={f.nature} onChange={(e) => setF({ ...f, nature: e.target.value })} aria-label="Nature de l’acte">{Object.entries(ACTES).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
      <select value={f.auteur} onChange={(e) => setF({ ...f, auteur: e.target.value })} aria-label="Auteur"><option value="preneur">du preneur</option><option value="bailleur">du bailleur</option></select>
      <label className="muted">Signifié le <input type="date" value={f.signifie} onChange={(e) => setF({ ...f, signifie: e.target.value })} /></label>
      <select value={f.forme} onChange={(e) => setF({ ...f, forme: e.target.value })} aria-label="Forme"><option value="acte">Commissaire de justice</option><option value="lrar">LRAR</option><option value="remise">Remise en main propre</option><option value="autre">Autre</option></select>
      <input placeholder="Référence" value={f.ref} onChange={(e) => setF({ ...f, ref: e.target.value })} style={{ width: 120 }} aria-label="Référence" />
      <label className="muted">Effet le <input type="date" value={f.effet} onChange={(e) => setF({ ...f, effet: e.target.value })} /></label>
      <button className="btn" disabled={!f.signifie} onClick={async () => { await agir('pilotage_bail_acte', { p_bail: b.bail_id, p_id: null, p_nature: f.nature, p_auteur: f.auteur, p_signifie: f.signifie, p_forme: f.forme, p_reference: f.ref || null, p_effet: f.effet || null, p_reponse: null, p_commentaire: f.com || null, p_supprimer: false }); setF(vide); setForm(false); }}>Ajouter</button>
      <button className="lien" onClick={() => setForm(false)}>Annuler</button>
    </div>}
  </>;
}
