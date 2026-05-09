import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import {
  EDUCATION_DOMAIN_RECIPES,
  LOCAL_LEARNING_DEFAULT_ENABLED,
  LOCAL_LEARNING_STATES,
} from '../src/education-domain-recipes.js';

const acceptedDomainPattern =
  /^(?!\*\.)[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/u;

describe('education domain recipes', () => {
  it('defines named recipes with non-empty descriptions and domains', () => {
    assert.deepEqual(
      EDUCATION_DOMAIN_RECIPES.map((recipe) => recipe.id),
      ['google-classroom', 'microsoft-365-education', 'moodle', 'youtube-educational']
    );

    for (const recipe of EDUCATION_DOMAIN_RECIPES) {
      assert.notEqual(recipe.name.trim(), '');
      assert.notEqual(recipe.description.trim(), '');
      assert.ok(recipe.domains.length > 0, `${recipe.id} should include at least one domain`);
    }
  });

  it('does not include wildcard entries that normal rule validators cannot accept', () => {
    for (const recipe of EDUCATION_DOMAIN_RECIPES) {
      for (const domain of recipe.domains) {
        assert.match(domain, acceptedDomainPattern, `${recipe.id} has invalid domain ${domain}`);
      }
    }
  });

  it('does not include duplicate domains inside or across recipes', () => {
    const seen = new Map<string, string>();

    for (const recipe of EDUCATION_DOMAIN_RECIPES) {
      for (const domain of recipe.domains) {
        const previousRecipe = seen.get(domain);
        assert.equal(
          previousRecipe,
          undefined,
          `${domain} appears in both ${previousRecipe ?? 'unknown'} and ${recipe.id}`
        );
        seen.set(domain, recipe.id);
      }
    }
  });

  it('keeps local learning disabled by default with explicit state names', () => {
    assert.equal(LOCAL_LEARNING_DEFAULT_ENABLED, false);
    assert.deepEqual(LOCAL_LEARNING_STATES, [
      'observed',
      'candidate',
      'session_allow',
      'local_confirmed',
      'expired',
    ]);
  });
});
