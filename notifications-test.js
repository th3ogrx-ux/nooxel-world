// DONNÉES DE TEST des notifications (fictives). À supprimer quand les vraies notifications existeront :
// abonnements, avis, réponses, signalements et vérifications ne génèrent pas encore de notification.
// type : follow (+), review (étoile), reply (bulle), post (logo d'un commerce), report-done (bouclier vert), verified (bouclier bleu)
window.NOTIF_TEST = [
  { id: "n1", type: "follow", name: "Camille Martin", text: "s'est abonnée à votre page", daysAgo: 0, time: "09:24" },
  { id: "n2", type: "review", name: "Thomas", text: "a laissé un avis 5 étoiles sur votre page : “Super accueil…”", daysAgo: 0, time: "08:47", read: true },
  { id: "n3", type: "reply", name: "Sophie Leroy", text: "a répondu à votre avis", daysAgo: 0, time: "07:32" },
  { id: "n4", type: "report-done", name: "", text: "Votre signalement a été traité", daysAgo: 2, time: "18:10", read: true },
  { id: "n5", type: "post", name: "Le Petit Paris", text: "a publié une nouvelle photo", daysAgo: 3, time: "12:05" },
  { id: "n6", type: "verified", name: "", text: "Votre profil professionnel a été vérifié", daysAgo: 5, time: "10:00", read: true },
  { id: "n7", type: "follow", name: "Lucas Moreau", text: "s'est abonné à votre page", daysAgo: 12, time: "16:40", read: true },
  { id: "n8", type: "review", name: "Élise Bernard", text: "a laissé un avis 5 étoiles sur votre page : “Excellente expérience !”", daysAgo: 13, time: "09:15", read: true },
];
const NOTIF_KEY = "nooxel_test_notif_read";
window.notifReadSet = () => { try { const a = JSON.parse(localStorage.getItem(NOTIF_KEY)); return new Set(Array.isArray(a) ? a : []); } catch (e) { return new Set(); } };
window.notifMarkRead = (ids) => { try { localStorage.setItem(NOTIF_KEY, JSON.stringify([...new Set([...window.notifReadSet(), ...ids])])); } catch (e) {} };
window.notifUnreadCount = () => { const r = window.notifReadSet(); return window.NOTIF_TEST.filter((n) => !n.read && !r.has(n.id)).length; };
