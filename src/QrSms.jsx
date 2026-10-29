import React, { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { qrSms } from './messages.js';

/** QR code à scanner avec l'appareil photo du portable : il ouvre Messages avec le numéro et le texte du SMS (repris d'UDI Pilot). */
export default function QrSms({ tel, texte }) {
  const [src, setSrc] = useState(null);
  useEffect(() => {
    let actif = true;
    QRCode.toDataURL(qrSms(tel, texte), { errorCorrectionLevel: 'M', margin: 1, width: 220 })
      .then((u) => actif && setSrc(u)).catch(() => actif && setSrc(null));
    return () => { actif = false; };
  }, [tel, texte]);
  if (!src) return null;
  return (
    <div className="qr-sms">
      <img src={src} alt="QR code du SMS à scanner avec le téléphone" width="220" height="220" />
      <p className="muted">Scannez avec l’appareil photo de votre portable : Messages s’ouvre avec le numéro et le texte, il reste à envoyer.</p>
    </div>
  );
}
