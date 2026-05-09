import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

type DnrResourceType =
  | 'main_frame'
  | 'sub_frame'
  | 'stylesheet'
  | 'script'
  | 'image'
  | 'font'
  | 'xmlhttprequest'
  | 'other';

interface DnrRule {
  id: number;
  priority: number;
  action:
    | { type: 'block' }
    | {
        type: 'redirect';
        redirect: {
          extensionPath: string;
        };
      };
  condition: {
    regexFilter?: string;
    urlFilter?: string;
    resourceTypes: DnrResourceType[];
  };
}

interface DynamicRuleUpdate {
  addRules: DnrRule[];
  removeRuleIds: number[];
}

const PRIORITY = {
  blockedPath: 300,
  blockedSubdomain: 200,
} as const;

const BLOCKED_PATH_REDIRECT_RULE_ID = 10_000;
const BLOCKED_PATH_BLOCK_RULE_ID = 11_000;
const BLOCKED_SUBDOMAIN_REDIRECT_RULE_ID = 20_000;
const BLOCKED_SUBDOMAIN_BLOCK_RULE_ID = 21_000;

const BLOCKED_SCREEN_EXTENSION_PATH = '/blocked/blocked.html';
const BLOCKABLE_SUBRESOURCE_TYPES: DnrResourceType[] = [
  'sub_frame',
  'xmlhttprequest',
  'script',
  'stylesheet',
  'image',
  'font',
  'other',
];

function escapeRegex(value: string): string {
  return value.replace(/[\\^$+?.()|[\]{}]/g, '\\$&');
}

function encodeReason(reason: string): string {
  return encodeURIComponent(reason);
}

function buildStaticBlockedScreenPath(reason: string, rawRule: string): string {
  return `${BLOCKED_SCREEN_EXTENSION_PATH}?error=${encodeReason(reason)}&rule=${encodeURIComponent(
    rawRule
  )}`;
}

function pathRuleToRegexFilter(rawRule: string): string {
  const normalized = rawRule
    .trim()
    .toLowerCase()
    .replace(/^(?:https?:\/\/|\*:\/\/)/, '');
  const slashIndex = normalized.indexOf('/');
  assert.notEqual(slashIndex, -1, 'path DNR spike only models host/path rules');

  const host = normalized.slice(0, slashIndex).replace(/^\*\./, '');
  const pathGlob = normalized.slice(slashIndex).replace(/\*/g, '.*');

  return `^https?://([^/?#]+\\.)?${escapeRegex(host)}${pathGlob}(?:[?#].*)?$`;
}

function buildBlockedPathDnrRules(rawRule: string, offset = 0): DnrRule[] {
  const reason = `BLOCKED_PATH_POLICY:${rawRule}`;
  const regexFilter = pathRuleToRegexFilter(rawRule);

  return [
    {
      id: BLOCKED_PATH_REDIRECT_RULE_ID + offset,
      priority: PRIORITY.blockedPath,
      action: {
        type: 'redirect',
        redirect: {
          extensionPath: buildStaticBlockedScreenPath(reason, rawRule),
        },
      },
      condition: {
        regexFilter,
        resourceTypes: ['main_frame'],
      },
    },
    {
      id: BLOCKED_PATH_BLOCK_RULE_ID + offset,
      priority: PRIORITY.blockedPath,
      action: { type: 'block' },
      condition: {
        regexFilter,
        resourceTypes: ['sub_frame', 'xmlhttprequest'],
      },
    },
  ];
}

function buildBlockedSubdomainDnrRules(rawRule: string, offset = 0): DnrRule[] {
  const normalized = rawRule.trim().toLowerCase().replace(/^\*\./, '');
  const reason = `BLOCKED_SUBDOMAIN_POLICY:${rawRule.trim().toLowerCase()}`;
  const urlFilter = `||${normalized}/`;

  return [
    {
      id: BLOCKED_SUBDOMAIN_REDIRECT_RULE_ID + offset,
      priority: PRIORITY.blockedSubdomain,
      action: {
        type: 'redirect',
        redirect: {
          extensionPath: buildStaticBlockedScreenPath(reason, rawRule),
        },
      },
      condition: {
        urlFilter,
        resourceTypes: ['main_frame'],
      },
    },
    {
      id: BLOCKED_SUBDOMAIN_BLOCK_RULE_ID + offset,
      priority: PRIORITY.blockedSubdomain,
      action: { type: 'block' },
      condition: {
        urlFilter,
        resourceTypes: BLOCKABLE_SUBRESOURCE_TYPES,
      },
    },
  ];
}

