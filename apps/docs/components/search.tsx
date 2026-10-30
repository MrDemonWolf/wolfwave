'use client';
import { useState } from 'react';
import {
  SearchDialog,
  SearchDialogClose,
  SearchDialogContent,
  SearchDialogFooter,
  SearchDialogHeader,
  SearchDialogIcon,
  SearchDialogInput,
  SearchDialogList,
  SearchDialogOverlay,
  TagsList,
  TagsListItem,
  type SharedProps,
} from 'fumadocs-ui/components/dialog/search';
import { useDocsSearch } from 'fumadocs-core/search/client';
import { useI18n } from 'fumadocs-ui/contexts/i18n';
import { DOCS_TABS } from '@/lib/docs-nav';
import { basePath } from '@/lib/site';

/**
 * Static (client-side) search dialog backed by the index served from
 * `app/api/search/route.ts`. The footer filters by sidebar tab; no filter
 * searches everything.
 */
export default function DefaultSearchDialog(props: SharedProps) {
  const { locale } = useI18n(); // (optional) for i18n
  const [tag, setTag] = useState<string | undefined>();
  const { search, setSearch, query } = useDocsSearch({
    type: 'static',
    // fumadocs-core 16.16 moved search to ZBSearch. Its default client DB
    // (`{ _: 'string' }` schema, English tokenizer) matches the index that
    // `app/api/search/route.ts` exports, so no custom `initDB` is needed.
    from: `${basePath}/api/search`,
    locale,
    tag,
  });

  return (
    <SearchDialog search={search} onSearchChange={setSearch} isLoading={query.isLoading} {...props}>
      <SearchDialogOverlay />
      <SearchDialogContent>
        <SearchDialogHeader>
          <SearchDialogIcon />
          <SearchDialogInput />
          <SearchDialogClose />
        </SearchDialogHeader>
        <SearchDialogList items={query.data !== 'empty' ? query.data : null} />
        <SearchDialogFooter>
          <TagsList tag={tag} onTagChange={setTag} allowClear>
            {DOCS_TABS.map((tab) => (
              <TagsListItem key={tab.id} value={tab.id}>
                {tab.title}
              </TagsListItem>
            ))}
          </TagsList>
        </SearchDialogFooter>
      </SearchDialogContent>
    </SearchDialog>
  );
}
