# Vérification des commerçants — mise en service

Tout est gratuit (offre gratuite de Supabase). À faire **dans cet ordre**.

## 1. Base de données (collages dans cet ordre)
Supabase → **SQL Editor** → New query → coller → **Run**.
1. `supabase/merchant-verification.sql` (étape 1 : tables, sécurité)
2. `supabase/merchant-functions.sql` (étape 2 : fonctions)
3. `supabase/admin-mfa.sql` (double authentification obligatoire pour l'administrateur)
4. `supabase/merchant-manual-review.sql` (étape 3 : validation manuelle **sans pièce d'identité**)
5. `supabase/commerce-pages.sql` (phase 2, étape 1 : pages commerçants, posts, abonnés, fil d'actualité)
6. `supabase/independents.sql` (phase 2, étape 2 : indépendants, zone d'intervention, planning de passage)
7. `supabase/reviews.sql` (phase 2, étape 3 : pseudo public, avis, réponses des commerçants)

Tous se relancent sans danger. L'étape 3 convertit les anciens badges en un seul badge « professionnel vérifié »,
annule les anciennes demandes encore ouvertes (les commerçants peuvent redéposer) et programme la suppression des
anciennes pièces d'identité.

### Principe de la validation manuelle
Le commerçant fournit un **téléphone** (non vérifié par SMS : c'est un service payant), le **lien de sa page**
Instagram/Facebook/TikTok, et facultativement un **SIRET** (contrôlé automatiquement, mais sans badge automatique :
un SIRET est public) et un **code de parrainage**. Vous examinez chaque demande dans `/admin` et approuvez ou refusez.
Le téléphone et le lien sont effacés tout de suite à l'annulation et 30 jours après un refus (tâche planifiée
`purge-request-personal-data`, créée par l'étape 3 si l'extension `pg_cron` est activée).

## 2. Vous donner les droits d'administrateur
Dans le SQL Editor, avec **votre** email (celui de votre compte Nooxel) :

```sql
insert into public.admins (user_id)
select id from auth.users where email = 'votre-email@exemple.com';
```

### Double authentification (obligatoire pour l'administrateur)
1. Supabase → SQL Editor : coller `supabase/admin-mfa.sql` → **Run**. Dès lors, `is_admin()` exige une session
   à deux facteurs (`aal2`) : sans elle, toute action d'administration est refusée par la base.
2. Vérifier que **Authentication → Sign In / Providers → Multi-Factor** a le TOTP activé (gratuit).
3. Ouvrir `/admin` connecté avec le compte administrateur : au premier passage, scanner le QR code avec une
   application d'authentification, **noter la clé secrète affichée**, saisir le code à 6 chiffres.
   Aux connexions suivantes, seul le code est demandé.
4. Téléphone perdu : dans le SQL Editor, `delete from auth.mfa_factors where user_id = (select id from auth.users where email = 'votre-email');`
   puis recommencer l'étape 3.

## 3. Fonctions serveur (3) — sans ligne de commande
Supabase → **Edge Functions** → **Deploy a new function** → **Via Editor**. Pour chaque fonction : donner
**exactement** le nom ci-dessous, effacer le code d'exemple, coller le contenu du fichier correspondant de
`supabase/functions-bundled/` (version « un seul fichier »), puis **Deploy**.

| Nom exact | Fichier à coller | « Verify JWT » |
|---|---|---|
| `verify-siret` | `functions-bundled/verify-siret.ts` | laissé activé |
| `purge-documents` | `functions-bundled/purge-documents.ts` | **désactivé** (elle est protégée par un secret) |

> **Ancien système (pièces d'identité) :** la fonction `admin-document-url` n'est plus utilisée : vous pouvez la
> supprimer dans le tableau de bord. Gardez `purge-documents` jusqu'à ce que les anciennes pièces soient effacées.
> Il faut re-coller `verify-siret.ts` : la nouvelle version ne donne plus de badge, elle mémorise seulement le
> résultat pour la demande (l'ancienne version continue de fonctionner, mais affiche un message obsolète).

Puis **Edge Functions → Secrets** → ajouter `CRON_SECRET` = une longue chaîne aléatoire (gardez-la : elle sert
à l'étape 4). Les clés `SUPABASE_URL`, `SUPABASE_ANON_KEY` et `SUPABASE_SERVICE_ROLE_KEY` sont fournies
automatiquement par Supabase : ne les copiez nulle part.

Alternative avec la ligne de commande Supabase (versions modulaires dans `supabase/functions/`) :
`supabase functions deploy verify-siret`, `... admin-document-url`, `... purge-documents --no-verify-jwt`.

| Fonction | Rôle | Qui l'appelle |
|---|---|---|
| `verify-siret` | contrôle un SIRET et mémorise le résultat pour la demande (aucun badge) | le commerçant connecté |
| `purge-documents` | supprime les anciennes pièces échues et les fichiers orphelins | tâche planifiée |

## 4. Nettoyage automatique quotidien (RGPD)
Supabase → **Database → Extensions** : activer `pg_cron` et `pg_net` (gratuits). Puis, dans le SQL Editor
(remplacez les 3 valeurs) :

```sql
select cron.schedule('purge-verification-docs', '17 3 * * *', $$
  select net.http_post(
    url     := 'https://<VOTRE-PROJET>.supabase.co/functions/v1/purge-documents',
    headers := '{"x-cron-secret": "<LE MÊME CRON_SECRET>", "Authorization": "Bearer <clé anon>"}'::jsonb
  );
$$);
```

## 5. Tester le contrôle SIRET
Testez avec un vrai SIRET (le vôtre ou un SIRET public) : le champ doit afficher « Entreprise trouvée : NOM ».
Si un SIRET qui existe est « introuvable », c'est `_shared/siret.ts` (`parseCompanySearch`) qu'il faut ajuster.

## 6. Les pages
| Page | Pour qui | Accès |
|---|---|---|
| `/pro.html` | le commerçant : créer son profil, demander la vérification (téléphone, page, SIRET, parrainage), statut, contestation | menu du compte → « Espace professionnel » |
| `/admin.html` | vous : file de validation (page à ouvrir, téléphone, SIRET, parrain), approuver / refuser, contestations, révocation | taper l'adresse à la main (aucun lien dans l'appli) ; il faut être connecté avec le compte administrateur |

La page admin n'est qu'une façade : **chaque action est contrôlée côté serveur** (`is_admin()`), un
non-administrateur reçoit « Accès refusé » même s'il connaît l'adresse.

**Essai complet conseillé avant d'ouvrir :** créez 2 comptes de test, faites passer l'un par le SIRET et
l'autre sans SIRET avec un code de parrainage ; ouvrez `/admin.html` avec votre compte administrateur, refusez, contestez,
puis révoquez. Vérifiez à chaque fois l'historique côté commerçant.

## Rappels de sécurité
- Ne jamais mettre la clé `service_role` dans `index.html` ni dans le dépôt.
- Tant que la confirmation d'email est désactivée dans Supabase, « email confirmé » ne prouve rien :
  la réactiver (avec un envoi d'emails gratuit) avant le lancement.
- Plus aucune pièce d'identité n'est collectée : le risque juridique associé a disparu.

## Pages commerçants (phase 2, étape 1)
`commerce-pages.sql` ajoute : l'adresse et la position d'un commerce, ses posts (texte + photo facultative), les
abonnements, le fil d'actualité, la recherche de commerces et leurs épingles sur la carte, et un espace de photos
(`merchant-media`, lecture publique, écriture réservée au propriétaire d'un commerce **vérifié**).

- Seuls les commerces **vérifiés** ont une page visible, apparaissent sur la carte et peuvent publier (20 posts / 24 h).
- Le navigateur n'écrit jamais directement dans les tables : posts, abonnements et compteur d'abonnés passent par
  des fonctions serveur qui vérifient l'identité de l'appelant.
- Re-coller `functions-bundled/purge-documents.ts` : la tâche du soir supprime aussi les photos de posts
  devenues orphelines (post ou compte supprimé), pour respecter le droit à l'effacement.
- **À surveiller** : stockage (photos ~150 Ko chacune) et trafic des photos sur l'offre gratuite de Supabase (5 Go
  de trafic par mois) ; voir la comparaison des offres avec le propriétaire du projet.

## Indépendants et commerces itinérants (phase 2, étape 2)
`independents.sql` ajoute un type de profil « mobile » (coiffeur à domicile, food truck, artisan, freelance…) :

- **Pas d'adresse** : une zone d'intervention (ville + rayon de 2 à 100 km). La position est **arrondie à ~1 km par
  la base de données elle-même** : même un navigateur modifié ne peut pas enregistrer une adresse personnelle précise.
- **Planning de passage** (lieu + créneau, 24 h maximum, 30 passages à venir, dans les 90 jours), géré par le
  commerçant. Les passages terminés depuis plus de 7 jours sont effacés chaque nuit (`purge_old_schedule`, pg_cron).
- Sur la carte : épingle **verte** et cercle de la zone ; pas de bouton « Itinéraire » vers le centre d'une zone.

## Avis (phase 2, étape 3)
`reviews.sql` ajoute le pseudo public (3 à 20 caractères, sans accent, unique, modifiable une fois par mois), les avis
(note de 1 à 5 + texte de 20 caractères minimum) et la réponse publique du commerçant. Tout est imposé par la base :

- **Un compte = un avis par commerce** (contrainte unique) : un second envoi modifie l'avis existant. Pas d'avis sur
  sa propre page ni sur un commerce non vérifié ; email confirmé obligatoire ; compte créé depuis plus d'une heure
  (pour les nouveaux avis) ; 5 nouveaux avis par 24 h.
- **Refus automatique avec explication :** trop court, uniquement des insultes, lien / email / numéro de téléphone,
  texte répété. La liste de gros mots est dans `insult_words()` (modifiable) : elle réduit les abus sans les supprimer,
  le bouton « Signaler » (étape 4) complète.
- **« Preuve de passage » :** simple case déclarative, affichée comme « non vérifié ».
- Seul le propriétaire d'un commerce vérifié répond à un avis ; la note moyenne est tenue à jour par la base.
- Supprimer son compte supprime ses avis et son pseudo.
