import { config } from "./config";

/**
 * Direct REST calls against Supabase's PostgREST. Avoids the `@supabase/supabase-js`
 * dependency — we only need two GETs and want full control over the `next.revalidate`
 * cache option on each one.
 */

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  // Fail loudly at build/start time rather than producing a confusing
  // 401 at request time.
  throw new Error(
    "Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY. See .env.local.example."
  );
}

// Catch the most common footgun: copying the placeholder from
// .env.local.example verbatim. The literal "…" ellipsis (char code 8230)
// can't be serialised into an HTTP header and produces a cryptic
// "Cannot convert argument to a ByteString" error deep in undici.
if (/[^\x20-\x7e]/.test(SUPABASE_ANON_KEY)) {
  throw new Error(
    "NEXT_PUBLIC_SUPABASE_ANON_KEY contains a non-ASCII character — did you paste the placeholder value 'sb_publishable_…' verbatim? Replace it with your real publishable key from Supabase → Project Settings → API."
  );
}

export interface FreeBusyEvent {
  event_id: string;
  start_utc: string;
  end_utc: string;
  is_all_day: boolean;
  is_tentative: boolean;
  status: "confirmed" | "tentative" | "cancelled";
}

export interface SyncState {
  last_synced_at: string;
  events_in_window: number;
}

async function rest<T>(path: string): Promise<T> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
    next: { revalidate: config.revalidateSeconds },
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`Supabase HTTP ${res.status}${body ? ` — ${body}` : ""}`);
  }

  return (await res.json()) as T;
}

/**
 * Fetch the busy intervals visible to anon for the next N days, ordered.
 * The public_freebusy view already filters out cancelled events and exposes
 * only non-sensitive columns.
 */
export async function fetchFreeBusy(): Promise<FreeBusyEvent[]> {
  const now = new Date();
  const horizon = new Date(now);
  horizon.setUTCDate(horizon.getUTCDate() + config.lookAheadDays);

  // PostgREST filter encoding: column=op.value, joined with &.
  const params = new URLSearchParams({
    select: "event_id,start_utc,end_utc,is_all_day,is_tentative,status",
    start_utc: `gte.${now.toISOString()}`,
    end_utc: `lt.${horizon.toISOString()}`,
    order: "start_utc.asc",
  });

  // Special-case: PostgREST encodes commas in `select=` differently than
  // URLSearchParams, but commas are safe in PostgREST select lists so we
  // need to swap %2C back to a literal comma.
  const query = params.toString().replace(/%2C/g, ",");
  return rest<FreeBusyEvent[]>(`public_freebusy?${query}`);
}

export async function fetchSyncState(): Promise<SyncState | null> {
  const rows = await rest<SyncState[]>(
    "sync_state?select=last_synced_at,events_in_window&id=eq.1&limit=1"
  );
  return rows[0] ?? null;
}
