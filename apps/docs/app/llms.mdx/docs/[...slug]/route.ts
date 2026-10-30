import { getLLMText, source } from '@/lib/source';
import { notFound } from 'next/navigation';

export const revalidate = false;

/**
 * One docs page as plain markdown, written to a static `.md` file at build
 * time (`/llms.mdx/docs/installation.md`). The "Copy Markdown" button on each
 * page fetches it. The `.md` suffix matters: route handlers export
 * extensionless files, and `design-system` would otherwise collide with the
 * `design-system/` folder its sub-pages live in.
 */
export async function GET(_request: Request, { params }: RouteContext<'/llms.mdx/docs/[...slug]'>) {
  const { slug } = await params;
  const last = slug.at(-1);
  if (!last?.endsWith('.md')) notFound();
  const page = source.getPage([...slug.slice(0, -1), last.slice(0, -'.md'.length)]);
  if (!page) notFound();
  return new Response(await getLLMText(page), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
}

/** Every docs page except the home, which has no page header and no button. */
export function generateStaticParams() {
  return source
    .generateParams()
    .filter((params) => params.slug.length > 0)
    .map(({ slug }) => ({ slug: [...slug.slice(0, -1), `${slug.at(-1)}.md`] }));
}
