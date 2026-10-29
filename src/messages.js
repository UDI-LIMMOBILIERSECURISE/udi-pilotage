// Modèles de mails et de SMS modifiables dans l'appli (091), repris du module d'UDI Pilot.
// Le pilotage n'envoie rien lui-même pour le commercial : le mail s'ouvre en brouillon Gmail, le SMS s'ouvre dans les Messages
// du portable (lien sms:) ou se scanne en QR code depuis l'ordinateur. Les SMS de la gestion restent envoyés par Twilio (066).
import { rpc } from './supabase.js';

/** Numéro au format international (06… → +336…), sans espaces. */
export const numero = (tel) => String(tel || '').replace(/[^\d+]/g, '').replace(/^0(\d{9})$/, '+33$1');

/** Lien qui ouvre les Messages du téléphone avec le numéro et le texte préremplis. */
export const lienSms = (tel, texte) => `sms:${numero(tel)}?&body=${encodeURIComponent(texte || '')}`;

/** Contenu d'un QR code « SMS » : l'appareil photo du téléphone propose d'ouvrir Messages avec numéro et texte. */
export const qrSms = (tel, texte) => `SMSTO:${numero(tel)}:${texte || ''}`;

/** Écran tactile (téléphone, tablette) : le lien sms: y ouvre Messages ; sur ordinateur on montre un QR code. */
export const surTelephone = () => { try { return window.matchMedia('(pointer: coarse)').matches; } catch { return false; } };

/** Champs restés entre accolades (non fournis par Rivage) : à saisir avant l'envoi, par ordre d'apparition. */
export const champsRestants = (...textes) => [...new Set(textes.join('\n').match(/\{[a-z_]+\}/g) || [])];

/** Remplace les champs saisis à la main ({date_edl} → valeur) ; un champ vide reste entre accolades. */
export const remplirChamps = (texte, valeurs) => Object.entries(valeurs || {})
  .reduce((t, [k, v]) => (v ? t.split(k).join(v) : t), texte || '');

// Modèles chargés une fois par session (écran des modèles et SMS de la gestion)
let cache = null;
export function chargerModeles(forcer = false) {
  if (!cache || forcer) cache = rpc('pilotage_messages_modeles').catch((e) => { cache = null; throw e; });
  return cache;
}

/** Texte d'un SMS de la gestion (Twilio) depuis les modèles ; {nom} reste, la base le remplace pour chaque locataire. */
export function texteSmsGestion(modeles, code, valeurs) {
  const m = (modeles || []).find((x) => x.code === code && x.actif);
  if (!m) return null;
  return remplirChamps(m.texte, { '{email_gestion}': 'votregestionnaire@udi-immo.com', ...valeurs });
}

export const CANAL = { email: 'Mail', sms: 'SMS' };
export const CIBLE = { bailleur: 'au bailleur', locataire: 'au locataire', garant: 'au garant' };
export const MOYEN = { gmail: 'ouvert dans Gmail', telephone: 'ouvert sur le portable', qr: 'envoyé par QR code', copie: 'texte copié', inutile: 'pas nécessaire' };
