import Link from 'next/link';
import type { ReactNode } from 'react';
import { repoUrl } from '@/lib/site';

/** One list feeds the landing FAQ and FAQPage JSON-LD; text and node must agree. */
export interface FaqItem {
  q: string;
  text: string;
  node: ReactNode;
}

const link = 'ww-text-brand font-semibold';

export const landingFaq: FaqItem[] = [
  {
    q: 'What Mac do I need?',
    text: 'WolfWave requires Apple Silicon (M1 or later), macOS 26 Tahoe or newer, and the Music app on that Mac. Intel Macs are not supported.',
    node: <>WolfWave requires <strong>Apple Silicon (M1 or later)</strong>, <strong>macOS 26 Tahoe or newer</strong>, and the Music app on that Mac. Intel Macs are not supported. See <Link href="/docs/installation" className={link}>installation and setup</Link>.</>,
  },
  {
    q: 'Is WolfWave really free?',
    text: 'Yes. WolfWave is free and open source under GPL-3.0, with no ads, paywall, or premium tier. An Apple Music subscription is separate and is needed for catalog song requests.',
    node: <>Yes. WolfWave is free and open source under GPL-3.0, with no ads, paywall, or premium tier. An Apple Music subscription is separate and is needed for catalog song requests. Browse the <a href={repoUrl} className={link}>source on GitHub</a>.</>,
  },
  {
    q: 'Does the music have to play on this Mac?',
    text: 'Yes. WolfWave reads the Music app on the Mac it runs on, including local tracks. Music playing only on an iPhone, HomePod, or in a web browser will not appear. Song requests search the Apple Music catalog.',
    node: <>Yes. WolfWave reads the Music app on the Mac it runs on, including local tracks. Music playing only on an iPhone, HomePod, or in a web browser will not appear. Song requests search the Apple Music catalog.</>,
  },
  {
    q: 'Can viewers request Spotify or YouTube links?',
    text: 'Yes. Viewers can send !sr with a song name or an Apple Music, Spotify, or YouTube link. WolfWave looks for a matching song on Apple Music; it does not play Spotify or YouTube audio. A match must be available in Apple Music.',
    node: <>Yes. Viewers can send <code className="ww-mono ww-text-1">!sr</code> with a song name or an Apple Music, Spotify, or YouTube link. WolfWave looks for a matching song on Apple Music; it does not play Spotify or YouTube audio. A match must be available in Apple Music. See <Link href="/docs/bot-commands#song-requests" className={link}>request examples</Link>.</>,
  },
  {
    q: 'Can I approve requests before they play?',
    text: 'Yes. Turn on Require My Approval in Settings → Song Requests and requests wait for you to approve or decline them. You can also hold the queue, limit who can request, and block songs, artists, or people.',
    node: <>Yes. Turn on <strong>Require My Approval</strong> in Settings → Song Requests and requests wait for you to approve or decline them. You can also hold the queue, limit who can request, and block songs, artists, or people. See <Link href="/docs/features#song-requests" className={link}>song request controls</Link>.</>,
  },
  {
    q: 'Can OBS run on a second computer?',
    text: 'Yes. WolfWave and Music stay on your Mac. OBS on another computer on the same local network can use the network overlay address from Settings → Stream Widgets. Keep its read-only overlay token private. Stream Deck control stays on the Mac.',
    node: <>Yes. WolfWave and Music stay on your Mac. OBS on another computer on the same local network can use the network overlay address from Settings → Stream Widgets. Keep its read-only overlay token private. Stream Deck control stays on the Mac. Follow the <Link href="/docs/features#now-playing-widget" className={link}>overlay setup guide</Link>.</>,
  },
];

/** Structured data is generated from the exact questions visible on the landing page. */
export function buildFaqJsonLd() {
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: landingFaq.map((item) => ({
      '@type': 'Question',
      name: item.q,
      acceptedAnswer: { '@type': 'Answer', text: item.text },
    })),
  };
}
