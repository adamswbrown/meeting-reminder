"use client";

import { useSyncExternalStore } from "react";
import { config } from "@/lib/config";
import type { SlotDescriptor } from "@/lib/booking";

interface Props {
  startISO: string;
  endISO: string;
  /** Pre-formatted heading for the day this slot belongs to. */
  dayLabel: string;
  /** Fires when the visitor clicks the slot. The fully-formed
   *  SlotDescriptor (including visitor-tz renders) is passed up so the
   *  dialog can construct deep-links/ICS/mailto without redoing the work. */
  onSelect: (descriptor: SlotDescriptor) => void;
}

interface TZRender {
  /** "14:30–15:30" */
  label: string;
  /** "BST" */
  tzAbbr: string;
}

/**
 * Format a UTC interval as a wall-clock time range in the given timezone.
 * en-GB locale gives 24-hour output, which matches British conventions and
 * removes AM/PM ambiguity across timezones.
 */
function formatRange(start: Date, end: Date, tzName: string): TZRender {
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: tzName,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const tzFmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: tzName,
    timeZoneName: "short",
  });
  return {
    label: `${fmt.format(start)}–${fmt.format(end)}`,
    tzAbbr:
      tzFmt.formatToParts(start).find((p) => p.type === "timeZoneName")
        ?.value ?? "",
  };
}

const subscribe = () => () => {};
const getVisitorTZ = () => Intl.DateTimeFormat().resolvedOptions().timeZone;
const getServerTZ = () => config.timezone;

/**
 * A single bookable slot card.
 *
 * Layout depends on whether the visitor is in London:
 * - London visitor → render London time only (primary).
 * - Anywhere else → visitor's local time is primary, London is the
 *   secondary annotation below. This removes the mental math for the
 *   most common "transatlantic call" case.
 *
 * Click opens the slot actions dialog with Outlook/Google/ICS/mailto
 * options — the SlotCard is now pure presentation + click forwarding.
 */
export function SlotCard({ startISO, endISO, dayLabel, onSelect }: Props) {
  const visitorTZ = useSyncExternalStore(
    subscribe,
    getVisitorTZ,
    getServerTZ
  );

  const start = new Date(startISO);
  const end = new Date(endISO);
  const ownerRender = formatRange(start, end, config.timezone);
  const visitorIsLondon = visitorTZ === config.timezone;
  const visitorRender = visitorIsLondon
    ? null
    : formatRange(start, end, visitorTZ);

  // Primary = what the visitor reads at a glance. Secondary = the other tz
  // shown as a smaller annotation. London visitors only see the primary.
  const primary = visitorRender ?? ownerRender;
  const secondary = visitorRender ? ownerRender : null;

  function handleClick() {
    onSelect({
      startISO,
      endISO,
      dayLabel,
      ownerLabel: ownerRender.label,
      ownerTZAbbr: ownerRender.tzAbbr,
      visitorLabel: visitorRender?.label,
      visitorTZAbbr: visitorRender?.tzAbbr,
    });
  }

  return (
    <button
      onClick={handleClick}
      className="group relative flex flex-col items-start rounded-xl border border-zinc-200 bg-white px-4 py-3 text-left transition hover:border-zinc-300 hover:shadow-sm focus:outline-none focus:ring-2 focus:ring-zinc-900 dark:border-zinc-800 dark:bg-zinc-950 dark:hover:border-zinc-700 dark:focus:ring-zinc-100"
      aria-label={`Book ${primary.label} ${primary.tzAbbr}`}
    >
      <span className="font-mono text-base font-medium tabular-nums text-zinc-900 dark:text-zinc-100">
        {primary.label}
      </span>
      <span className="mt-0.5 text-xs uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
        {primary.tzAbbr}
        {secondary && (
          <span className="ml-2 normal-case tracking-normal text-zinc-400 dark:text-zinc-500">
            &middot; {secondary.label} {secondary.tzAbbr}
          </span>
        )}
      </span>
      <span className="absolute right-3 top-3 text-[10px] font-medium uppercase tracking-wide text-zinc-400 opacity-0 transition group-hover:opacity-100 dark:text-zinc-600">
        Book
      </span>
    </button>
  );
}
