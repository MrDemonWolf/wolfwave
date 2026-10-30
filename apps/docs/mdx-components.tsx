import defaultMdxComponents from 'fumadocs-ui/mdx';
import { Tab, Tabs } from 'fumadocs-ui/components/tabs';
import { Step, Steps } from 'fumadocs-ui/components/steps';
import { Accordion, Accordions } from 'fumadocs-ui/components/accordion';
import { Callout } from 'fumadocs-ui/components/callout';
import { Card, Cards } from 'fumadocs-ui/components/card';
import { File, Files, Folder } from 'fumadocs-ui/components/files';
import type { MDXComponents } from 'mdx/types';
import { Mermaid } from '@/components/docs/mermaid';
import { HomeGrid, HomeHeader, LinkGroup } from '@/components/docs/home';

/**
 * Component map for MDX pages: Fumadocs defaults plus the extra components
 * docs content uses (tabs, steps, accordions, callouts, cards, file trees),
 * `Mermaid` (emitted by `rehypeMermaid` for ```mermaid fences), and the docs
 * home building blocks (`components/docs/home.tsx`).
 * Per-call `components` override the defaults.
 */
export function getMDXComponents(components?: MDXComponents): MDXComponents {
  return {
    ...defaultMdxComponents,
    Tab,
    Tabs,
    Step,
    Steps,
    Accordion,
    Accordions,
    Callout,
    Card,
    Cards,
    File,
    Files,
    Folder,
    Mermaid,
    HomeGrid,
    HomeHeader,
    LinkGroup,
    ...components,
  };
}
