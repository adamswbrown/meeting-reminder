import { redirect } from "next/navigation";

/**
 * Booking is now handled directly by Cal.com. Any visit to /book/<slug>
 * — including old bookmarks — is forwarded to the canonical Cal.com URL.
 * Cal.com reads the Exchange calendar for real-time availability and sends
 * instant confirmation with a Teams link.
 */

interface PageProps {
  params: Promise<{ slug: string }>;
}

export default async function Page({ params }: PageProps) {
  const { slug } = await params;
  redirect(`https://cal.com/adamswbrown/${slug}`);
}
