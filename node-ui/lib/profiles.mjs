import crypto from 'node:crypto';

const LOCAL_PROVIDERS = new Set(['ollama', 'lmstudio', 'local', 'llamacpp', 'llama.cpp', 'vllm']);
const REASONING_SUFFIX = /#(minimal|low|medium|high|xhigh)$/i;
export function defaultApiLimits() {
  return { mode: 'daily', dailyUsd: 5, reserveUsd: .5, emergencyStopUsd: 4.95, allowUnlimited: false, requireGlobalOpenCodeStats: true, stopOnZeroCostWithTokens: true, balance: { source: 'snapshot', id: '', minimumUsd: 5, iterationReserveUsd: .5, maxAgeMinutes: 5, command: '', arguments: [] } };
}
export function splitModelVariant(value = '') {
  const text = String(value).trim(); const match = text.match(REASONING_SUFFIX);
  return { model: match ? text.slice(0, -match[0].length) : text, reasoningVariant: match ? match[1].toLowerCase() : '' };
}

export function modelProvider(model = '') {
  return String(model).trim().split('/')[0].toLowerCase();
}

export function isLocalModel(model = '') {
  return LOCAL_PROVIDERS.has(modelProvider(model));
}

export function policyFor(model, account) {
  if (isLocalModel(model)) return 'local';
  return String(account?.authMethod || '').toLowerCase() === 'oauth' ? 'oauth-managed' : 'api';
}

export function profileFrom(model, account = null, reasoningVariant = '', showThinking = false) {
  const parsed = splitModelVariant(model); const variant = String(reasoningVariant || parsed.reasoningVariant || '');
  const policy = policyFor(parsed.model, account);
  return {
    id: crypto.randomUUID(),
    model: parsed.model,
    provider: modelProvider(parsed.model),
    credentialId: policy === 'local' ? '' : String(account?.credentialId || ''),
    credentialLabel: policy === 'local' ? 'No credential (local inference)' : String(account?.label || ''),
    authStoreId: policy === 'local' ? '' : 'legacy-shared',
    policy, reasoningVariant: variant, limits: null, limitPolicy: { mode: 'critical', amount: null, reserve: null }, runControls: { maxIterations: 0 },
    usageSource: policy === 'local' ? { kind: 'none' } : { kind: 'snapshot', unit: 'percent', remaining: null, reserve: 5, maxAgeMinutes: 120, observedAt: '', costTracking: { enabled: false, baselineAllTimeCostUsd: null, baselineObservedAt: '' } },
    showThinking: Boolean(showThinking)
  };
}

export function normalizeProfile(profile) {
  const parsed = splitModelVariant(profile?.model); const model = parsed.model;
  const policy = ['api', 'oauth-managed', 'local'].includes(profile?.policy)
    ? profile.policy
    : policyFor(model, { authMethod: profile?.authMethod });
  return {
    id: String(profile?.id || crypto.randomUUID()), model, provider: modelProvider(model),
    credentialId: policy === 'local' ? '' : String(profile?.credentialId || ''),
    credentialLabel: policy === 'local' ? 'No credential (local inference)' : String(profile?.credentialLabel || ''),
    authStoreId: policy === 'local' ? '' : String(profile?.authStoreId || 'legacy-shared'),
    policy, reasoningVariant: String(profile?.reasoningVariant || parsed.reasoningVariant || ''),
    limits: profile?.limits && typeof profile.limits === 'object' ? structuredClone(profile.limits) : null,
    limitPolicy: { mode: String(profile?.limitPolicy?.mode || 'critical'), amount: profile?.limitPolicy?.amount ?? null, reserve: profile?.limitPolicy?.reserve ?? profile?.usageSource?.reserve ?? null, configured: Boolean(profile?.limitPolicy?.configured) },
    runControls: { maxIterations: Number(profile?.runControls?.maxIterations || 0) || 0 },
    usageSource: policy === 'local' ? { kind: 'none' } : {
      kind: 'snapshot', unit: String(profile?.usageSource?.unit || 'percent'), remaining: profile?.usageSource?.remaining ?? null,
      reserve: Number(profile?.usageSource?.reserve ?? 5), maxAgeMinutes: Number(profile?.usageSource?.maxAgeMinutes ?? 120), observedAt: String(profile?.usageSource?.observedAt || ''),
      costTracking: { enabled: Boolean(profile?.usageSource?.costTracking?.enabled), baselineAllTimeCostUsd: profile?.usageSource?.costTracking?.baselineAllTimeCostUsd ?? null, baselineObservedAt: String(profile?.usageSource?.costTracking?.baselineObservedAt || '') }
    },
    showThinking: Boolean(profile?.showThinking)
  };
}

export function migrateProfiles(settings) {
  const openCode = settings.openCode ||= {};
  const accounts = Array.isArray(openCode.accounts) ? openCode.accounts : [];
  const legacyBudget = settings.budget && typeof settings.budget === 'object' ? structuredClone(settings.budget) : defaultApiLimits();
  if (Array.isArray(openCode.profiles) && openCode.profiles.length) {
    // Keep object identity: profile detail screens hold a reference while the
    // dashboard redraws and normalizes settings between prompt interactions.
    // Replacing the array here used to make a freshly entered snapshot vanish.
    openCode.profiles.forEach((profile, index) => Object.assign(profile, normalizeProfile(openCode.profiles[index])));
    // v1.6.0 profiles predate profile-scoped API limits. Preserve the legacy
    // budget for each existing API profile instead of showing a zero floor.
    for (const profile of openCode.profiles) {
      if (profile.policy === 'api' && !profile.limits) profile.limits = structuredClone(legacyBudget);
      const account = accounts.find(item => item.provider === profile.provider && item.credentialId === profile.credentialId);
      // Repair snapshots written by early v1.6 screens: their account update
      // succeeded, but a redraw replaced the profile object before save.
      if (profile.policy !== 'local' && profile.usageSource?.remaining == null && account?.quota?.configured) {
        profile.usageSource = { kind: 'snapshot', unit: account.quota.unit, remaining: account.quota.remaining, reserve: account.quota.reserve, maxAgeMinutes: account.quota.maxAgeMinutes, observedAt: account.quota.observedAt };
      }
    }
  } else {
    const active = accounts.find(a => a.id === openCode.activeAccountId) || null;
    const reasoning = openCode.reasoning || {};
    const model = String(settings.model || '');
    const profile = profileFrom(model, active, reasoning.variant, reasoning.showThinking);
    if (profile.policy === 'api') profile.limits = structuredClone(legacyBudget);
    openCode.profiles = model ? [profile] : [];
  }
  delete openCode.activeProfileId;
  delete openCode.activeAccountId;
  delete openCode.reasoning;
  delete settings.model;
  delete settings.budget;
  return openCode.profiles;
}