function buildNativeHostDynamicRuleUpdate(input: {
  previousRuleIds: number[];
  blockedPaths: string[];
  blockedSubdomains: string[];
}): DynamicRuleUpdate {
  return {
    removeRuleIds: input.previousRuleIds,
    addRules: [
      ...input.blockedPaths.flatMap((rule, index) => buildBlockedPathDnrRules(rule, index)),
      ...input.blockedSubdomains.flatMap((rule, index) =>
        buildBlockedSubdomainDnrRules(rule, index)
      ),
    ],
  };
}

void describe('Firefox DNR equivalence spike', () => {
  void test('models top-frame redirects to the blocked screen with static context', () => {
    const [redirectRule] = buildBlockedPathDnrRules('example.com/private');

    assert.deepEqual(redirectRule, {
      id: BLOCKED_PATH_REDIRECT_RULE_ID,
      priority: PRIORITY.blockedPath,
      action: {
        type: 'redirect',
        redirect: {
          extensionPath:
            '/blocked/blocked.html?error=BLOCKED_PATH_POLICY%3Aexample.com%2Fprivate&rule=example.com%2Fprivate',
        },
      },
      condition: {
        regexFilter: '^https?://([^/?#]+\\.)?example\\.com/private(?:[?#].*)?$',
        resourceTypes: ['main_frame'],
      },
    });
  });

  void test('creates a replace-all dynamic rule update from native-host state', () => {
    const update = buildNativeHostDynamicRuleUpdate({
      previousRuleIds: [10_000, 11_000, 20_000],
      blockedPaths: ['example.com/private'],
      blockedSubdomains: ['media.example.test'],
    });

    assert.deepEqual(update.removeRuleIds, [10_000, 11_000, 20_000]);
    assert.equal(update.addRules.length, 4);
    assert.deepEqual(
      update.addRules.map((rule) => rule.id),
      [10_000, 11_000, 20_000, 21_000]
    );
  });

  void test('represents one blocked path as redirect plus subresource block rules', () => {
    const rules = buildBlockedPathDnrRules('example.com/private');
    const blockRule = rules[1];
    assert.ok(blockRule);

    assert.equal(blockRule.action.type, 'block');
    assert.equal(blockRule.priority, PRIORITY.blockedPath);
    assert.equal(
      blockRule.condition.regexFilter,
      '^https?://([^/?#]+\\.)?example\\.com/private(?:[?#].*)?$'
    );
    assert.deepEqual(blockRule.condition.resourceTypes, ['sub_frame', 'xmlhttprequest']);
  });

  void test('represents one blocked subdomain as redirect plus broad subresource block rules', () => {
    const rules = buildBlockedSubdomainDnrRules('*.media.example.test');
    const redirectRule = rules[0];
    const blockRule = rules[1];
    assert.ok(redirectRule);
    assert.ok(blockRule);

    assert.equal(redirectRule.condition.urlFilter, '||media.example.test/');
    assert.deepEqual(redirectRule.condition.resourceTypes, ['main_frame']);
    assert.equal(blockRule.action.type, 'block');
    assert.deepEqual(blockRule.condition.resourceTypes, BLOCKABLE_SUBRESOURCE_TYPES);
  });

  void test('keeps path and subdomain policies ordered without auto-allow rules', () => {
    const update = buildNativeHostDynamicRuleUpdate({
      previousRuleIds: [],
      blockedPaths: ['example.com/private'],
      blockedSubdomains: ['media.example.test'],
    });
    const actions = new Set(update.addRules.map((rule) => rule.action.type));

    const priorities = [PRIORITY.blockedPath, PRIORITY.blockedSubdomain];
    assert.deepEqual(
      [...priorities].sort((a, b) => b - a),
      priorities
    );
    assert.deepEqual(actions, new Set(['redirect', 'block']));
  });
});
