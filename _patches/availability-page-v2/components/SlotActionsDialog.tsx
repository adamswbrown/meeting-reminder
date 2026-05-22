"use client";

import { useEffect, useRef, useState } from "react";
import { config } from "@/lib/config";
import {
  buildCopyText,
  buildGoogleCalendarURL,
  buildMailtoURL,
  buildOutlookComposeURL,
  downloadICS,
  type SlotDescriptor,
} from "@/lib/booking";

const OWNER_FIRST_NAME = config.ownerFirstName.split(" ")[0];

interface Props {
  slot: SlotDescriptor | null;
  onClose: () => void;
}

/**
 * Modal dialog that surfaces "real booking" actions for a chosen slot.
 *
 * Built on the native <dialog> element so we get focus trapping, ESC
 * dismissal, and a proper backdrop without pulling in a third-party
 * primitive. We layer click-outside-to-close on top manually since the
 * native element doesn't ship that out of the box.
 */
export function SlotActionsDialog({ slot, onClose }: Props) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const [copied, setCopied] = useState(false);

  // Open/close imperatively so React state drives the dialog lifecycle.
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (slot && !dialog.open) {
      dialog.showModal();
      setCopied(false);
    } else if (!slot && dialog.open) {
      dialog.close();
    }
  }, [slot]);

  // The native dialog fires `close` for ESC and for explicit .close() calls.
  // Mirror that to our React state.
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    const handleClose = () => onClose();
    dialog.addEventListener("close", handleClose);
    return () => dialog.removeEventListener("close", handleClose);
  }, [onClose]);

  // Backdrop click: the <dialog> itself is the click target when the
  // visitor clicks the dark area outside the inner content.
  function handleBackdropClick(e: React.MouseEvent<HTMLDialogElement>) {
    if (e.target === e.currentTarget) onClose();
  }

  async function copySlot() {
    if (!slot) return;
    try {
      await navigator.clipboard.writeText(buildCopyText(slot));
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // no-op — slot text is still readable on screen
    }
  }

  function handleDownload() {
    if (slot) downloadICS(slot);
  }

  const actionClass =
    "flex w-full items-center justify-between gap-3 rounded-lg border border-zinc-200 px-4 py-3 text-sm font-medium text-zinc-900 transition hover:border-zinc-300 hover:bg-zinc-50 focus:outline-none focus:ring-2 focus:ring-zinc-900 dark:border-zinc-800 dark:text-zinc-100 dark:hover:border-zinc-700 dark:hover:bg-zinc-900 dark:focus:ring-zinc-100";

  return (
    <dialog
      ref={dialogRef}
      onClick={handleBackdropClick}
      className="w-full max-w-md rounded-2xl border border-zinc-200 bg-white p-0 text-zinc-900 shadow-xl backdrop:bg-zinc-900/60 backdrop:backdrop-blur-sm dark:border-zinc-800 dark:bg-zinc-950 dark:text-zinc-100"
    >
      {slot && (
        <div className="p-6">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 className="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-500">
                Book this slot
              </h2>
              <p className="mt-1 font-mono text-xl font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">
                {slot.visitorLabel ?? slot.ownerLabel}
                <span className="ml-2 text-xs uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
                  {slot.visitorTZAbbr ?? slot.ownerTZAbbr}
                </span>
              </p>
              <p className="mt-0.5 text-xs text-zinc-500 dark:text-zinc-500">
                {slot.dayLabel}
                {slot.visitorLabel && (
                  <>
                    {" "}&middot; {slot.ownerLabel} {slot.ownerTZAbbr} (Adam&rsquo;s time)
                  </>
                )}
              </p>
            </div>
            <button
              type="button"
              onClick={onClose}
              aria-label="Close"
              className="rounded-md p-1 text-zinc-400 transition hover:bg-zinc-100 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-200"
            >
              <svg
                width="18"
                height="18"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <path d="M18 6 6 18M6 6l12 12" />
              </svg>
            </button>
          </div>

          <div className="mt-6 flex flex-col gap-2">
            <a
              href={buildOutlookComposeURL(slot)}
              target="_blank"
              rel="noopener noreferrer"
              className={actionClass}
            >
              <span className="flex-1 text-left">Open in Outlook</span>
              <span className="text-xs font-normal text-zinc-400 dark:text-zinc-500">
                new tab
              </span>
            </a>
            <a
              href={buildGoogleCalendarURL(slot)}
              target="_blank"
              rel="noopener noreferrer"
              className={actionClass}
            >
              <span className="flex-1 text-left">Open in Google Calendar</span>
              <span className="text-xs font-normal text-zinc-400 dark:text-zinc-500">
                new tab
              </span>
            </a>
            <button type="button" onClick={handleDownload} className={actionClass}>
              <span className="flex-1 text-left">Download .ics</span>
              <span className="text-xs font-normal text-zinc-400 dark:text-zinc-500">
                Apple Calendar / Thunderbird / Outlook desktop
              </span>
            </button>
            <a href={buildMailtoURL(slot)} className={actionClass}>
              <span className="flex-1 text-left">
                Email {OWNER_FIRST_NAME}
              </span>
              <span className="text-xs font-normal text-zinc-400 dark:text-zinc-500">
                opens mail app
              </span>
            </a>
          </div>

          <div className="mt-5 border-t border-zinc-200 pt-4 dark:border-zinc-800">
            <button
              type="button"
              onClick={copySlot}
              className="flex w-full items-center justify-between text-xs text-zinc-500 transition hover:text-zinc-700 dark:text-zinc-400 dark:hover:text-zinc-200"
            >
              <span>Or copy a ready-made reply text</span>
              <span
                className={
                  copied
                    ? "font-medium text-emerald-600 dark:text-emerald-400"
                    : ""
                }
              >
                {copied ? "Copied" : "Copy"}
              </span>
            </button>
          </div>
        </div>
      )}
    </dialog>
  );
}

