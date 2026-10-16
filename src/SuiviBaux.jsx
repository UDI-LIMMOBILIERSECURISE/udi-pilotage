// Suivi des baux et obligations : contrôle d'entrée, échéances et congés, suivis récurrents, paliers, actes.
import React, { useEffect, useMemo, useState } from 'react';
import { supabase, rpc } from './supabase.js';
import { ResumeIA, Tuiles, Filtres } from './App.jsx';
import { preparer, SMS, lienGmail, TYPES_BAIL, DECISIONS, CONSEQUENCES } from './mails.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const auj = () => new Date().toISOString().slice(0, 10);
const jours = (d) => (d ? Math.round((new Date(d) - new Date(auj())) / 86400000) : null);
const SEV = { critique: 'Critique', haute: 'Haute', normale: 'Normale' };
const BLOCS = { pieces: 'Pièces du dossier', rivage: 'Croisement avec Rivage', clauses: 'Clauses et suivis' };
const NATURES = {
  assurance: 'Assurance', entretien: 'Entretien d\'équipement', compteur: 'Relevé de compteurs', garantie: 'Expiration de garantie', caution: 'Fin d\'engagement de la caution',
  dpe: 'Validité du DPE', tsb: 'Taxe sur les bureaux', surprime: 'Surprime d\'assurance', charges_regul: 'Régularisation des charges', etat_travaux: 'État prévisionnel des travaux',
  tertiaire: 'Décret tertiaire (OPERAT)', destination: 'Contrôle de la destination',
};
const PERIODE = { assurance: 12, entretien: 12, compteur: 6, tsb: 12, surprime: 12, charges_regul: 12, etat_travaux: 36, tertiaire: 12, destination: 12 };
const ETATS = {
  a_venir: 'À venir', a_informer: 'Bailleur à informer', attente_bailleur: 'Réponse du bailleur attendue', reconduit: 'Reconduit (sans réponse)', decide: 'Décision prise',
  conge_a_delivrer: 'Congé à délivrer', conge_delivre: 'Congé délivré', hors_delai: 'Délai dépassé', fin_auto: 'Fin automatique', info: 'Contrat à vérifier',
  derogatoire_terme: 'Opposition urgente', derogatoire_depasse: 'Dérogatoire dépassé', incomplet: 'Fiche incomplète',
};
const CANAL = { mail_locataire: 'Mail au locataire', mail_bailleur: 'Mail au bailleur', sms_rivage: 'SMS (Rivage)', lrar: 'Recommandé', tache: 'Tâche' };

function useEmail() {
  const [e, setE] = useState('');
  useEffect(() => { supabase.auth.getSession().then(({ data }) => setE(data?.session?.user?.email || '')); }, []);
  return e;
}

