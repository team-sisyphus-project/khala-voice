/**
 * ESM resolve hook (registered via `node:module`.register) that teaches the node
 * test runner the web app's `@/` path aliases. `tsc` and vite resolve these via
 * tsconfig `paths`/vite alias; the bare node runtime does not. The hook supplies
 * the same mapping so a `.ts` module using `@/…` imports (e.g. the real
 * `useAccount`) loads unchanged: real `@/i18n`, mock `@/lib/*`.
 */
interface ResolveContext {
  conditions: string[];
  importAttributes: Record<string, string>;
  parentURL?: string;
}

type NextResolve = (
  specifier: string,
  context: ResolveContext,
) => Promise<{ url: string; shortCircuit?: boolean }>;

let base = "";

export async function initialize(data: { base: string }): Promise<void> {
  base = data.base;
}

export async function resolve(
  specifier: string,
  context: ResolveContext,
  next: NextResolve,
): Promise<{ url: string; shortCircuit?: boolean }> {
  const map: Record<string, string> = {
    "@/i18n": base + "src/i18n/index.ts",
    "@/lib/api": base + "src/hooks/__testsupport/apiMock.ts",
    "@/lib/theme": base + "src/hooks/__testsupport/themeMock.ts",
  };
  const mapped = map[specifier];
  if (mapped) return { url: mapped, shortCircuit: true };
  return next(specifier, context);
}
