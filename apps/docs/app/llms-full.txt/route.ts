import { getLLMText, source } from '@/lib/source';

export const revalidate = false;

/** Serves every docs page as one concatenated markdown document (llms-full.txt). Built at export time. */
export async function GET() {
  const scan = source.getPages().map(getLLMText);
  const scanned = await Promise.all(scan);

  return new Response(scanned.join('\n\n'));
}
