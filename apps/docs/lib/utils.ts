/**
 * Prefixes `path` with the deployment base path (empty on the custom domain
 * and in local development). Normalizes leading/trailing
 * slashes so the result is always a single clean absolute path.
 */
export function getAssetPath(path: string): string {
  // Default to the domain root; an explicit path supports other deployments.
  const envValue = process.env.NEXT_PUBLIC_BASE_PATH;
  let basePath: string;
  if (envValue === undefined) {
    basePath = "";
  } else if (envValue === "" || envValue === "/") {
    basePath = "";
  } else {
    let parsed = envValue;
    try { parsed = new URL(envValue).pathname; } catch {}
    basePath = !parsed || parsed === "/" ? "" : (parsed.startsWith("/") ? parsed : `/${parsed}`);
  }
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;
  const normalizedBase = basePath.endsWith("/") ? basePath.slice(0, -1) : basePath;
  return `${normalizedBase}${normalizedPath}`;
}
