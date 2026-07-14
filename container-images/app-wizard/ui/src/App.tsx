// Phase 1 scaffold shell. The form renderer task replaces this with the
// schema-driven wizard (basic/advanced tiers, live YAML pane, CEL validation).
import { useEffect, useState } from "react";
import type { SchemaPayload } from "./api/types";

export function App() {
  const [schema, setSchema] = useState<SchemaPayload | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/schema")
      .then((r) => r.json())
      .then(setSchema)
      .catch((e) => setError(String(e)));
  }, []);

  return (
    <main style={{ fontFamily: "system-ui", padding: "2rem" }}>
      <h1>App Wizard</h1>
      {error && <p style={{ color: "crimson" }}>Failed to load schema: {error}</p>}
      {schema && (
        <p>
          Schema loaded (version <code>{schema.schemaVersion}</code>,{" "}
          {schema.stacks.length} stacks). Form renderer not yet implemented.
        </p>
      )}
    </main>
  );
}