export default function SuiviBaux({ moi }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [filtre, setFiltre] = useState('traiter');
  const [sel, setSel] = useState(null);
  const [cherche, setCherche] = useState('');
  const charger = () => rpc('pilotage_baux').then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;

  const baux = d.baux;
  const aFaire = (b) => !!b.echeance?.action || b.obligations.some((o) => o.a_faire || o.en_retard);
  const grave = (b) => b.echeance?.gravite === 'critique' || b.obligations.some((o) => o.gravite === 'critique') || !!b.echeance?.alerte_derogatoire;
  const aValider = (b) => !b.controle?.go_le;
  const commercial = (b) => ['commercial', 'derogatoire', 'professionnel'].includes(b.echeance?.type);
  const dans12 = (b) => { const j = jours(b.echeance?.echeance); return j != null && j <= 365; };
  const tests = { traiter: (b) => aFaire(b) || grave(b), valider: aValider, douze: dans12, commerciaux: commercial, tous: () => true };
  const q = cherche.trim().toLowerCase();
  const vus = baux.filter(tests[filtre]).filter((b) => !q || [b.reference, b.locataires, b.adresse, b.bailleur, b.mandat].join(' ').toLowerCase().includes(q));
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
      <input className="recherche" placeholder="Rechercher (bail, locataire, adresse, bailleur)" value={cherche} onChange={(e) => setCherche(e.target.value)} aria-label="Rechercher un bail" />
    </div>
    {s ? <section className="panneau" style={{ marginTop: 8 }}>
      <button className="btn" onClick={() => setSel(null)}>← Retour à la liste</button>
      <div style={{ maxWidth: 980, marginTop: 10 }}><DossierBail b={s} peut={d.peut} moi={moi} apres={charger} /></div>
    </section> : <>
      <div className="grille-cartes grille-baux">{vus.map((b) => {
        const e = b.echeance || {}; const g = grave(b) ? 'critique' : aFaire(b) ? 'haute' : 'normale';
        const prochaine = e.action_libelle || b.obligations.find((o) => o.a_faire)?.a_faire?.libelle;
        return <button key={b.bail_id} className={'kcarte ' + (sel === b.bail_id ? 'sel ' : '') + g} onClick={() => { setSel(b.bail_id); window.scrollTo({ top: 0, behavior: 'smooth' }); }}>
          <div className="row" style={{ justifyContent: 'space-between' }}>
            <span className="mono muted">Bail {b.reference} · {TYPES_BAIL[e.type] || 'type ?'}{e.type && !e.type_confirme ? ' (suggéré)' : ''}</span>
            {b.controle?.go_le ? <span className="sev normale">GO</span> : <span className="sev haute">À valider</span>}
          </div>
          <div className="kcarte-titre">{b.locataires || '—'}</div>
          <div className="muted">{b.adresse}</div>
          <div className="grid2" style={{ marginTop: 6 }}>
            <span className="muted">Bailleur</span><span>{b.bailleur || '—'}</span>
            <span className="muted">Échéance</span><span>{e.echeance ? date(e.echeance) + (e.mode === 'prolongation' ? ' (prolongation)' : '') : '—'}</span>
            <span className="muted">Situation</span><span>{ETATS[e.etat] || e.etat || '—'}</span>
          </div>
          {prochaine && <div style={{ marginTop: 6, fontSize: 13, color: g === 'critique' ? 'var(--red)' : 'var(--amber)' }}>→ {prochaine}</div>}
          {!b.controle?.go_le && b.controle?.restant > 0 && <div className="muted" style={{ marginTop: 4 }}>{b.controle.restant} point(s) de contrôle à traiter</div>}
        </button>; })}</div>
      {!vus.length && <div className="card">Aucun bail avec ce filtre.</div>}
    </>}
  </>;
}

// ===== Détail d'un bail =====

