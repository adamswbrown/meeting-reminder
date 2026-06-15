import { config } from "@/lib/config";
import { formatRelativeTime } from "@/lib/format";

interface Props {
  lastSyncedAt: Date | null;
  now: Date;
}

/**
 * Renders a small pill explaining how fresh the data is. When the Mac has
 * been offline > `stalenessWarnAfterMinutes`, switches to a warning style
 * so visitors know to treat the slots as approximate.
 */
export function StalenessPill({ lastSyncedAt, now }: Props) {
  if (!lastSyncedAt) {
    return (
      <span className="inline-flex items-center gap-1.5 rounded-full bg-amber-50 px-2.5 py-1 text-xs font-medium text-amber-700 dark:bg-amber-950 dark:text-amber-300">
        <span className="size-1.5 rounded-full bg-amber-500" />
        No sync yet
      </span>
    );
  }

  const minutesAgo = (now.getTime() - lastSyncedAt.getTime()) / 60_000;
  const stale = minutesAgo > config.stalenessWarnAfterMinutes;

  if (stale) {
    return (
      <span
        className="inline-flex items-center gap-1.5 rounded-full bg-amber-50 px-2.5 py-1 text-xs font-medium text-amber-700 dark:bg-amber-950 dark:text-amber-300"
        title={`Last synced ${lastSyncedAt.toISOString()}`}
      >
        <span className="size-1.5 rounded-full bg-amber-500" />
        Updated {formatRelativeTime(lastSyncedAt, now)} — may be out of date
      </span>
    );
  }

  return (
    <span
      className="inline-flex items-center gap-1.5 rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-medium text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
      title={`Last synced ${lastSyncedAt.toISOString()}`}
    >
      <span className="size-1.5 rounded-full bg-emerald-500" />
      Updated {formatRelativeTime(lastSyncedAt, now)}
    </span>
  );
}
