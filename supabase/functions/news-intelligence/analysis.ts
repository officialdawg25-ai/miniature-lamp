// Pure helpers for the news-intelligence function. No I/O and no runtime imports so they can be unit-tested with plain Node.

export const PROMPT_VERSION = "news-intel-v1";
export const IMPORTANCE = ["critical_policy_event", "high_priority_development", "relevant_context", "low_impact_background", "unverified_claim", "irrelevant_noise"] as const;

// Documented importance definitions. These are operational labels, not probabilities of a price move.
export const IMPORTANCE_DEFINITIONS: Record<(typeof IMPORTANCE)[number], string> = {
  critical_policy_event: "An official policy decision, or an official statement that changes the stated policy path.",
  high_priority_development: "Official information likely to matter for the policy outlook (projections, minutes with a new emphasis, a senior policymaker's new signal).",
  relevant_context: "Official information that adds context but does not change the stated outlook.",
  low_impact_background: "Routine publications, operational or administrative notices.",
  unverified_claim: "The text reports something that the source itself does not establish.",
  irrelevant_noise: "No bearing on monetary policy, rates, currencies or gold.",
};

const norm = (s: string) => s.toLowerCase().replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/\s+/g, " ").trim();

// An excerpt supports a statement only if it appears verbatim (after whitespace, case and quote normalisation) in the source.
export function excerptFound(source: string, excerpt: string): boolean {
  const e = norm(excerpt);
  return e.length >= 8 && norm(source).includes(e);
}

type WithExcerpt = { excerpt: string };
// Splits model output items into those whose excerpt is in the source and those that are not; the latter are never kept as facts.
export function verifyExcerpts<T extends WithExcerpt>(source: string, items: T[]): { verified: T[]; unverified: T[] } {
  const verified: T[] = [], unverified: T[] = [];
  for (const it of items) (excerptFound(source, it.excerpt) ? verified : unverified).push(it);
  return { verified, unverified };
}

// The article is untrusted data. It is wrapped in a delimiter whose closing tag is stripped from the text itself, so the text
// cannot close the block and continue as instructions.
export function wrapUntrusted(meta: { publisher: string | null; title: string; published_at: string; url: string | null }, body: string | null): string {
  const clean = (s: string) => s.replace(/<\/?source_document[^>]*>/gi, "");
  return [
    "<source_document>",
    `publisher: ${clean(meta.publisher ?? "unknown")}`,
    `published_at: ${meta.published_at}`,
    `url: ${clean(meta.url ?? "")}`,
    `title: ${clean(meta.title)}`,
    `text: ${clean(body ?? "(no text beyond the title)")}`,
    "</source_document>",
  ].join("\n");
}

export function inputBasis(body: string | null): "title_only" | "title_and_feed_summary" {
  return body && body.trim().length > 0 ? "title_and_feed_summary" : "title_only";
}
