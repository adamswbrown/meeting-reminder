import { config } from "./config";

/**
 * Everything the booking actions need to know about a single slot.
 * Constructed in `SlotCard` (which already knows the visitor's timezone)
 * and passed up to the dialog via the click handler.
 */
export interface SlotDescriptor {
  startISO: string;
  endISO: string;
  /** Pre-formatted heading like "Today" / "Mon 26 May". */
  dayLabel: string;
  /** Owner-tz time range, e.g. "14:30–15:30". */
  ownerLabel: string;
  /** Owner-tz abbreviation, e.g. "BST". */
  ownerTZAbbr: string;
  /** Visitor-tz time range. Present only when visitor ≠ London. */
  visitorLabel?: string;
  /** Visitor-tz abbreviation. Present only when visitor ≠ London. */
  visitorTZAbbr?: string;
}

const MEETING_TITLE = `Meeting with ${config.ownerFirstName}`;

function meetingDescription(d: SlotDescriptor): string {
  const lines = [`Proposed slot: ${d.dayLabel} ${d.ownerLabel} ${d.ownerTZAbbr}`];
  if (d.visitorLabel) {
    lines.push(`(${d.visitorLabel} ${d.visitorTZAbbr} in your timezone)`);
  }
  lines.push("");
  lines.push("Requested via Adam's availability page.");
  return lines.join("\n");
}

/**
 * Outlook Web compose URL. Opens a new meeting compose dialog in Outlook
 * with start/end pre-set and Adam pre-added as an attendee. The visitor
 * reviews and clicks Send — Adam gets a real Outlook invite. Works for
 * any Microsoft 365 work account.
 */
export function buildOutlookComposeURL(d: SlotDescriptor): string {
  const params = new URLSearchParams({
    path: "/calendar/action/compose",
    rru: "addevent",
    subject: MEETING_TITLE,
    startdt: d.startISO,
    enddt: d.endISO,
    to: config.ownerEmail,
    body: meetingDescription(d),
  });
  return `https://outlook.office.com/calendar/0/deeplink/compose?${params.toString()}`;
}

/**
 * Google Calendar compose URL. Opens an event-creation form with the slot
 * pre-filled and Adam as a guest.
 */
export function buildGoogleCalendarURL(d: SlotDescriptor): string {
  // Google's `dates` param wants YYYYMMDDTHHMMSSZ (no dashes/colons, UTC).
  const toGoogleDate = (iso: string) =>
    iso.replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");

  const params = new URLSearchParams({
    action: "TEMPLATE",
    text: MEETING_TITLE,
    dates: `${toGoogleDate(d.startISO)}/${toGoogleDate(d.endISO)}`,
    add: config.ownerEmail,
    details: meetingDescription(d),
  });
  return `https://calendar.google.com/calendar/render?${params.toString()}`;
}

/**
 * mailto URL with a pre-filled subject and body that proposes the slot
 * in the visitor's voice. Fallback for visitors who'd rather just send
 * an email than open a calendar.
 */
export function buildMailtoURL(d: SlotDescriptor): string {
  const subject = `Meeting request — ${d.dayLabel} ${d.ownerLabel} ${d.ownerTZAbbr}`;
  const firstName = config.ownerFirstName.split(" ")[0];
  const slotLine = d.visitorLabel
    ? `${d.dayLabel} ${d.ownerLabel} ${d.ownerTZAbbr} (${d.visitorLabel} ${d.visitorTZAbbr} my time)`
    : `${d.dayLabel} ${d.ownerLabel} ${d.ownerTZAbbr}`;
  const body = [
    `Hi ${firstName},`,
    "",
    "I'd like to book in for this slot:",
    "",
    slotLine,
    "",
    "Thanks,",
  ].join("\n");
  return `mailto:${config.ownerEmail}?subject=${encodeURIComponent(
    subject
  )}&body=${encodeURIComponent(body)}`;
}

/**
 * Generate ICS file content for the slot. The visitor downloads this and
 * opens it in their native calendar app (Apple Calendar / Outlook desktop
 * / Thunderbird etc.), which then offers to send the invite to Adam.
 *
 * Escapes per RFC 5545: backslash, comma, semicolon, and newline.
 */
export function buildICSContent(d: SlotDescriptor): string {
  const toICSDate = (iso: string) =>
    iso.replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");

  const nowICS = toICSDate(new Date().toISOString());
  const startICS = toICSDate(d.startISO);
  const endICS = toICSDate(d.endISO);
  // Stable UID per slot — if the visitor downloads the same slot twice,
  // their calendar app updates the existing event rather than duplicating.
  const uid = `slot-${startICS}-${endICS}@adam-availability`;

  const esc = (text: string) =>
    text
      .replace(/\\/g, "\\\\")
      .replace(/,/g, "\\,")
      .replace(/;/g, "\\;")
      .replace(/\r?\n/g, "\\n");

  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Adam Brown Availability//EN",
    "METHOD:PUBLISH",
    "BEGIN:VEVENT",
    `UID:${uid}`,
    `DTSTAMP:${nowICS}`,
    `DTSTART:${startICS}`,
    `DTEND:${endICS}`,
    `SUMMARY:${esc(MEETING_TITLE)}`,
    `DESCRIPTION:${esc(meetingDescription(d))}`,
    `ORGANIZER;CN=${esc(config.ownerFirstName)}:MAILTO:${config.ownerEmail}`,
    "STATUS:TENTATIVE",
    "END:VEVENT",
    "END:VCALENDAR",
  ];
  // RFC 5545 mandates CRLF line endings.
  return lines.join("\r\n");
}

/**
 * Browser-only: trigger a download of the slot as an .ics file.
 */
export function downloadICS(d: SlotDescriptor): void {
  const content = buildICSContent(d);
  const blob = new Blob([content], { type: "text/calendar;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  const filenameOwner = config.ownerFirstName.toLowerCase().replace(/\s+/g, "-");
  link.href = url;
  link.download = `meeting-with-${filenameOwner}-${d.startISO.slice(0, 10)}.ics`;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}

/**
 * Visitor-proposing text for copy-to-clipboard. The fallback when none of
 * the structured booking actions fit the visitor's workflow.
 */
export function buildCopyText(d: SlotDescriptor): string {
  return d.visitorLabel
    ? `${d.dayLabel} ${d.ownerLabel} ${d.ownerTZAbbr} (${d.visitorLabel} ${d.visitorTZAbbr} my time) works for me.`
    : `${d.dayLabel} ${d.ownerLabel} ${d.ownerTZAbbr} works for me.`;
}
