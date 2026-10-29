// Fiche d'un dossier en grand (096) : panneau large au-dessus de la page, au lieu de la colonne étroite ou du dépliant dans la carte.
// Fermeture : bouton, touche Échap ou clic sur le fond. La page derrière ne défile plus tant que la fiche est ouverte.
import React, { useEffect } from 'react';

export default function Fiche({ titre, fermer, children }) {
  useEffect(() => {
    const echap = (e) => { if (e.key === 'Escape') fermer(); };
    const avant = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    window.addEventListener('keydown', echap);
    return () => { window.removeEventListener('keydown', echap); document.body.style.overflow = avant; };
  }, [fermer]);
  return (
    <div className="fiche-voile" onMouseDown={(e) => { if (e.target === e.currentTarget) fermer(); }}>
      <section className="panneau fiche-large" role="dialog" aria-modal="true" aria-label={titre || 'Fiche'}>
        <div className="fiche-barre">
          <strong>{titre || 'Fiche'}</strong>
          <button className="btn" onClick={fermer}>Fermer ×</button>
        </div>
        <div className="fiche-corps">{children}</div>
      </section>
    </div>
  );
}
