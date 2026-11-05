/* Flèche « retour » : revient à l'écran précédent de la navigation (ex. Favoris → Paramètres), et non toujours à la carte.
   Le lien garde son adresse de secours (href) : elle sert si la page a été ouverte directement (pas d'écran précédent sur Nooxel). */
document.addEventListener("click", (e) => {
  const a = e.target.closest && e.target.closest("a[data-back]");
  if (!a || e.defaultPrevented || e.button || e.metaKey || e.ctrlKey || e.shiftKey) return;
  try {
    if (history.length > 1 && document.referrer && new URL(document.referrer).origin === location.origin) { e.preventDefault(); history.back(); }
  } catch (_) { /* on suit le lien normalement */ }
});
