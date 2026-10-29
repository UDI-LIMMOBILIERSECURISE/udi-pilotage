// Écran « Modèles de messages » (091) : tous les mails et SMS proposés selon l'avancement du mandat et du bail, classés par étape.
// Lecture pour toute l'équipe ; modification par Nicolas et Romain (droits vérifiés dans la base, chaque modification historisée).
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';
import { chargerModeles, CANAL, CIBLE } from './messages.js';
import { smsFactures } from './mails.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');

export default function ModelesMessages() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [ok, setOk] = useState('');
  const charger = (forcer) => chargerModeles(forcer).then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(false); }, []);
  const agir = async (fn, args, message) => {
    setErr(''); setOk('');
    try { await rpc(fn, args); setOk(message); await charger(true); } catch (e) { setErr(e.message); }
  };
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  return (
    <div className="stack">
      <div>
        <h1>Modèles de messages</h1>
        <p className="sub">Mails et SMS proposés dans les fiches des mandats et des baux, et dans Ma journée, selon l’étape du dossier. Le mail s’ouvre en brouillon dans Gmail ; le SMS du commercial part de son portable (lien sur le téléphone, QR code sur l’ordinateur). Les relances de la gestion restent envoyées par le pilotage, expéditeur UDI GESTION.
          {!d.peut_modifier && ' Seuls Nicolas et Romain peuvent modifier les modèles.'}</p>
      </div>
      <details className="replie">
        <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Champs remplis automatiquement</summary>
        <div className="muted" style={{ fontSize: 13, marginTop: 6, lineHeight: 1.6 }}>
          {d.champs.map(([c, l]) => <div key={c}><code>{c}</code> : {l}</div>)}
        </div>
      </details>
      {err && <div className="banner">{err}</div>}
      {ok && <div className="info">{ok}</div>}
      {d.categories.map((k) => <Categorie key={k.cle} k={k} modeles={d.modeles.filter((m) => m.categorie === k.cle)} modifiable={d.peut_modifier} agir={agir} />)}
    </div>
  );
}

function Categorie({ k, modeles, modifiable, agir }) {
  const [avant, setAvant] = useState(k.jours_avant ?? '');
  const [apres, setApres] = useState(k.jours_apres ?? '');
  useEffect(() => { setAvant(k.jours_avant ?? ''); setApres(k.jours_apres ?? ''); }, [k.jours_avant, k.jours_apres]);
  const fenetre = k.jours_avant != null || k.jours_apres != null;
  const change = String(avant) !== String(k.jours_avant ?? '') || String(apres) !== String(k.jours_apres ?? '');
  return (
    <section className="card">
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h3 style={{ margin: 0 }}>{k.libelle} <span className="pastille">{modeles.length}</span></h3>
        <span className="tag tache">{k.objet === 'mandat' ? 'Mandat' : 'Bail'}</span>
      </div>
      <p className="muted" style={{ margin: '4px 0 8px', fontSize: 13 }}>{k.quand}</p>
      {fenetre && (
        <div className="row" style={{ marginBottom: 8, fontSize: 13 }}>
          {k.jours_avant != null && <label>Jours avant <input type="number" min="0" max="365" style={{ width: 70 }} value={avant} disabled={!modifiable} onChange={(e) => setAvant(e.target.value)} /></label>}
          {k.jours_apres != null && <label>Jours après <input type="number" min="0" max="365" style={{ width: 70 }} value={apres} disabled={!modifiable} onChange={(e) => setApres(e.target.value)} /></label>}
          {modifiable && change && <button className="btn plein" onClick={() => agir('pilotage_message_categorie_modifier',
            { p_cle: k.cle, p_avant: avant === '' ? null : Number(avant), p_apres: apres === '' ? null : Number(apres) }, `« ${k.libelle} » : fenêtre enregistrée.`)}>Enregistrer</button>}
        </div>
      )}
      <div className="stack" style={{ gap: 6 }}>
        {modeles.map((m) => <Modele key={m.code} m={m} modifiable={modifiable} agir={agir} />)}
      </div>
    </section>
  );
}

function Modele({ m, modifiable, agir }) {
  const [objet, setObjet] = useState(m.objet || '');
  const [texte, setTexte] = useState(m.texte || '');
  useEffect(() => { setObjet(m.objet || ''); setTexte(m.texte || ''); }, [m.objet, m.texte]);
  const change = objet !== (m.objet || '') || texte !== m.texte;
  const f = m.canal === 'sms' ? smsFactures(texte.split('{nom}').join('Prénom NOM')) : null;
  return (
    <details className="replie">
      <summary style={{ cursor: 'pointer' }}>
        <span className={'tag ' + (m.canal === 'sms' ? 'oblig' : 'tache')}>{CANAL[m.canal]}</span>{' '}
        <strong style={{ opacity: m.actif ? 1 : 0.5 }}>{m.libelle}</strong>
        <span className="muted"> · {CIBLE[m.cible]}{m.envoi === 'twilio' ? ' · envoyé par le pilotage (UDI GESTION)' : ''}{!m.actif ? ' · désactivé' : ''}</span>
      </summary>
      <div className="stack" style={{ gap: 6, marginTop: 8 }}>
        {m.canal === 'email' && <label style={{ fontSize: 13 }}>Objet<input style={{ width: '100%' }} value={objet} disabled={!modifiable} onChange={(e) => setObjet(e.target.value)} /></label>}
        <label style={{ fontSize: 13 }}>Texte
          <textarea rows={m.canal === 'sms' ? 4 : 12} style={{ width: '100%', fontFamily: 'inherit', fontSize: 14 }} value={texte} disabled={!modifiable} onChange={(e) => setTexte(e.target.value)} />
        </label>
        {f && <div className="muted" style={{ color: f.n > 1 ? 'var(--red)' : undefined }}>{f.longueur} caractères avec un nom type{f.unicode ? ' (caractère spécial : le message passe en Unicode)' : ''} · {f.n} SMS</div>}
        {modifiable && (
          <div className="row">
            <button className="btn plein" disabled={!change} onClick={() => agir('pilotage_message_modele_modifier', { p_code: m.code, p_objet: objet, p_texte: texte, p_actif: null }, `« ${m.libelle} » enregistré.`)}>Enregistrer</button>
            {change && <button className="btn gris" onClick={() => { setObjet(m.objet || ''); setTexte(m.texte); }}>Annuler</button>}
            <button className="btn gris" onClick={() => agir('pilotage_message_modele_modifier', { p_code: m.code, p_objet: m.objet, p_texte: m.texte, p_actif: !m.actif },
              `« ${m.libelle} » ${m.actif ? 'désactivé' : 'réactivé'}.`)}>{m.actif ? 'Désactiver' : 'Réactiver'}</button>
          </div>
        )}
        {m.modifie_le && <p className="muted">Modifié par {m.modifie_par_prenom || '—'} le {date(m.modifie_le)}</p>}
      </div>
    </details>
  );
}
