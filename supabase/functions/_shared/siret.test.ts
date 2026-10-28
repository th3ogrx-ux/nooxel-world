// Lancer : node --experimental-strip-types --test supabase/functions/_shared/siret.test.ts
import test from "node:test";
import assert from "node:assert/strict";
import { isValidSiretFormat, normalizeSiret, parseCompanySearch } from "./siret.ts";
import { mapError } from "./errors.ts";

test("normalisation : espaces, points et tirets retirés", () => {
  assert.equal(normalizeSiret("732 829 320 00074"), "73282932000074");
  assert.equal(normalizeSiret(null), "");
});
test("clé de Luhn : SIRET connus valides, altérés invalides", () => {
  assert.equal(isValidSiretFormat("73282932000074"), true);   // exemple public de l'INSEE
  assert.equal(isValidSiretFormat("73282932000075"), false);
  assert.equal(isValidSiretFormat("1234"), false);
  assert.equal(isValidSiretFormat("7328293200007a"), false);
  assert.equal(isValidSiretFormat("12345678901234"), false);
});
test("La Poste : le siège passe Luhn ; les autres établissements via la règle « somme multiple de 5 »", () => {
  assert.equal(isValidSiretFormat("35600000000048"), true);    // siège de La Poste, valide par Luhn
  assert.equal(isValidSiretFormat("35600000000010"), true);    // somme = 15 (règle La Poste)
  assert.equal(isValidSiretFormat("35600000000011"), false);   // ni Luhn ni somme multiple de 5
  assert.equal(isValidSiretFormat("12300000000010"), false);   // la règle La Poste ne s'applique qu'à ce SIREN
});
const sample = (over: any = {}) => ({ results: [{
  siren: "732829320", nom_complet: "BOULANGERIE TEST", etat_administratif: "A",
  siege: { siret: "73282932000074", etat_administratif: "A", libelle_commune: "GRENOBLE", code_postal: "38000" },
  matching_etablissements: [{ siret: "73282932000090", etat_administratif: "F" }],
  dirigeants: [{ nom: "DUPONT", prenoms: "Jean" }], ...over }] });
test("réponse API : établissement actif trouvé, sans données de dirigeants", () => {
  const r: any = parseCompanySearch(sample(), "73282932000074");
  assert.equal(r.found, true); assert.equal(r.active, true);
  assert.equal(r.check.name, "BOULANGERIE TEST"); assert.equal(r.check.city, "GRENOBLE");
  assert.ok(!JSON.stringify(r.check).includes("DUPONT"));
});
test("réponse API : établissement fermé, entreprise fermée, SIRET absent", () => {
  assert.equal((parseCompanySearch(sample(), "73282932000090") as any).active, false);
  assert.equal((parseCompanySearch(sample({ etat_administratif: "C" }), "73282932000074") as any).active, false);
  assert.equal(parseCompanySearch(sample(), "99999999999999").found, false);
  assert.equal(parseCompanySearch({}, "73282932000074").found, false);
  assert.equal(parseCompanySearch({ results: "n'importe quoi" }, "73282932000074").found, false);
});
test("erreurs SQL → statut HTTP et message français", () => {
  assert.equal(mapError("email_not_confirmed").status, 403);
  assert.equal(mapError("too_many_attempts").status, 429);
  assert.equal(mapError('Error: forbidden').status, 403);
  assert.equal(mapError("quelque chose d'imprévu").status, 500);
  assert.match(mapError("siret_already_claimed").message, /déjà associé/);
});
