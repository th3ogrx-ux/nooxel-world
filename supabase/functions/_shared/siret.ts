// Logique pure (sans réseau) du contrôle SIRET : testable avec `node --experimental-strip-types --test`.

export function normalizeSiret(input: unknown): string {
  return String(input ?? "").replace(/[\s.-]/g, "");
}

// Clé de contrôle de Luhn. Exception connue : les établissements de La Poste (SIREN 356 000 000)
// sont valides si la somme des chiffres est un multiple de 5.
export function isValidSiretFormat(siret: string): boolean {
  if (!/^[0-9]{14}$/.test(siret)) return false;
  if (siret.startsWith("356000000")) {
    return [...siret].reduce((s, d) => s + Number(d), 0) % 5 === 0;
  }
  let sum = 0;
  for (let i = 0; i < 14; i++) {
    let d = Number(siret[13 - i]);
    if (i % 2 === 1) { d *= 2; if (d > 9) d -= 9; }
    sum += d;
  }
  return sum % 10 === 0;
}

export type SiretLookup =
  | { found: false }
  | { found: true; active: boolean; check: Record<string, unknown> };

// Lit la réponse de https://recherche-entreprises.api.gouv.fr/search?q=<siret>
// (champs : results[].siren, nom_complet, etat_administratif ('A' = actif), siege{}, matching_etablissements[]).
// On ne garde que le minimum utile : aucune donnée sur les dirigeants.
export function parseCompanySearch(json: any, siret: string): SiretLookup {
  const results: any[] = Array.isArray(json?.results) ? json.results : [];
  for (const unit of results) {
    const candidates: any[] = [unit?.siege, ...(Array.isArray(unit?.matching_etablissements) ? unit.matching_etablissements : [])];
    const etab = candidates.find((e) => e && String(e.siret) === siret);
    if (!etab) continue;
    const unitActive = (unit.etat_administratif ?? "A") === "A";
    const etabActive = (etab.etat_administratif ?? "A") === "A";
    return {
      found: true,
      active: unitActive && etabActive,
      check: {
        source: "recherche-entreprises.api.gouv.fr",
        checked_at: new Date().toISOString(),
        siren: unit.siren ?? null,
        name: unit.nom_complet ?? unit.nom_raison_sociale ?? null,
        unit_state: unit.etat_administratif ?? null,
        establishment_state: etab.etat_administratif ?? null,
        activity: etab.activite_principale ?? unit.activite_principale ?? null,
        city: etab.libelle_commune ?? null,
        postal_code: etab.code_postal ?? null,
      },
    };
  }
  return { found: false };
}
