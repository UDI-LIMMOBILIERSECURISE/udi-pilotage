// Messages d'un mandat ou d'un bail (091) : les modèles de l'étape en cours, remplis depuis Rivage pour la personne connectée.
// Mail : brouillon Gmail à relire et envoyer. SMS : lien qui ouvre les Messages du portable, ou QR code à scanner depuis
// l'ordinateur (repris d'UDI Pilot). Chaque message préparé est noté au journal du dossier ; « Pas nécessaire » le retire de Ma journée.
import React, { useEffect, useState } from 'react';
import { rpc, supabase } from './supabase.js';
import { lienGmail, smsFactures } from './mails.js';
import { lienSms, surTelephone, champsRestants, remplirChamps, CANAL, MOYEN } from './messages.js';
import QrSms from './QrSms.jsx';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const libelleChamp = (c) => c.replace(/[{}]/g, '').replace(/_/g, ' ');

export default function MessagesDossier({ objet, id, apres, titre = true }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [etape, setEtape] = useState(null);
  const [ouvert, setOuvert] = useState(null);
  const [email, setEmail] = useState('');
  const charger = () => rpc('pilotage_messages_dossier', { p_objet: objet, p_id: id }).then((x) => {
    setD(x); setEtape((e) => e || (x.actives || [])[0] || null);
  }).catch((e) => setErr(e.message));
  useEffect(() => { setD(null); setEtape(null); setOuvert(null); charger(); }, [objet, id]);
  useEffect(() => { supabase.auth.getSession().then(({ data }) => setEmail(data?.session?.user?.email || '')); }, []);
  if (err && !d) return <div className="err">{err}</div>;
  if (!d) return null;
  const actives = d.actives || [];
  const restants = (cle) => d.messages.filter((m) => m.categorie === cle && !m.fait).length;
  const liste = d.messages.filter((m) => m.categorie === etape);
  const noter = async (m, moyen, x) => {
    setErr('');
    try {
      await rpc('pilotage_message_noter', { p_objet: objet, p_id: id, p_code: m.code, p_a: x.a, p_objet_mail: x.objet || null, p_texte: x.texte, p_moyen: moyen });
      await charger(); apres && apres();
    } catch (e) { setErr(e.message); }
  };
  return (
    <div style={{ marginTop: 18 }}>
      {titre && <h3 style={{ margin: '0 0 6px' }}>Messages {objet === 'mandat' ? 'au bailleur' : 'au locataire et au bailleur'}</h3>}
      <div className="row" role="tablist" style={{ marginBottom: 8 }}>
        {d.categories.map((k) => (
          <button key={k.cle} role="tab" aria-selected={etape === k.cle} className={'chip' + (etape === k.cle ? ' on' : '')} onClick={() => { setEtape(k.cle); setOuvert(null); }}
            style={k.active ? undefined : { opacity: 0.6 }}>
            {k.libelle}{k.active && restants(k.cle) > 0 && <span className="n">{restants(k.cle)}</span>}
          </button>
        ))}
      </div>
      {!etape && <p className="muted" style={{ fontSize: 13 }}>Aucune étape en cours pour ce dossier : choisissez une étape pour voir ses messages.</p>}
      {etape && !actives.includes(etape) && <p className="muted" style={{ fontSize: 13 }}>Cette étape n’est pas en cours pour ce dossier ; les messages restent utilisables.</p>}
      {err && <div className="err">{err}</div>}
      <div className="stack" style={{ gap: 6 }}>
        {liste.map((m, i) => {
          const cle = m.code + '|' + i;
          return (
            <div key={cle} className="card" style={{ padding: '8px 12px' }}>
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <span><span className={'tag ' + (m.canal === 'sms' ? 'oblig' : 'tache')}>{CANAL[m.canal]}</span> <strong>{m.libelle}</strong>
                  <span className="muted"> · {m.a || 'pas de ' + (m.canal === 'sms' ? 'numéro' : 'e-mail') + ' dans Rivage'}</span></span>
                <span className="row">
                  {m.fait && <span className="muted">✓ {MOYEN[m.fait.moyen] || m.fait.moyen} le {date(m.fait.le)}{m.fait.par ? ' par ' + m.fait.par : ''}</span>}
                  <button className={'btn' + (m.fait ? ' gris' : ' plein')} onClick={() => setOuvert(ouvert === cle ? null : cle)}>{ouvert === cle ? 'Fermer' : m.fait ? 'Revoir' : 'Préparer'}</button>
                </span>
              </div>
              {ouvert === cle && (m.canal === 'email'
                ? <FormMail m={m} email={email} noter={(moyen, x) => { noter(m, moyen, x); if (moyen === 'inutile') setOuvert(null); }} />
                : <FormSms m={m} noter={(moyen, x) => { noter(m, moyen, x); if (moyen === 'inutile') setOuvert(null); }} />)}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// Champs non fournis par Rivage ({date_edl}, {heure_edl}…) : saisis ici, remplacés dans le texte avant l'envoi
function Champs({ champs, valeurs, setValeurs }) {
  if (!champs.length) return null;
  return (
    <div className="row" style={{ fontSize: 13 }}>
      {champs.map((c) => <label key={c}>{libelleChamp(c)} <input value={valeurs[c] || ''} onChange={(e) => setValeurs({ ...valeurs, [c]: e.target.value })} /></label>)}
    </div>
  );
}

function FormMail({ m, email, noter }) {
  const [a, setA] = useState(m.a || '');
  const [objet, setObjet] = useState(m.objet || '');
  const [texte, setTexte] = useState(m.texte || '');
  const [valeurs, setValeurs] = useState({});
  const champs = champsRestants(m.objet || '', m.texte || '');
  const objetFinal = remplirChamps(objet, valeurs);
  const texteFinal = remplirChamps(texte, valeurs);
  const manque = champsRestants(objetFinal, texteFinal);
  const to = a.split(/[,;]\s*/).map((x) => x.trim()).filter(Boolean);
  return (
    <div className="stack" style={{ gap: 6, marginTop: 8 }}>
      <Champs champs={champs} valeurs={valeurs} setValeurs={setValeurs} />
      <label style={{ fontSize: 13 }}>À<input style={{ width: '100%' }} value={a} onChange={(e) => setA(e.target.value)} placeholder="adresses séparées par une virgule" /></label>
      <label style={{ fontSize: 13 }}>Objet<input style={{ width: '100%' }} value={objet} onChange={(e) => setObjet(e.target.value)} /></label>
      <label style={{ fontSize: 13 }}>Texte<textarea rows={12} style={{ width: '100%', fontFamily: 'inherit', fontSize: 14 }} value={texte} onChange={(e) => setTexte(e.target.value)} /></label>
      {manque.length > 0 && <div className="err">À compléter avant l’envoi : {manque.join(' ')}</div>}
      <div className="row">
        {manque.length === 0 && to.length > 0
          ? <a className="btn plein" href={lienGmail({ to, objet: objetFinal, corps: texteFinal }, email)} target="_blank" rel="noreferrer"
              onClick={() => noter('gmail', { a, objet: objetFinal, texte: texteFinal })}>Ouvrir dans Gmail</a>
          : <button className="btn plein" disabled>Ouvrir dans Gmail</button>}
        <button className="btn gris" onClick={() => noter('inutile', { a, objet: objetFinal, texte: texteFinal })}>Pas nécessaire</button>
      </div>
      <p className="muted">Le brouillon s’ouvre dans votre boîte Gmail : relisez-le et envoyez-le vous-même.</p>
    </div>
  );
}

function FormSms({ m, noter }) {
  const [a, setA] = useState(m.a || '');
  const [texte, setTexte] = useState(m.texte || '');
  const [valeurs, setValeurs] = useState({});
  const [copie, setCopie] = useState(false);
  const [note, setNote] = useState(false);
  const telephone = surTelephone();
  const champs = champsRestants(m.texte || '');
  const texteFinal = remplirChamps(texte, valeurs);
  const manque = champsRestants(texteFinal);
  const pret = manque.length === 0 && !!a.trim() && !!texteFinal.trim();
  const f = smsFactures(texteFinal);
  // Journal : noté au premier geste (ouvrir sur le portable, copier, ou « Fait » après le QR code)
  const noterUneFois = (moyen) => { if (note) return; setNote(true); noter(moyen, { a, texte: texteFinal }); };
  const copier = async () => { try { await navigator.clipboard.writeText(texteFinal); setCopie(true); noterUneFois('copie'); } catch { setCopie(false); } };
  return (
    <div className="stack" style={{ gap: 6, marginTop: 8 }}>
      <Champs champs={champs} valeurs={valeurs} setValeurs={setValeurs} />
      <label style={{ fontSize: 13 }}>Numéro<input value={a} onChange={(e) => setA(e.target.value)} placeholder="portable" /></label>
      <label style={{ fontSize: 13 }}>Texte<textarea rows={4} style={{ width: '100%', fontFamily: 'inherit', fontSize: 14 }} value={texte} onChange={(e) => setTexte(e.target.value)} /></label>
      <div className="muted" style={{ color: f.n > 1 ? 'var(--red)' : undefined }}>{f.longueur} caractères · {f.n} SMS</div>
      {manque.length > 0 && <div className="err">À compléter avant l’envoi : {manque.join(' ')}</div>}
      {pret && !telephone && <QrSms tel={a} texte={texteFinal} />}
      <div className="row">
        {pret && telephone && <a className="btn plein" href={lienSms(a, texteFinal)} onClick={() => noterUneFois('telephone')}>Ouvrir dans Messages</a>}
        <button className="btn" disabled={manque.length > 0} onClick={copier}>{copie ? 'Copié' : 'Copier le texte'}</button>
        {pret && !telephone && <button className="btn gris" onClick={() => noterUneFois('qr')}>Fait</button>}
        <button className="btn gris" onClick={() => noter('inutile', { a, texte: texteFinal })}>Pas nécessaire</button>
      </div>
      <p className="muted">Le SMS part de votre portable{telephone ? ' : ouvrez-le dans Messages' : ' : scannez le QR code'}, puis envoyez-le.</p>
    </div>
  );
}

// Ma journée (091) : dossiers dont l'étape en cours a des messages pas encore faits (commercial du dossier, à défaut la gestionnaire)
export function MessagesAEnvoyer() {
  const [liste, setListe] = useState(null);
  const [err, setErr] = useState('');
  const [sel, setSel] = useState(null);
  const charger = () => rpc('pilotage_messages_a_envoyer').then(setListe).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  if (err) return <div className="err">{err}</div>;
  if (!liste || !liste.length) return null;
  return (
    <details className="replie" open style={{ marginBottom: 14 }}>
      <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Messages à envoyer <span className="pastille">{liste.length}</span></summary>
      <div className="muted" style={{ fontSize: 12, margin: '4px 0' }}>Selon l’étape du dossier (nouveau mandat, nouveau bail, état des lieux, congé…). Un message préparé ou marqué « Pas nécessaire » sort de la liste.</div>
      <div className="stack" style={{ gap: 6, marginTop: 6 }}>
        {liste.map((x) => {
          const cle = x.objet + x.id;
          return (
            <div key={cle} className="card" style={{ padding: '8px 12px' }}>
              <div className="row" style={{ justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => setSel(sel === cle ? null : cle)}>
                <span><strong>{x.titre}</strong><span className="muted"> · {x.adresse || '—'} · {(x.etapes || []).join(', ')}</span></span>
                <span className="row"><span className="pastille">{x.restants.length} à faire</span><button className="btn">{sel === cle ? 'Fermer' : 'Ouvrir'}</button></span>
              </div>
              {sel === cle && <MessagesDossier objet={x.objet} id={x.id} titre={false} apres={charger} />}
            </div>
          );
        })}
      </div>
    </details>
  );
}
