/**
 * FTS5 has its own query grammar, and a natural-language question like
 * `why do we use X?` is a syntax error in it. Since every query OMA sees comes
 * from a human or an agent asking a question, the input is always treated as a
 * bag of terms rather than as FTS syntax.
 */
export function toFtsQuery(input: string): string {
  const terms = input
    .toLowerCase()
    .split(/[^\p{L}\p{N}_*-]+/u)
    .map((t) => t.replace(/^-+|-+$/g, ""))
    .filter((t) => t.length > 0 && !STOP_WORDS.has(t));

  if (terms.length === 0) return "";

  return terms
    .map((t) => (t.endsWith("*") ? `"${t.slice(0, -1)}"*` : `"${t}"`))
    .join(" OR ");
}

/**
 * Kept deliberately short: only words so common that they contribute nothing to
 * ranking. Over-filtering would break queries like "how to build".
 */
const STOP_WORDS = new Set([
  "the",
  "a",
  "an",
  "of",
  "is",
  "are",
  "was",
  "were",
  "do",
  "does",
  "did",
  "to",
  "we",
  "i",
  "it",
  "in",
  "on",
  "for",
  "and",
  "or",
  "de",
  "het",
  "een",
  "van",
  "wij",
  "je",
]);
