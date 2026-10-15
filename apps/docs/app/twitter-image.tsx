// Twitter card reuses the Open Graph image; segment config must be re-declared
// here because Next does not read it through a re-export.
export const dynamic = "force-static";
export const revalidate = false;
export { default, alt, size, contentType } from "./opengraph-image";
