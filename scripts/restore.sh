#!/usr/bin/env bash
# Restauration d'une sauvegarde dans un projet Supabase NEUF (ou vidé).
# 1) Dans le nouveau projet : collez dans le SQL Editor les fichiers supabase/*.sql dans l'ordre du README
#    (ils recréent la structure, les règles de sécurité, les fonctions et les espaces de stockage).
# 2) Puis, depuis votre ordinateur :
#      BACKUP_PASSPHRASE="..." NEW_DB_URL="postgresql://..." scripts/restore.sh nooxel_2026-11-01_0223.sql.gpg
# Les fichiers (photos, vidéos) ne font pas partie de la sauvegarde.
set -euo pipefail
: "${BACKUP_PASSPHRASE:?mot de passe de chiffrement manquant}"; : "${NEW_DB_URL:?adresse de la nouvelle base manquante}"; FILE="${1:?fichier .gpg manquant}"
{
  echo "set session_replication_role = replica;"      # pendant le chargement, ni déclencheurs ni vérifications croisées (tout est déjà cohérent)
  gpg --batch --yes --pinentry-mode loopback --passphrase "$BACKUP_PASSPHRASE" --decrypt "$FILE"
} | psql "$NEW_DB_URL" -v ON_ERROR_STOP=1 -q
echo "Restauration terminée."
