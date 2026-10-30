#!/usr/bin/env bash
# Sauvegarde chiffrée de la base Nooxel World (comptes + données de l'application).
# Variables obligatoires : SUPABASE_DB_URL (adresse de connexion à la base) et BACKUP_PASSPHRASE (mot de passe de chiffrement).
# Ne contient AUCUN secret : ils viennent de l'environnement. Les fichiers (photos, vidéos) ne sont pas inclus.
set -euo pipefail
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL manquante}"
: "${BACKUP_PASSPHRASE:?BACKUP_PASSPHRASE manquante}"
OUT="${1:-backup}"; mkdir -p "$OUT"
RAW="$(mktemp)"; trap 'rm -f "$RAW"' EXIT

# Seules les DONNÉES sont sauvegardées : la structure, les règles de sécurité et les fonctions se reconstruisent avec les
# fichiers supabase/*.sql du dépôt (voir scripts/restore.sh). Ainsi une restauration ne peut pas ouvrir par erreur des accès.
# 1) les comptes d'abord (les données de l'application y font référence)
pg_dump "$SUPABASE_DB_URL" --data-only --no-owner --no-privileges --table=auth.users --table=auth.identities >> "$RAW"
# 2) toutes les données du schéma « public » (profils, posts, abonnements, avis, signalements, vidéos…)
pg_dump "$SUPABASE_DB_URL" --data-only --schema=public --no-owner --no-privileges >> "$RAW"

# 3) contrôle : la sauvegarde doit contenir les tables essentielles, sinon on échoue (et GitHub prévient par email)
for t in "COPY auth.users" "COPY public.merchant_profiles"; do
  grep -q "$t" "$RAW" || { echo "Sauvegarde incomplète : $t est absente." >&2; exit 1; }
done
LINES=$(wc -l < "$RAW"); [ "$LINES" -gt 20 ] || { echo "Sauvegarde anormalement petite ($LINES lignes)." >&2; exit 1; }

# 4) chiffrement AES-256 (le fichier en clair n'est jamais conservé)
FILE="$OUT/nooxel_$(date -u +%Y-%m-%d_%H%M).sql.gpg"
gpg --batch --yes --pinentry-mode loopback --passphrase "$BACKUP_PASSPHRASE" --symmetric --cipher-algo AES256 --compress-algo zlib -o "$FILE" "$RAW"
echo "Sauvegarde chiffrée : $FILE ($(du -h "$FILE" | cut -f1), $LINES lignes)"
