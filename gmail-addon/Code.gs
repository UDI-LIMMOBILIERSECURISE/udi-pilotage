// Module « Pilotage UDI » pour Gmail (146).
// Lecture d'un mail : lot / bail / ticket reconnus par le pilotage, rattachement en un clic, derniers échanges.
// Écriture d'un mail : recherche d'un lot, d'un bail ou d'un ticket ; un clic sur le dossier ajoute la référence [UDI L<lot> T<ticket>] en bas du mail.
// Les droits sont ceux du membre du pilotage qui a la même adresse Gmail (vérifiés côté pilotage, fonction pilotage-gmail).

var API = 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-gmail';
var PILOTAGE = 'https://udi-pilotage.vercel.app/';
var ROLES = { locataire: 'Locataire', bailleur: 'Bailleur', prestataire: 'Prestataire', syndic: 'Syndic', garant: 'Garant', organisme: 'Organisme' };

function appel(action, params) {
  var corps = { action: action, id_token: ScriptApp.getIdentityToken() };
  for (var k in params) corps[k] = params[k];
  var r = UrlFetchApp.fetch(API, { method: 'post', contentType: 'application/json', payload: JSON.stringify(corps), muteHttpExceptions: true });
  var j = {};
  try { j = JSON.parse(r.getContentText() || '{}'); } catch (e) { j = {}; }
  if (r.getResponseCode() !== 200) throw new Error(j.error || ('Erreur ' + r.getResponseCode()));
  return j;
}

