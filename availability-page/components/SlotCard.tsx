"use client";

import { useState, useSyncExternalStore } from "react";
import { config } from "@/lib/config";

interface Props {
  startISO: string;
  endISO: string;
  /** Pre-formatted owner-tz time range, e.g. "14:30–15:30". */
  ownerLabel: string;
  /** Pre-formatted owner-tz abbreviation, e.g. "BST". */
  ownerTZAbbr: string;
  /** Pre-formatted day label, e.g. "Tomorrow". */
  dayLabel: string;
}

interface VisitorInfo {
  label: string;
  tzAbbr: string;
}

/**
 * Compute the visitor's local rendition of a UTC slot. Runs only on the
 * client (server snapshot returns null) so that hydration matches SSR.
 */
function computeVisitorInfo(startISO: string, endISO: string): VisitorInfo | null {
  const visitorTZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (visitorTZ === config.timezone) return null;

  const start = new Date(startISO);
  const end = new Date(endISO);
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: visitorTZ,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const tzFmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: visitorTZ,
    timeZoneName: "short",
  });

  return {
    label: `${fmt.format(start)}–${fmt.format(end)}`,
    tzAbbr:
      tzFmt.formatToParts(start).find((p) => p.type === "timeZoneName")
        ?.value ?? "",
  };
}

// `useSyncExternalStore` with a noop subscribe is the idiomatic way to
// expose a client-only value to a server-rendered component in React 19.
// SSR / first render returns null; hydration replaces it with the real
// visitor info without tripping the set-state-in-effect lint rule.
const subscribe = () => () => {};

/** Renders a single free slot. Click copies a nicely-formatted blurb. */
export function SlotCard({
  startISO,
  endISO,
  ownerLabel,
  ownerTZAbbr,
  dayLabel,
}: Props) {
  const visitor = useSyncExternalStore<VisitorInfo | null>(
    subscribe,
    () => computeVisitorInfo(startISO, endISO),
    () => null
  );

  const [copied, setCopied] = useState(false);

  async function copy() {
    const owner = `${ownerLabel} ${ownerTZAbbr}`;
    const visitorBit = visitor
      ? ` (${visitor.label} ${visitor.tzAbbr} your time)`
      : "";
    const text = `${config.ownerFirstName} is free ${dayLabel.toLowerCase()} ${owner}${visitorBit}.`;
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Silently no-op — the slot text is still readable on screen.
    }
  }

  return (
    <button
      onClick={copy}
      className="group relative flex flex-col items-start rounded-xl border border-zinc-200 bg-white px-4 py-3 text-left transition hover:border-zinc-300 hover:shadow-sm focus:outline-none focus:ring-2 focus:ring-zinc-900 dark:border-zinc-800 dark:bg-zinc-950 dark:hover:border-zinc-700 dark:focus:ring-zinc-100"
      aria-label={`Copy slot ${ownerLabel} ${ownerTZAbbr}`}
    >
      <span className="font-mono text-base font-medium tabular-nums text-zinc-900 dark:text-zinc-100">
        {ownerLabel}
      </span>
      <span className="mt-0.5 text-xs uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
        {ownerTZAbbr}
        {visitor && (
          <span className="ml-2 normal-case tracking-normal text-zinc-400 dark:text-zinc-500">
            · {visitor.label} {visitor.tzAbbr}
          </span>
        )}
      </span>
      <span
        className={`absolute right-3 top-3 text-[10px] font-medium uppercase tracking-wide transition ${
          copied
            ? "text-emerald-600 dark:text-emerald-400"
            : "text-zinc-400 opacity-0 group-hover:opacity-100 dark:text-zinc-600"
        }`}
      >
        {copied ? "Copied" : "Copy"}
      </span>
    </button>
  );
}
