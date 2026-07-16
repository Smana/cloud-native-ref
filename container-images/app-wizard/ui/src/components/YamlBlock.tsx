import { useState, type ReactNode } from "react";
import { cn } from "../lib/utils";

// Terminal-style YAML viewer with lightweight, zero-dependency syntax
// highlighting. The block is intentionally dark in BOTH light and dark page
// themes — a code block reads as a terminal, and a fixed palette keeps the
// rendered manifests legible regardless of the surrounding surface.
//
// Highlighting is line-based (no full YAML grammar). It is tuned for the
// rendered Kubernetes manifests the wizard shows (keys, scalars, comments,
// list items, document separators) — good enough to read at a glance without
// pulling in a highlighter dependency into the distroless SPA.

// GitHub-dark-ish palette. Green keys / blue values give the classic
// key↔value contrast; numbers and booleans get their own accents.
const COLOR = {
  key: "#7ee787", // keys
  value: "#a5d6ff", // strings / plain scalars
  number: "#f2cc60", // numbers
  keyword: "#ff7b72", // true / false / null
  comment: "#8b949e", // # comments
  punct: "#8b949e", // - : --- ... | >
  plain: "#c9d1d9", // default / whitespace
} as const;

type Tok = { t: string; c: string };

function classifyScalar(v: string): string {
  const t = v.trim();
  if (t === "") return COLOR.plain;
  if (/^-?\d+(\.\d+)?$/.test(t)) return COLOR.number;
  if (/^(true|false|null|~|True|False|Null|yes|no|on|off)$/.test(t)) return COLOR.keyword;
  if (/^[|>][-+0-9]*$/.test(t)) return COLOR.punct; // block scalar indicators
  return COLOR.value; // quoted or plain scalar
}

// Split a "value region" (everything after `key:` or after a `- `) into a
// leading-whitespace token, the scalar, and an optional trailing `# comment`.
function pushValue(tokens: Tok[], text: string): void {
  const lead = /^(\s*)/.exec(text)?.[1] ?? "";
  if (lead) tokens.push({ t: lead, c: COLOR.plain });
  let v = text.slice(lead.length);
  if (v === "") return;
  if (v.startsWith("#")) {
    tokens.push({ t: v, c: COLOR.comment });
    return;
  }
  let comment = "";
  const cIdx = v.search(/\s#/);
  if (cIdx >= 0) {
    comment = v.slice(cIdx);
    v = v.slice(0, cIdx);
  }
  if (v) tokens.push({ t: v, c: classifyScalar(v) });
  if (comment) tokens.push({ t: comment, c: COLOR.comment });
}

function tokenizeLine(line: string): Tok[] {
  const indent = /^(\s*)/.exec(line)?.[1] ?? "";
  const rest = line.slice(indent.length);
  if (rest === "") return [{ t: line, c: COLOR.plain }];
  if (rest.startsWith("#")) return [{ t: line, c: COLOR.comment }];
  if (rest === "---" || rest === "...") return [{ t: line, c: COLOR.punct }];

  const tokens: Tok[] = [{ t: indent, c: COLOR.plain }];

  // Leading list dash(es): "- ", possibly nested ("- - ").
  let body = rest;
  const dash = /^(?:-\s+)+/.exec(body);
  if (body === "-") return [...tokens, { t: "-", c: COLOR.punct }];
  if (dash) {
    tokens.push({ t: dash[0], c: COLOR.punct });
    body = body.slice(dash[0].length);
  }

  // key: value  (non-greedy up to the first colon followed by space or EOL)
  const kv = /^([^:\s#][^:]*?):(\s|$)/.exec(body);
  if (kv) {
    tokens.push({ t: kv[1], c: COLOR.key });
    tokens.push({ t: ":", c: COLOR.punct });
    pushValue(tokens, body.slice(kv[1].length + 1));
  } else {
    pushValue(tokens, body);
  }
  return tokens;
}

function renderLine(line: string, i: number): ReactNode {
  const tokens = tokenizeLine(line);
  return (
    <span key={i}>
      {tokens.map((tok, j) => (
        <span key={j} style={{ color: tok.c }}>
          {tok.t}
        </span>
      ))}
      {"\n"}
    </span>
  );
}

export function YamlBlock({
  yaml,
  maxHeightClass = "max-h-[50vh]",
  copyable = true,
  testId,
}: {
  yaml: string;
  maxHeightClass?: string;
  copyable?: boolean;
  testId?: string;
}) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(yaml);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* clipboard unavailable (non-secure context) — no-op */
    }
  }

  const lines = yaml.replace(/\n$/, "").split("\n");

  return (
    <div className="overflow-hidden rounded-md border border-black/40 bg-[#0d1117] shadow-inner">
      {/* terminal chrome */}
      <div className="flex items-center gap-2 border-b border-white/10 bg-[#161b22] px-3 py-1.5">
        <span className="flex gap-1.5" aria-hidden>
          <span className="h-2.5 w-2.5 rounded-full bg-[#ff5f56]" />
          <span className="h-2.5 w-2.5 rounded-full bg-[#ffbd2e]" />
          <span className="h-2.5 w-2.5 rounded-full bg-[#27c93f]" />
        </span>
        <span className="ml-1 select-none font-mono text-[10px] uppercase tracking-wider text-[#8b949e]">
          yaml
        </span>
        {copyable && (
          <button
            type="button"
            onClick={copy}
            className="ml-auto rounded px-1.5 py-0.5 font-mono text-[10px] text-[#8b949e] transition-colors hover:bg-white/10 hover:text-[#c9d1d9]"
          >
            {copied ? "copied ✓" : "copy"}
          </button>
        )}
      </div>
      <pre
        data-testid={testId}
        className={cn(
          "overflow-auto p-3 font-mono text-xs leading-relaxed text-[#c9d1d9]",
          maxHeightClass,
        )}
      >
        <code>{lines.map(renderLine)}</code>
      </pre>
    </div>
  );
}