function adresses(texte) {
  var m = String(texte || '').match(/[A-Z0-9._%+'-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi) || [];
  var vus = {}, res = [];
  m.forEach(function (x) { x = x.toLowerCase(); if (!vus[x]) { vus[x] = 1; res.push(x); } });
  return res;
}
function date(d) { return d ? Utilities.formatDate(new Date(d), 'Europe/Paris', 'dd/MM/yyyy') : ''; }
function ref(lot, ticket) { return '[UDI L' + lot + (ticket ? ' T' + ticket : '') + ']'; }
// 151 : ticket d'immeuble (sans lot) : référence courte, rattachement sans lot
function refTicket(l, t) { return t.immeuble ? '[UDI T' + t.numero + ']' : ref(l.lot, t.numero); }
function libTicket(t) { return 'Ticket n°' + t.numero + (t.immeuble ? ' · immeuble' : ''); }
function carteErreur(e) {
  return CardService.newCardBuilder().setHeader(CardService.newCardHeader().setTitle('Pilotage UDI'))
    .addSection(CardService.newCardSection().addWidget(CardService.newTextParagraph().setText(String(e && e.message || e)))).build();
}
function lienPilotage() {
  return CardService.newTextButton().setText('Ouvrir le pilotage').setOpenLink(CardService.newOpenLink().setUrl(PILOTAGE));
}
function blocLot(l) {
  var t = '<b>Lot ' + l.lot + '</b> · ' + (l.adresse || '');
  if (l.bail) t += '<br>Bail ' + l.bail + (l.locataires ? ' · ' + l.locataires : '');
  if (l.bailleur) t += '<br>Bailleur : ' + l.bailleur;
  if ((l.tickets || []).length) t += '<br>Tickets ouverts : ' + l.tickets.map(function (x) {
    var p = (x.prestataires || []).map(function (y) { return y.nom; }).join(', ');
    return 'n°' + x.numero + ' ' + (x.titre || '') + (x.immeuble ? ' [' + (x.immeuble_libelle || 'immeuble') + ']' : '') + (p ? ' (' + p + ')' : '');
  }).join(' ; ');
  return CardService.newTextParagraph().setText(t);
}

// ---------- Page d'accueil (icône dans le panneau de droite) ----------
function accueil(e) { return carteRecherche('', false, null); }

// ---------- Lecture d'un mail ----------
function surMessage(e) {
  var d, m;
  try {
    GmailApp.setCurrentMessageAccessToken(e.gmail.accessToken);
    m = GmailApp.getMessageById(e.gmail.messageId);
    d = appel('contexte', { message_id: m.getHeader('Message-ID') || '', emails: adresses([m.getFrom(), m.getTo(), m.getCc()].join(',')) });
  } catch (err) { return carteErreur(err); }
  var c = CardService.newCardBuilder().setHeader(CardService.newCardHeader().setTitle('Pilotage UDI').setSubtitle(m.getSubject() || ''));
  var s1 = CardService.newCardSection().setHeader('Ce mail');
  if (!d.mail) {
    s1.addWidget(CardService.newTextParagraph().setText((d.parties || []).length
      ? 'Pas encore dans le pilotage.'
      : 'Aucun correspondant connu de Rivage : ce mail n\'est pas repris.'));
    if ((d.parties || []).length) s1.addWidget(CardService.newTextButton().setText('Ajouter au pilotage')
      .setOnClickAction(CardService.newAction().setFunctionName('importer').setParameters({ gmail_id: String(m.getId()) })));
    // Mail non repris mais portant une référence [UDI L<lot> T<ticket>] : on affiche quand même le dossier, pour information
    var r = String(m.getSubject() || '').match(/\[UDI L([^\]\s]+)(?: T(\d+))?\]/);
    if (r) {
      try {
        var trouves = (appel('chercher', { q: r[1] }).lots || []).filter(function (l) { return String(l.lot) === r[1]; });
        trouves.forEach(function (l) {
          var t = (l.tickets || []).filter(function (x) { return r[2] && String(x.numero) === r[2]; })[0];
          s1.addWidget(CardService.newTextParagraph().setText('Référence <b>' + r[0] + '</b> dans l\'objet :'
            + (t ? '<br>Ticket n°' + t.numero + ' ' + (t.titre || '') : '')));
          d.lots = (d.lots || []).concat([l]);
        });
      } catch (err) { }
    }
  } else if (d.mail.statut === 'classe') {
    s1.addWidget(CardService.newTextParagraph().setText((d.mail.lot ? 'Rattaché au <b>lot ' + d.mail.lot + '</b> · ' + (d.mail.adresse || '') : 'Rattaché à l\'<b>' + (d.mail.immeuble || 'immeuble') + '</b>')
      + (d.mail.bail ? '<br>Bail ' + d.mail.bail : '') + (d.mail.ticket ? '<br>Ticket n°' + d.mail.ticket.numero + ' ' + (d.mail.ticket.titre || '') : '')
      + (d.mail.resume ? '<br><i>' + d.mail.resume + '</i>' : '')));
  } else if (d.mail.statut === 'a_verifier') {
    s1.addWidget(CardService.newTextParagraph().setText('<b>À vérifier</b> : le pilotage hésite. Choisissez le bon lot ci-dessous.'));
  } else {
    s1.addWidget(CardService.newTextParagraph().setText('Retiré du pilotage (« pas un dossier »).'));
  }
  if ((d.parties || []).length) s1.addWidget(CardService.newTextParagraph().setText(d.parties.map(function (p) { return (p.nom || p.email) + ' (' + (ROLES[p.role] || p.role) + ')'; }).join('<br>')));
  c.addSection(s1);

  (d.lots || []).forEach(function (l) {
    var s = CardService.newCardSection().addWidget(blocLot(l));
    if (d.mail && d.peut_classer && !(d.mail.statut === 'classe' && d.mail.lot_id === l.lot_id && !d.mail.ticket_id)) {
      var bs = CardService.newButtonSet();
      if (!(d.mail.statut === 'classe' && d.mail.lot_id === l.lot_id))
        bs.addButton(CardService.newTextButton().setText('Rattacher au lot ' + l.lot)
          .setOnClickAction(CardService.newAction().setFunctionName('classer').setParameters({ mail_id: String(d.mail.id), lot_id: l.lot_id, ticket_id: '' })));
      (l.tickets || []).forEach(function (t) {
        if (d.mail.ticket_id === t.ticket_id) return;
        bs.addButton(CardService.newTextButton().setText(libTicket(t))
          .setOnClickAction(CardService.newAction().setFunctionName('classer').setParameters({ mail_id: String(d.mail.id), lot_id: t.immeuble ? '' : l.lot_id, ticket_id: t.ticket_id })));
      });
      s.addWidget(bs);
    }
    c.addSection(s);
  });

  if ((d.echanges || []).length) {
    var s3 = CardService.newCardSection().setHeader('Derniers échanges sur ce lot').setCollapsible(true).setNumUncollapsibleWidgets(3);
    d.echanges.forEach(function (x) {
      s3.addWidget(CardService.newDecoratedText().setTopLabel(date(x.le) + (x.sens === 'envoye' ? ' · envoyé' : ' · reçu')).setText(x.objet || '(sans objet)')
        .setBottomLabel(x.resume || '').setWrapText(true));
    });
    c.addSection(s3);
  }
  if (d.mail && d.peut_classer) c.addSection(sectionRecherche('', false, d.mail.id));
  c.addSection(CardService.newCardSection().addWidget(lienPilotage()));
  return c.build();
}

// 148 : mail arrivé avant le branchement de la boîte — le pilotage le lit et le range, puis le panneau est réaffiché
function importer(e) {
  var st;
  try { st = appel('importer', { gmail_id: e.parameters.gmail_id }).statut; }
  catch (err) { return CardService.newActionResponseBuilder().setNotification(CardService.newNotification().setText(String(err.message || err))).build(); }
  var msg = { classe: 'Ajouté et rangé dans le dossier.', a_verifier: 'Ajouté : choisissez le dossier ci-dessous.', doublon: 'Déjà dans le pilotage.',
    exclu: 'Mail marqué « Privé » : non repris.', interne: 'Échange interne : non repris.', hors_rivage: 'Aucun correspondant lié à un lot ou un bail : non repris.' }[st]
    || 'Ce mail n\'a pas pu être repris.';
  return CardService.newActionResponseBuilder().setNotification(CardService.newNotification().setText(msg))
    .setNavigation(CardService.newNavigation().updateCard(surMessage(e))).build();
}

function classer(e) {
  var p = e.parameters;
  try { appel('classer', { mail_id: Number(p.mail_id), lot_id: p.lot_id, ticket_id: p.ticket_id || null }); }
  catch (err) { return CardService.newActionResponseBuilder().setNotification(CardService.newNotification().setText(String(err.message || err))).build(); }
  return CardService.newActionResponseBuilder().setNotification(CardService.newNotification().setText('Rattaché : le libellé Gmail passe à « Pilotage/Classé ».'))
    .setStateChanged(true).build();
}

// ---------- Recherche (accueil, lecture et écriture) ----------
function sectionRecherche(q, redaction, mailId) {
  var s = CardService.newCardSection().setHeader(redaction ? 'Dossier du mail' : 'Chercher un lot');
  if (redaction) s.addWidget(CardService.newTextParagraph().setText('Cherchez le lot, puis cliquez sur le lot ou le ticket concerné : la référence du dossier est ajoutée en bas du mail et le mail, comme les réponses, sera rangé dans ce dossier.'));
  s.addWidget(CardService.newTextInput().setFieldName('q').setTitle('N° de lot, adresse, locataire, bailleur, prestataire ou n° de ticket').setValue(q || ''));
  s.addWidget(CardService.newTextButton().setText('Rechercher')
    .setOnClickAction(CardService.newAction().setFunctionName('rechercher').setParameters({ redaction: redaction ? '1' : '', mail_id: mailId ? String(mailId) : '' })));
  return s;
}

function carteRecherche(q, redaction, mailId, lots) {
  var c = CardService.newCardBuilder().setHeader(CardService.newCardHeader().setTitle('Pilotage UDI').setSubtitle(redaction ? 'Rattacher ce mail à un dossier' : 'Recherche'));
  c.addSection(sectionRecherche(q, redaction, mailId));
  if (lots) {
    if (!lots.length) c.addSection(CardService.newCardSection().addWidget(CardService.newTextParagraph().setText('Aucun lot trouvé.')));
    lots.forEach(function (l) {
      var s = CardService.newCardSection().addWidget(blocLot(l));
      var bs = CardService.newButtonSet();
      if (redaction) {
        // Un seul geste : choisir le dossier. La référence part dans l'objet, et la réponse reviendra au même dossier.
        bs.addButton(CardService.newTextButton().setText('Lot ' + l.lot + (l.bail ? ' · bail ' + l.bail : ''))
          .setOnClickAction(CardService.newAction().setFunctionName('insererRef').setParameters({ ref: ref(l.lot) })));
        (l.tickets || []).forEach(function (t) {
          bs.addButton(CardService.newTextButton().setText(libTicket(t))
            .setOnClickAction(CardService.newAction().setFunctionName('insererRef').setParameters({ ref: refTicket(l, t) })));
        });
      } else if (mailId) {
        bs.addButton(CardService.newTextButton().setText('Rattacher au lot ' + l.lot)
          .setOnClickAction(CardService.newAction().setFunctionName('classer').setParameters({ mail_id: String(mailId), lot_id: l.lot_id, ticket_id: '' })));
        (l.tickets || []).forEach(function (t) {
          bs.addButton(CardService.newTextButton().setText(libTicket(t))
            .setOnClickAction(CardService.newAction().setFunctionName('classer').setParameters({ mail_id: String(mailId), lot_id: t.immeuble ? '' : l.lot_id, ticket_id: t.ticket_id })));
        });
      }
      s.addWidget(bs);
      c.addSection(s);
    });
  }
  return c.build();
}

function rechercher(e) {
  var q = (e.formInput && e.formInput.q) || '';
  var redaction = !!e.parameters.redaction, mailId = e.parameters.mail_id ? Number(e.parameters.mail_id) : null;
  var lots;
  try { lots = appel('chercher', { q: q }).lots || []; } catch (err) { return CardService.newActionResponseBuilder().setNotification(CardService.newNotification().setText(String(err.message || err))).build(); }
  return CardService.newActionResponseBuilder().setNavigation(CardService.newNavigation().pushCard(carteRecherche(q, redaction, mailId, lots))).build();
}

// ---------- Écriture d'un mail ----------
function surRedaction(e) { return [carteRecherche('', true, null)]; }

// Référence ajoutée en bas du texte du mail, en petit et en gris (l'objet reste libre). Le pilotage la lit dans le texte comme dans l'objet,
// et elle reste dans le texte cité des réponses.
function insererRef(e) {
  var r = e.parameters.ref, md = e.draftMetadata || {};
  // 148 : choix gardé côté pilotage (sécurité si la ligne est effacée) — sans effet sur le brouillon si l'appel échoue
  try { appel('choisir', { ref: r, emails: [].concat(md.toRecipients || [], md.ccRecipients || [], md.bccRecipients || []), objet: md.subject || '' }); } catch (err) { }
  var html = '<div style="clear:both;display:block;text-align:left;white-space:nowrap;color:#9aa0a6;font-size:11px;margin-top:12px">Réf. dossier : ' + r + '</div>';
  return CardService.newUpdateDraftActionResponseBuilder()
    .setUpdateDraftBodyAction(CardService.newUpdateDraftBodyAction().addUpdateContent(html, CardService.ContentType.MUTABLE_HTML)
      .setUpdateType(CardService.UpdateDraftBodyType.INSERT_AT_END)).build();
}
