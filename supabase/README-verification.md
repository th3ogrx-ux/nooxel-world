# Vérification des commerçants — mise en service

Tout est gratuit (offre gratuite de Supabase). À faire **dans cet ordre**.

## 1. Base de données (2 collages)
Supabase → **SQL Editor** → New query → coller → **Run**.
1. `supabase/merchant-verification.sql` (étape 1 : tables, sécurité, stockage privé)
2. `supabase/merchant-functions.sql` (étape 2 : fonctions)

Les deux se relancent sans danger.

## 2. Vous donner les droits d'administrateur
Dans le SQL Editor, avec **votre** email (celui de votre compte Nooxel) :

```sql
insert into public.admins (user_id)
select id from auth.users where email = 'votre-email@exemple.com';
```

Activez aussi l'**authentification à deux facteurs** sur ce compte quand l'écran d'administration existera
(Supabase Auth gratuit : TOTP).

## 3. Fonctions serveur (3)
Supabase → **Edge Functions** → *Deploy a new function* (éditeur dans le navigateur), une par dossier de
`supabase/functions/`. Chaque fonction a aussi besoin du dossier `_shared/` : si vous utilisez l'éditeur
du navigateur, copiez le contenu de `_shared/errors.ts` et `_shared/siret.ts` à côté. Le plus simple et le
plus fiable est la ligne de commande Supabase (gratuite) :

```bash
supabase functions deploy verify-siret
supabase functions deploy admin-document-url
supabase functions deploy purge-documents --no-verify-jwt   # protégée par un secret, voir ci-dessous
supabase secrets set CRON_SECRET="<une longue chaîne aléatoire>"
```

| Fonction | Rôle | Qui l'appelle |
|---|---|---|
| `verify-siret` | contrôle un SIRET (niveau 1) | le commerçant connecté |
| `admin-document-url` | lien de 60 s vers une pièce + trace | un administrateur |
| `purge-documents` | supprime les pièces échues et les fichiers orphelins | tâche planifiée |

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
Le format de la réponse de l'API « Recherche d'entreprises » a été écrit de mémoire, sans pouvoir l'appeler
depuis l'environnement de développement. **Testez avec un vrai SIRET** (le vôtre ou un SIRET public) avant
d'ouvrir au public : si le résultat est « SIRET introuvable » alors qu'il existe, c'est
`_shared/siret.ts` (`parseCompanySearch`) qu'il faut ajuster.

## 6. Les pages
| Page | Pour qui | Accès |
|---|---|---|
| `/pro.html` | le commerçant : créer son profil, SIRET, pièce + photo, statut, contestation, suppression de ses pièces | menu du compte → « Espace professionnel » |
| `/admin.html` | vous : file de validation, visionneuse de pièces, approuver / refuser, contestations, révocation | taper l'adresse à la main (aucun lien dans l'appli) ; il faut être connecté avec le compte administrateur |

La page admin n'est qu'une façade : **chaque action est contrôlée côté serveur** (`is_admin()`), un
non-administrateur reçoit « Accès refusé » même s'il connaît l'adresse.

**Essai complet conseillé avant d'ouvrir :** créez 2 comptes de test, faites passer l'un par le SIRET et
l'autre par la pièce d'identité ; ouvrez `/admin.html` avec votre compte administrateur, refusez, contestez,
puis révoquez. Vérifiez à chaque fois l'historique côté commerçant.

## Rappels de sécurité
- Ne jamais mettre la clé `service_role` dans `index.html` ni dans le dépôt.
- Tant que la confirmation d'email est désactivée dans Supabase, « email confirmé » ne prouve rien :
  la réactiver (avec un envoi d'emails gratuit) avant le lancement.
- Ne pas ouvrir la collecte des pièces d'identité au public avant d'avoir décidé qui en est
  juridiquement responsable.
