import { getLLMText, source } from '@/lib/source';

export const revalidate = false;

/**
 * Serves every docs page as one concatenated markdown document (llms-full.txt).
 * `/llms.txt` is the short index that points here. Built at export time.
 */
export async function GET() {
  const scan = source.getPages().map(getLLMText);
  const scanned = await Promise.all(scan);

  return new Response(scanned.join('\n\n'), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
