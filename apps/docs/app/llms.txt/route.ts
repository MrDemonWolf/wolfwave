import { llms } from 'fumadocs-core/source/llms';
import { source } from '@/lib/source';
import { absoluteUrl, pageUrl, repoUrl } from '@/lib/site';

export const revalidate = false;

/**
 * Serves the llms.txt index (https://llmstxt.org): a short summary of WolfWave,
 * where each audience should start, and every docs page as an absolute link
 * with its description, grouped by the sidebar sections in `meta.json`.
 * The full text of every page lives at `/llms-full.txt`. Built at export time.
 */
export async function GET() {
  const tree = await llms(source).index();
  const pages = tree
    .split('\n')
    // Drop the generated `# Documentation` heading; this file supplies its own.
    .slice(1)
    .join('\n')
    .trim()
    // Page links are site-relative (`/docs/...`). Make them absolute, with the
    // base path and trailing slash, so the index works wherever it is read.
    .replace(/\]\((\/docs[^)]*)\)/g, (_, path: string) => `](${pageUrl(path)})`);

  const body = `# WolfWave

> WolfWave is a free, open-source macOS menu bar app for streamers who play Apple Music. It posts the current song to Twitch chat through bot commands, takes song requests from chat, channel points, and Bits, shows the song on Discord with Rich Presence, and feeds a now-playing overlay to OBS. An optional Stream Deck plugin controls it. Requires macOS 26 or later on Apple Silicon.

## Where to start

- Streamers: [Installation](${pageUrl('/docs/installation')}) covers the install and the setup wizard. [Features](${pageUrl('/docs/features')}) and [Settings](${pageUrl('/docs/settings')}) cover each feature.
- Viewers in chat: [What can I type in chat?](${pageUrl('/docs/bot-commands')}#what-can-i-type-in-chat) lists every chat command and what it does.
- Developers: [Development](${pageUrl('/docs/development')}), [Architecture](${pageUrl('/docs/architecture')}), the [Stream Deck control API](${pageUrl('/docs/stream-deck')}), and the [OBS widget](${pageUrl('/docs/widget')}). Source code: ${repoUrl}

## Full text

- [llms-full.txt](${absoluteUrl('/llms-full.txt')}): every docs page as one markdown file.

## Docs

${pages}
`;

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
