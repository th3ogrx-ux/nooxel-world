# Sauvegarde automatique et gratuite de la base

Chaque nuit (vers 3 h 23, heure de Paris en hiver), GitHub copie les **données** de la base (comptes, profils, posts, abonnements,
avis, signalements, vidéos) dans un fichier **chiffré** (AES-256), conservé **30 jours**. Rien ne coûte. Les **fichiers** (photos et
vidéos) ne sont pas inclus : ils restent dans le stockage de Supabase.

Trois protections se cumulent : le dépôt est **privé**, le fichier est **chiffré**, et l'automatisme **refuse de s'exécuter** si le
dépôt devient public par erreur.

## Mise en route (une seule fois, 10 minutes)
1. **Rendre le dépôt privé** : GitHub → votre dépôt → **Settings** → tout en bas **Danger Zone** → **Change visibility** → *Make private*.
   (Le site Cloudflare continue de se déployer normalement.)
2. **Supabase** → bouton **Connect** (en haut) → onglet **Session pooler** → copiez l'adresse (elle commence par `postgresql://`).
   Remplacez `[YOUR-PASSWORD]` par le mot de passe de la base (Project Settings → Database → *Reset database password* si perdu).
3. **Inventez un long mot de passe aléatoire** (24 caractères ou plus) pour le chiffrement. **Gardez-le ailleurs que sur GitHub**
   (gestionnaire de mots de passe, papier). **Sans lui, les sauvegardes sont illisibles.**
4. **GitHub** → **Settings → Secrets and variables → Actions → New repository secret**, deux fois :
   - `SUPABASE_DB_URL` = l'adresse de l'étape 2 ;
   - `BACKUP_PASSPHRASE` = le mot de passe de l'étape 3.
5. Onglet **Actions → « Sauvegarde de la base » → Run workflow**. Une coche verte = c'est bon ; la sauvegarde apparaît en bas de la page
   du lancement, dans « Artifacts » (`sauvegarde-chiffree`).

Ne collez jamais ces deux valeurs dans une conversation ou un fichier du dépôt.

## Bon à savoir
- Si une sauvegarde échoue (mot de passe de la base changé, projet en pause, dépôt public…), GitHub vous envoie un email.
- Téléchargez de temps en temps (chaque mois, par exemple) une sauvegarde et rangez-la ailleurs : GitHub n'en garde que 30 jours.
- Les données d'un compte supprimé restent dans les sauvegardes déjà faites jusqu'à leur expiration (30 jours) : c'est indiqué dans la
  politique de confidentialité.

## Restaurer (projet perdu, erreur grave…)
1. Créez un nouveau projet Supabase, puis collez dans son **SQL Editor** les fichiers `supabase/*.sql` dans l'ordre du `README-verification.md`
   (ils recréent la structure, la sécurité, les fonctions et les espaces de stockage).
2. Téléchargez la sauvegarde choisie (fichier `.gpg`) depuis l'onglet Actions.
3. Sur un ordinateur avec `psql` et `gpg` :
   `BACKUP_PASSPHRASE="..." NEW_DB_URL="postgresql://..." scripts/restore.sh nooxel_2026-11-01_0223.sql.gpg`
4. Les photos et vidéos déjà envoyées ne reviennent pas toutes seules : si le stockage d'origine est perdu, les commerçants devront les republier.

Test réalisé sur une vraie base PostgreSQL : sauvegarde, chiffrement, puis restauration dans une base neuve. Les comptes, profils, posts,
abonnés, avis, notes, pseudos et signalements sont identiques, et les droits d'accès sont restés fermés au public.