function DossierBail({ b, peut, moi, apres }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [mail, setMail] = useState(null); // { m, etape: { cle, etape, detail } }
  const email = useEmail();
  const charger = () => rpc('pilotage_bail_dossier', { p_bail: b.bail_id }).then(setD).catch((e) => setErr(e.message));
  useEffect(() => { setD(null); setMail(null); charger(); }, [b.bail_id]);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;

  const agir = async (fn, args) => { setErr(''); try { await rpc(fn, args); await charger(); apres(); } catch (e) { setErr(e.message); } };
  const ech = d.echeance || {}; const fiche = d.fiche || {};
  const ctx = { bail: b, fiche, ech, contacts: d.contacts, moi: { prenom: moi.prenom, email } };
  const ouvrirMail = (code, extra, etape) => {
    const m = preparer(code, { ...ctx, ...extra });
    if (m) setMail({ m, etape });
  };
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
    {ech.alerte_derogatoire && <div className="mini-alerte critique">{ech.alerte_derogatoire}</div>}

    <h3>À faire maintenant</h3>
    {!actions.length && <p className="muted">Rien à faire aujourd’hui sur ce bail.</p>}
    {actions.map((a) => <div key={a.k} className={'mini-alerte ' + (a.grav || 'normale')}>
      <b>{SEV[a.grav] || 'Normale'}</b> · {a.libelle}
      {a.ob && <div className="muted">{a.ob.libelle} · échéance le {date(a.ob.prochaine)} · {CANAL[a.ob.a_faire.canal]} prévu le {date(a.ob.a_faire.date)}</div>}
      {peut && <div className="row" style={{ marginTop: 6 }}>
        {a.ech && ech.action === 'informer' && <button className="btn plein" onClick={() => ouvrirMail('echeance_info', {}, { cle: ech.cle, etape: 'informe', detail: 'Bailleur informé' })}>Préparer le mail au bailleur</button>}
        {a.ech && ech.action === 'relancer' && <button className="btn plein" onClick={() => ouvrirMail('echeance_relance', {}, { cle: ech.cle, etape: 'relance', detail: 'Bailleur relancé' })}>Préparer la relance</button>}
        {a.ech && ech.action === 'lrar_silence' && <button className="btn plein" onClick={() => ouvrirMail('echeance_lrar', {}, { cle: ech.cle, etape: 'lrar', detail: 'LRAR envoyée au bailleur' })}>Préparer la LRAR</button>}
        {a.ech && ['fin_auto', 'verifier_contrat'].includes(ech.action) && <button className="btn" onClick={() => etapeFaite(ech.cle, 'vu', 'Vu')}>C’est noté</button>}
        {a.ob && a.ob.a_faire.modele && a.ob.a_faire.canal !== 'sms_rivage' && <button className="btn plein" onClick={() => ouvrirMail(a.ob.a_faire.modele, { ob: a.ob }, { cle: a.ob.cle, etape: String(a.ob.a_faire.ordre), detail: a.ob.a_faire.libelle })}>
          {a.ob.a_faire.canal === 'lrar' ? 'Préparer le recommandé' : 'Préparer le mail'}</button>}
        {a.ob && a.ob.a_faire.canal === 'sms_rivage' && <SmsRivage texte={SMS[a.ob.a_faire.modele]?.({ ...ctx, ob: a.ob })} fait={() => etapeFaite(a.ob.cle, String(a.ob.a_faire.ordre), 'SMS envoyé depuis Rivage')} />}
        {a.ob && <button className="btn" onClick={() => etapeFaite(a.ob.cle, String(a.ob.a_faire.ordre), a.ob.a_faire.libelle)}>Marquer fait</button>}
        {a.ob && <Realise ob={a.ob} agir={agir} />}
      </div>}
    </div>)}
    {mail && <EditeurMail mail={mail} email={email} fermer={() => setMail(null)} marquer={async () => { await etapeFaite(mail.etape.cle, mail.etape.etape, mail.etape.detail); setMail(null); }} peut={peut} />}

    <Echeance d={d} b={b} peut={peut} agir={agir} ouvrirMail={ouvrirMail} />
    <Controle d={d} b={b} peut={peut} agir={agir} ouvrirMail={ouvrirMail} recharger={async () => { await charger(); apres(); }} />
    <Suivis d={d} b={b} peut={peut} agir={agir} />
    <Paliers d={d} b={b} peut={peut} agir={agir} ouvrirMail={ouvrirMail} />
    <Actes d={d} b={b} peut={peut} agir={agir} />
    {d.journal?.length > 0 && <><h3>Journal</h3><ol className="histo">{d.journal.slice(0, 20).map((j, i) =>
      <li key={i}><span className="muted">{new Date(j.le).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' })}</span><span>{j.detail || j.etape}{j.par ? ' · ' + j.par : ''}</span></li>)}</ol></>}
    <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={b.lien} target="_blank" rel="noreferrer">Ouvrir le bail dans Rivage</a></div>
  </>;
}

function SmsRivage({ texte, fait }) {
  const [vu, setVu] = useState(false);
  return <>
    <button className="btn plein" onClick={() => { navigator.clipboard?.writeText(texte || ''); setVu(true); }}>Copier le SMS (à envoyer depuis Rivage)</button>
    {vu && <><span className="muted" style={{ fontSize: 12 }}>Copié : « {texte} »</span><button className="btn" onClick={fait}>SMS envoyé</button></>}
  </>;
}

function Realise({ ob, agir }) {
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

function EditeurMail({ mail, email, fermer, marquer, peut }) {
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
  return <>
    <h3>Échéance du bail</h3>
    {ech.etat === 'incomplet' ? <div className="mini-alerte haute">{ech.raison}</div> : <>
      <div className="echeance"><div><b>{ech.mode === 'prolongation' ? 'En tacite prolongation depuis le' : ech.mode === 'fin_auto' ? 'Fin du bail' : 'Échéance'}</b>
        <div className="muted">{ETATS[ech.etat] || ech.etat}{ech.manquee ? ` · délai de congé dépassé pour l’échéance du ${date(ech.manquee)}` : ''}</div></div>
        <div className="echeance-n">{date(ech.echeance)}</div></div>
      <ol className="etapes">{[
        ['Information du bailleur', ech.info, ech.informe_le],
        ['Relance', ech.relance, ech.relance_le],
        ['Décision attendue, sinon LRAR', ech.decision, ech.lrar_le || ech.choix_le],
        ['Date limite du congé', ech.limite, ech.conge_le],
      ].filter((x) => x[1] || x[2]).map(([l, pr, fait]) => <li key={l} className={fait ? 'fait' : pr && pr < auj() ? 'retard' : ''}>
        <span className="puce">{fait ? '✓' : ''}</span><span>{l}<span className="muted"> · prévu le {date(pr)}{fait ? ` · fait le ${date(fait)}` : ''}</span></span></li>)}</ol>
      {ech.mode === 'prolongation' && <p className="muted">Un congé délivré aujourd’hui prendrait effet au plus tôt le {date(ech.effet_conge_au_plus_tot)} (6 mois, pour le dernier jour d’un trimestre civil).</p>}
      {ech.douze_ans && <p className="muted">12 ans de durée le {date(ech.douze_ans)} : au-delà, déplafonnement possible du loyer du bail renouvelé.</p>}
      {ech.triennale && <p className="muted">Prochaine fin de période triennale : {date(ech.triennale)} (faculté de congé du preneur avec 6 mois de préavis).</p>}
      {(ech.blocages || []).map((x, i) => <div key={i} className="mini-alerte critique">{x}</div>)}
      {habitation && <div className="row" style={{ marginTop: 6 }}>
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
      {ech.conge_le && <p>Congé délivré le {date(ech.conge_le)} ({ech.conge_mode}).</p>}
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

// ----- Contrôle d'entrée -----
function Controle({ d, b, peut, agir, ouvrirMail, recharger }) {
  const c = d.controle || { items: [] };
  const [ouvert, setOuvert] = useState(!c.go_le);
  const [lecture, setLecture] = useState({ charge: false, err: '' });
  useEffect(() => { setOuvert(!c.go_le); }, [b.bail_id]);
  const manquants = c.items.filter((i) => i.bloc === 'pieces' && i.statut !== 'ok' && i.statut !== 'sans_objet').map((i) => i.libelle);
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
        <button className="btn" disabled={lecture.charge} onClick={() => lire(null)}>{lecture.charge ? 'Lecture en cours…' : 'Lire le bail déposé dans Rivage (IA)'}</button>
        <label className="btn">Lire un PDF (IA)<input type="file" accept="application/pdf" hidden onChange={(e) => e.target.files[0] && lire(e.target.files[0])} /></label>
        {manquants.length > 0 && <button className="btn" onClick={() => ouvrirMail('pieces_manquantes', { manquants }, { cle: 'e:' + b.bail_id + ':pieces', etape: auj(), detail: 'Pièces demandées au bailleur' })}>Demander les pièces au bailleur</button>}
      </div>}
      {lecture.err && <div className="err">{lecture.err}</div>}
    </div>
    {d.lecture && <LectureIA l={d.lecture} />}
    {ouvert && ['pieces', 'rivage', 'clauses'].map((bloc) => <div key={bloc}>
      <div className="groupe-tete" style={{ marginTop: 10 }}><b>{BLOCS[bloc]}</b></div>
      {c.items.filter((i) => i.bloc === bloc).map((i) => <Question key={i.cle} i={i} d={d} b={b} peut={peut} agir={agir} />)}
    </div>)}
  </>;
}

function LectureIA({ l }) {
  const r = l.resultat || {};
  const an = Array.isArray(r.anomalies) ? r.anomalies : []; const rf = Array.isArray(r.refacturations) ? r.refacturations : [];
  if (!an.length && !rf.length) return null;
  return <div className="resume-ia" style={{ marginTop: 8 }}>
    <span className="resume-ia-titre">✦ Lecture du bail</span> <span className="muted">({l.source}, le {date(l.le)})</span>
    {an.length > 0 && <><div style={{ marginTop: 4 }}><b>Points signalés</b></div><ul style={{ margin: '2px 0 6px', paddingLeft: 18 }}>{an.map((x, k) => <li key={k}>{String(x)}</li>)}</ul></>}
    {rf.length > 0 && <><div><b>Sommes refacturables selon le bail</b></div><ul style={{ margin: '2px 0 6px', paddingLeft: 18 }}>{rf.map((x, k) => <li key={k}>{x.nature}{x.article ? ` (art. ${x.article})` : ''}{x.page ? `, page ${x.page}` : ''}</li>)}</ul></>}
    <div className="muted" style={{ fontSize: 12 }}>Proposition de l’IA à vérifier sur le document : chaque point se valide dans le questionnaire.</div>
  </div>;
}

function Question({ i, d, b, peut, agir }) {
  const [com, setCom] = useState(i.commentaire || '');
  const [suivi, setSuivi] = useState(i.suivi || (i.bloc === 'rivage' ? 'rivage' : i.genere ? 'backoffice' : ''));
  const [creer, setCreer] = useState(false);
  useEffect(() => { setCom(i.commentaire || ''); }, [i.commentaire]);
  const repondre = (statut) => agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: statut, p_suivi: suivi || null, p_valeur: null, p_commentaire: com || null });
  const couleur = i.statut === 'ok' ? 'var(--teal)' : i.statut === 'anomalie' ? 'var(--red)' : i.statut === 'sans_objet' ? 'var(--muted)' : 'var(--amber)';
  const suiviExiste = i.genere && (d.obligations || []).some((o) => o.nature === i.genere && o.actif);
  return <div style={{ borderTop: '1px solid var(--line)', padding: '8px 0' }}>
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
      <div style={{ flex: 1, minWidth: 220 }}>
        <span style={{ color: couleur, fontWeight: 700 }}>{i.statut === 'ok' ? '✓' : i.statut === 'anomalie' ? '!' : i.statut === 'sans_objet' ? '–' : '○'}</span> {i.libelle}
        {i.aide && <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div>}
        {i.detail && i.mode !== 'fiche' && <div style={{ fontSize: 13 }}>{i.mode === 'rivage' ? 'Rivage : ' : ''}{i.detail}</div>}
        {i.ia && <div style={{ fontSize: 13, background: 'var(--blue-bg)', padding: '4px 8px', borderRadius: 6, marginTop: 4 }}>
          ✦ Lu dans le bail : {i.ia.valeur || (i.ia.trouve === false ? 'non trouvé' : '—')}{i.ia.page ? ` (page ${i.ia.page})` : ''}
          {i.ia.extrait && <div className="muted" style={{ fontSize: 12 }}>« {i.ia.extrait} »</div>}</div>}
        {i.mode === 'fiche' && <div style={{ marginTop: 4 }}><ChampFiche b={b} fiche={d.fiche} champ={i.ref} peut={peut} agir={agir} /></div>}
        {i.repondu && <div className="muted" style={{ fontSize: 12 }}>Répondu par {i.par || '—'} le {date(i.le)}{i.suivi ? ` · suivi ${i.suivi === 'rivage' ? 'dans Rivage' : 'dans le back-office'}` : ''}{i.commentaire ? ' · ' + i.commentaire : ''}</div>}
      </div>
      {peut && !(i.genere && i.genere !== 'garantie' && !i.repondu) && <div className="row" style={{ justifyContent: 'flex-end' }}>
        <select value={suivi} onChange={(e) => setSuivi(e.target.value)} aria-label="Où se fait le suivi">
          <option value="">Suivi —</option><option value="rivage">Suivi dans Rivage</option><option value="backoffice">Suivi back-office</option></select>
        <input placeholder="Commentaire" value={com} onChange={(e) => setCom(e.target.value)} style={{ width: 150 }} />
        <button className="btn" onClick={() => repondre('ok')}>Conforme</button>
        <button className="btn" onClick={() => repondre('anomalie')}>Anomalie</button>
        <button className="btn gris" onClick={() => repondre('sans_objet')}>Sans objet</button>
        {i.repondu && <button className="lien" onClick={() => agir('pilotage_bail_repondre', { p_bail: b.bail_id, p_cle: i.cle, p_statut: null, p_suivi: null, p_valeur: null, p_commentaire: null })}>Effacer</button>}
      </div>}
    </div>
    {peut && i.genere && i.genere !== 'garantie' && !i.repondu && <QuestionSuivi i={i} d={d} b={b} agir={agir} />}
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
  const [v, setV] = useState({});
  const [err, setErr] = useState('');
  const maj = (k, x) => setV((o) => ({ ...o, [k]: x }));
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
      <div className="row" style={{ marginTop: 6 }}>
        <button className="btn gris" onClick={() => creer([], 'sans_objet', 'Compteurs individuels : rien à relever')}>Tous individuels</button>
        <span className="muted">ou compteurs divisionnaires :</span>
        {COMPTEURS.map((c) => <label key={c}><input type="checkbox" checked={!!v['c_' + c]} onChange={(x) => maj('c_' + c, x.target.checked)} /> {c}</label>)}
      </div>
      {coches.length > 0 && <div className="row" style={{ marginTop: 6 }}>
        <label>Prochain relevé le <input type="date" value={v.date || prochainRelevé()} onChange={(e) => maj('date', e.target.value)} /></label>
        <span className="muted" style={{ fontSize: 12 }}>Tous les 6 mois, calé sur la régularisation des charges.</span>
        <button className="btn plein" onClick={() => creer([{ libelle: 'Relevé ' + coches.join(', ').toLowerCase(), date: v.date || prochainRelevé(), per: 6 }], 'ok', 'Divisionnaires : ' + coches.join(', '))}>Valider et suivre</button>
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
  const PAR_DEFAUT = { charges_regul: ['Régularisation des charges et état récapitulatif', 12], etat_travaux: ['État prévisionnel des travaux', 36], destination: ['Contrôle de la destination des lieux', 12] };
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
        <span className="puce">{e.fait_le ? '✓' : ''}</span><span>{e.libelle}<span className="muted"> · {date(e.date)}{e.fait_le ? ' · fait le ' + date(e.fait_le) : ''}</span></span></li>)}</ol>
      {o.derniere_le && <div className="muted">Dernière réalisation : {date(o.derniere_le)}</div>}
      {peut && <div className="row" style={{ marginTop: 6 }}>
        <Realise ob={o} agir={agir} />
        <button className="btn gris" onClick={() => agir('pilotage_bail_obligation', { p_bail: b.bail_id, p_id: o.id, p_nature: o.nature, p_libelle: null, p_periodicite: o.periodicite_mois, p_prochaine: null, p_actif: !o.actif })}>{o.actif ? 'Arrêter ce suivi' : 'Réactiver'}</button>
      </div>}
    </details>)}
    {peut && (ajout ? <NouveauSuivi b={b} agir={agir} fini={() => setAjout(false)} /> : <button className="lien" onClick={() => setAjout(true)}>+ Ajouter un suivi (assurance, équipement, compteurs…)</button>)}
  </>;
}

// ----- Paliers et franchises -----
function Paliers({ d, b, peut, agir, ouvrirMail }) {
  const [f, setF] = useState({ nature: 'palier', debut: '', fin: '', loyer: '', com: '' });
  const ps = d.paliers || [];
  return <>
    <h3>Paliers et franchises de loyer</h3>
    {!ps.length && <p className="muted">Aucun palier ni franchise saisi.</p>}
    {peut && (d.lecture?.resultat?.paliers || []).filter((x) => x?.debut && !ps.some((p) => p.debut === x.debut)).map((x, k) =>
      <div key={k} className="mini-alerte normale">✦ Lu dans le bail : {x.nature === 'franchise' ? 'franchise' : 'palier'} du {date(x.debut)}{x.fin ? ' au ' + date(x.fin) : ''}{x.loyer_annuel_ht != null ? `, loyer annuel ${Number(x.loyer_annuel_ht).toLocaleString('fr-FR')} € HT` : ''}{x.page ? ` (page ${x.page})` : ''}
        <button className="lien" style={{ marginLeft: 8 }} onClick={() => setF({ nature: x.nature === 'franchise' ? 'franchise' : 'palier', debut: x.debut, fin: x.fin || '', loyer: '', com: 'Lu dans le bail' + (x.page ? ', page ' + x.page : '') })}>Reprendre (saisir le montant Rivage)</button></div>)}
    {ps.length > 0 && <div className="table-wrap"><table className="table-imp"><thead><tr><th>Nature</th><th>Du</th><th>Au</th><th>Loyer attendu dans Rivage</th><th>Note</th><th></th></tr></thead><tbody>
      {ps.map((p) => <tr key={p.id}><td>{p.nature === 'franchise' ? 'Franchise' : 'Palier'}</td><td>{date(p.debut)}</td><td>{date(p.fin)}</td>
        <td>{p.loyer_rivage != null ? Number(p.loyer_rivage).toLocaleString('fr-FR', { style: 'currency', currency: 'EUR' }) : '—'}</td><td>{p.commentaire}</td>
        <td>{peut && <><button className="lien" onClick={() => ouvrirMail('palier_locataire', { palier: p }, { cle: 'e:' + b.bail_id + ':palier' + p.id, etape: 'info', detail: 'Locataire informé du palier' })}>Mail locataire</button>{' '}
          <button className="lien" onClick={() => agir('pilotage_bail_palier', { p_bail: b.bail_id, p_id: p.id, p_nature: null, p_debut: null, p_fin: null, p_loyer: null, p_commentaire: null, p_supprimer: true })}>Supprimer</button></>}</td></tr>)}
    </tbody></table></div>}
    <p className="muted" style={{ fontSize: 12 }}>Le montant attendu est saisi dans la même unité que le loyer de Rivage (par appel). Le pilotage rappelle la mise à jour 30 jours avant et signale tout écart avec Rivage une fois le palier commencé.</p>
    {peut && <div className="row">
      <select value={f.nature} onChange={(e) => setF({ ...f, nature: e.target.value })} aria-label="Nature"><option value="palier">Palier</option><option value="franchise">Franchise</option></select>
      <label className="muted">Du <input type="date" value={f.debut} onChange={(e) => setF({ ...f, debut: e.target.value })} /></label>
      <label className="muted">Au <input type="date" value={f.fin} onChange={(e) => setF({ ...f, fin: e.target.value })} /></label>
      <input type="number" placeholder="Loyer attendu" value={f.loyer} onChange={(e) => setF({ ...f, loyer: e.target.value })} style={{ width: 130 }} aria-label="Loyer attendu dans Rivage" />
      <input placeholder="Note (article du bail)" value={f.com} onChange={(e) => setF({ ...f, com: e.target.value })} aria-label="Note" />
      <button className="btn" disabled={!f.debut} onClick={async () => { await agir('pilotage_bail_palier', { p_bail: b.bail_id, p_id: null, p_nature: f.nature, p_debut: f.debut, p_fin: f.fin || null, p_loyer: f.loyer === '' ? (f.nature === 'franchise' ? 0 : null) : Number(f.loyer), p_commentaire: f.com || null, p_supprimer: false }); setF({ nature: 'palier', debut: '', fin: '', loyer: '', com: '' }); }}>Ajouter</button>
    </div>}
  </>;
}

// ----- Actes -----
const ACTES = { demande_renouvellement: 'Demande de renouvellement', conge: 'Congé', refus_renouvellement: 'Refus de renouvellement', reponse: 'Réponse', avenant: 'Avenant', commandement: 'Commandement', autre: 'Autre' };
function Actes({ d, b, peut, agir }) {
  const vide = { nature: 'demande_renouvellement', auteur: 'preneur', signifie: '', forme: 'acte', ref: '', effet: '', com: '' };
  const [f, setF] = useState(vide);
  const as = d.actes || [];
  return <>
    <h3>Actes et notifications</h3>
    {!as.length && <p className="muted">Aucun acte saisi.</p>}
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
    {peut && <div className="row">
      <select value={f.nature} onChange={(e) => setF({ ...f, nature: e.target.value })} aria-label="Nature de l’acte">{Object.entries(ACTES).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
      <select value={f.auteur} onChange={(e) => setF({ ...f, auteur: e.target.value })} aria-label="Auteur"><option value="preneur">du preneur</option><option value="bailleur">du bailleur</option></select>
      <label className="muted">Signifié le <input type="date" value={f.signifie} onChange={(e) => setF({ ...f, signifie: e.target.value })} /></label>
      <select value={f.forme} onChange={(e) => setF({ ...f, forme: e.target.value })} aria-label="Forme"><option value="acte">Commissaire de justice</option><option value="lrar">LRAR</option><option value="remise">Remise en main propre</option><option value="autre">Autre</option></select>
      <input placeholder="Référence" value={f.ref} onChange={(e) => setF({ ...f, ref: e.target.value })} style={{ width: 120 }} aria-label="Référence" />
      <label className="muted">Effet le <input type="date" value={f.effet} onChange={(e) => setF({ ...f, effet: e.target.value })} /></label>
      <button className="btn" disabled={!f.signifie} onClick={async () => { await agir('pilotage_bail_acte', { p_bail: b.bail_id, p_id: null, p_nature: f.nature, p_auteur: f.auteur, p_signifie: f.signifie, p_forme: f.forme, p_reference: f.ref || null, p_effet: f.effet || null, p_reponse: null, p_commentaire: f.com || null, p_supprimer: false }); setF(vide); }}>Ajouter</button>
    </div>}
  </>;
}
