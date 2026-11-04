import crypto from 'node:crypto';

const LOCAL_PROVIDERS = new Set(['ollama', 'lmstudio', 'local', 'llamacpp', 'llama.cpp', 'vllm']);
const REASONING_SUFFIX = /#(minimal|low|medium|high|xhigh)$/i;

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
    policy, reasoningVariant: variant, limits: null, limitPolicy: { mode: 'critical', amount: 0 }, runControls: { maxIterations: 0 },
    usageSource: policy === 'local' ? { kind: 'none' } : { kind: 'snapshot', unit: 'percent', remaining: null, reserve: 5, maxAgeMinutes: 120, observedAt: '' },
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
    policy, reasoningVariant: String(profile?.reasoningVariant || parsed.reasoningVariant || ''),
    limits: profile?.limits && typeof profile.limits === 'object' ? structuredClone(profile.limits) : null,
    limitPolicy: { mode: String(profile?.limitPolicy?.mode || 'critical'), amount: Number(profile?.limitPolicy?.amount || 0) || 0 },
    runControls: { maxIterations: Number(profile?.runControls?.maxIterations || 0) || 0 },
    usageSource: policy === 'local' ? { kind: 'none' } : {
      kind: 'snapshot', unit: String(profile?.usageSource?.unit || 'percent'), remaining: profile?.usageSource?.remaining ?? null,
      reserve: Number(profile?.usageSource?.reserve ?? 5), maxAgeMinutes: Number(profile?.usageSource?.maxAgeMinutes ?? 120), observedAt: String(profile?.usageSource?.observedAt || '')
    },
    showThinking: Boolean(profile?.showThinking)
  };
}

export function migrateProfiles(settings) {
  const openCode = settings.openCode ||= {};
  const accounts = Array.isArray(openCode.accounts) ? openCode.accounts : [];
  if (Array.isArray(openCode.profiles) && openCode.profiles.length) {
    // Keep object identity: profile detail screens hold a reference while the
    // dashboard redraws and normalizes settings between prompt interactions.
    // Replacing the array here used to make a freshly entered snapshot vanish.
    openCode.profiles.forEach((profile, index) => Object.assign(profile, normalizeProfile(openCode.profiles[index])));
    // v1.6.0 profiles predate profile-scoped API limits. Preserve the legacy
    // budget for each existing API profile instead of showing a zero floor.
    for (const profile of openCode.profiles) {
      if (profile.policy === 'api' && !profile.limits) profile.limits = structuredClone(settings.budget || {});
      const account = accounts.find(item => item.provider === profile.provider && item.credentialId === profile.credentialId);
      // Repair snapshots written by early v1.6 screens: their account update
      // succeeded, but a redraw replaced the profile object before save.
      if (profile.policy !== 'local' && profile.usageSource?.remaining == null && account?.quota?.configured) {
        profile.usageSource = { kind: 'snapshot', unit: account.quota.unit, remaining: account.quota.remaining, reserve: account.quota.reserve, maxAgeMinutes: account.quota.maxAgeMinutes, observedAt: account.quota.observedAt };
      }
    }
    if (!openCode.profiles.some(p => p.id === openCode.activeProfileId)) openCode.activeProfileId = openCode.profiles[0].id;
    return openCode.profiles;
  }
  const active = accounts.find(a => a.id === openCode.activeAccountId) || null;
  const reasoning = openCode.reasoning || {};
  const model = String(settings.model || '');
  const profile = profileFrom(model, active, reasoning.variant, reasoning.showThinking);
  if (profile.policy === 'api') profile.limits = structuredClone(settings.budget || {});
  openCode.profiles = model ? [profile] : [];
  openCode.activeProfileId = profile.id;
  return openCode.profiles;
}

export function activeProfile(settings) {
  const profiles = migrateProfiles(settings);
  return profiles.find(p => p.id === settings.openCode.activeProfileId) || profiles[0] || null;
}

export function profileTitle(profile) {
  if (!profile) return 'No profile selected';
  const policy = profile.policy === 'api' ? 'API spending limits' : profile.policy === 'oauth-managed' ? 'OAuth provider-managed usage' : 'Local / no limits';
  return `${profile.model}${profile.reasoningVariant ? `#${profile.reasoningVariant}` : ''} — ${policy}`;
}

export function applyProfile(settings, profile) {
  const openCode = settings.openCode ||= {};
  openCode.profiles ||= [];
  openCode.activeProfileId = profile.id;
  settings.model = `${profile.model}${profile.reasoningVariant ? `#${profile.reasoningVariant}` : ''}`;
  openCode.reasoning = { variant: profile.reasoningVariant || '', showThinking: Boolean(profile.showThinking) };
  if (profile.policy === 'api' && profile.limits) settings.budget = structuredClone(profile.limits);
  if (profile.policy === 'local') {
    const localId = `local:${profile.provider}`;
    const index = openCode.accounts.findIndex(a => a.id === localId);
    const local = { id: localId, provider: profile.provider, credentialId: '', label: 'Local inference', authMethod: 'local', usageKind: 'local' };
    if (index >= 0) openCode.accounts[index] = local; else openCode.accounts.push(local);
    openCode.activeAccountId = localId;
  } else {
    const account = openCode.accounts.find(a => a.credentialId === profile.credentialId && a.provider === profile.provider);
    if (!account) throw new Error('The selected OpenCode credential is no longer available. Refresh profiles and select it again.');
    const policy = profile.limitPolicy || { mode: 'critical' };
    if (policy.mode === 'unlimited') { account.usageKind = 'unlimited'; openCode.activeAccountId = account.id; return; }
    if (profile.policy === 'api' && ['daily', 'hourly'].includes(policy.mode)) {
      settings.budget ||= {}; settings.budget.mode = policy.mode;
      if (policy.mode === 'daily') settings.budget.dailyUsd = policy.amount;
      else settings.budget.hourlyUsd = policy.amount;
      account.usageKind = 'balance'; openCode.activeAccountId = account.id; return;
    }
    account.usageKind = 'quota';
    const snapshot = profile.usageSource || {};
    const refresh = policy.mode === 'refresh-hourly' ? 60 : policy.mode === 'refresh-daily' ? 1440 : snapshot.maxAgeMinutes ?? 120;
    account.quota = { configured: snapshot.kind === 'snapshot' && snapshot.remaining !== null, unit: snapshot.unit || 'percent', remaining: snapshot.remaining, reserve: snapshot.reserve ?? 5, maxAgeMinutes: refresh, observedAt: snapshot.observedAt || '' };
    openCode.activeAccountId = account.id;
  }
}
