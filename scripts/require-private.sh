#!/usr/bin/env bash
# Garde-fou : refuse de continuer si le dépôt GitHub est PUBLIC (les sauvegardes contiennent des données personnelles).
# Utilise la commande « gh » (déjà présente sur GitHub) avec le jeton fourni automatiquement par GitHub.
set -euo pipefail
priv="$(gh api "repos/${GITHUB_REPOSITORY:?}" --jq .private)"
if [ "$priv" != "true" ]; then
  echo "REFUS : ce dépôt est PUBLIC. Une sauvegarde y serait téléchargeable par tout le monde." >&2
  echo "Rendez-le privé (GitHub → Settings → Danger Zone → Change visibility), puis relancez." >&2
  exit 1
fi
echo "Dépôt privé : sauvegarde autorisée."
