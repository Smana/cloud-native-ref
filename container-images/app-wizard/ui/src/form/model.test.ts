import { describe, expect, it } from "vitest";
import { fixtureSchema } from "../api/__fixtures__/schema";
import { buildLayout, hintFor } from "./model";

describe("layout tiering (SC-002 + progressive disclosure)", () => {
  const layout = buildLayout(fixtureSchema);

  it("puts every schema property somewhere — none are dropped", () => {
    const placed = new Set<string>([
      ...layout.basic.map((f) => f.key),
      ...layout.groups.flatMap((g) => g.fields.map((f) => f.key)),
      ...layout.ungrouped.map((f) => f.key),
    ]);
    const schemaKeys = Object.keys(
      (fixtureSchema.jsonSchema as { properties: Record<string, unknown> }).properties,
    );
    for (const k of schemaKeys) expect(placed.has(k)).toBe(true);
  });

  it("SC-002: a field present in jsonSchema but ABSENT from hints defaults to advanced tier", () => {
    // futureScalarField exists in the schema fixture, not in hints.fields.
    expect(hintFor("futureScalarField", fixtureSchema.hints).tier).toBe("advanced");
    const inBasic = layout.basic.some((f) => f.key === "futureScalarField");
    const inAdvanced =
      layout.groups.some((g) => g.fields.some((f) => f.key === "futureScalarField")) ||
      layout.ungrouped.some((f) => f.key === "futureScalarField");
    expect(inBasic).toBe(false);
    expect(inAdvanced).toBe(true);
  });
});
