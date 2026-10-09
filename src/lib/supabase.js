import { createClient } from '@supabase/supabase-js';

// Prefer build-time variables when supplied, but do not depend on Cloudflare's
// build-variable injection: public/supabase-config.json is the runtime fallback.
export let supabase = null;
export let supabaseConfigError = true;

let initialization;

function validConfig(url, key) {
  if (typeof url !== 'string' || typeof key !== 'string') return false;
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || !parsed.hostname.endsWith('.supabase.co')) return false;
  } catch {
    return false;
  }
  // Supabase publishable keys are public client keys. Never accept service-role keys.
  return key.startsWith('sb_publishable_') || (key.startsWith('eyJ') && key.split('.').length === 3);
}

export function initializeSupabase() {
  if (initialization) return initialization;
  initialization = (async () => {
    let url = import.meta.env.VITE_SUPABASE_URL;
    let key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

    if (!validConfig(url, key)) {
      try {
        const response = await fetch('/supabase-config.json', {
          cache: 'no-store',
          headers: { Accept: 'application/json' },
        });
        if (!response.ok) throw new Error('Runtime config request failed');
        const config = await response.json();
        url = config.supabaseUrl;
        key = config.supabasePublishableKey;
      } catch {
        // The UI will show a safe configuration diagnostic instead of crashing.
      }
    }

    if (!validConfig(url, key)) {
      supabase = null;
      supabaseConfigError = true;
      return null;
    }

    supabase = createClient(url.replace(/\\/$/, ''), key, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    });
    supabaseConfigError = false;
    return supabase;
  })();
  return initialization;
}
