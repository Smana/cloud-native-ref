// Day-2 inventory view (Phase 2). Lists apps declared across all stacks and
// offers Edit / Decommission actions per row. Loading, error and empty states.
import { useCallback, useEffect, useState } from "react";
import type { AppSummary, PRResponse } from "../api/types";
import * as api from "../api/client";
import { Alert, AlertDescription, AlertTitle } from "../components/ui/alert";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { errorMessage } from "../lib/utils";

interface Props {
  // Called when a row's "Edit" action is triggered — parent fetches the detail
  // and swaps in the wizard.
  onEdit: (app: AppSummary) => void;
}

type LoadState = "loading" | "loaded" | "error";

export function AppList({ onEdit }: Props) {
  const [apps, setApps] = useState<AppSummary[]>([]);
  const [state, setState] = useState<LoadState>("loading");
  const [error, setError] = useState<string | null>(null);

  // Per-row decommission progress + resulting PR / error.
  const [decommissioning, setDecommissioning] = useState<string | null>(null);
  const [removalPr, setRemovalPr] = useState<PRResponse | null>(null);
  const [decommissionError, setDecommissionError] = useState<string | null>(null);

  const rowKey = (a: AppSummary) => `${a.stack}/${a.name}`;

  const load = useCallback(() => {
    setState("loading");
    setError(null);
    api
      .listApps()
      .then((res) => {
        setApps(res);
        setState("loaded");
      })
      .catch((e) => {
        setError(errorMessage(e));
        setState("error");
      });
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function onDecommission(app: AppSummary) {
    const ok = window.confirm(
      `Decommission "${app.name}" (stack ${app.stack})?\n\n` +
        "This opens a pull request that removes the app's manifest from Git.",
    );
    if (!ok) return;

    setDecommissioning(rowKey(app));
    setDecommissionError(null);
    setRemovalPr(null);
    try {
      const res = await api.openPR({
        stack: app.stack,
        appName: app.name,
        mode: "delete",
        spec: {},
        description: `Decommission ${app.name}`,
      });
      setRemovalPr(res);
    } catch (e) {
      setDecommissionError(errorMessage(e));
    } finally {
      setDecommissioning(null);
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold">My apps</h2>
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={load}
          disabled={state === "loading"}
        >
          {state === "loading" ? "Refreshing…" : "Refresh"}
        </Button>
      </div>

      {removalPr && (
        <Alert variant="success">
          <AlertTitle>Decommission pull request opened</AlertTitle>
          <AlertDescription>
            <a
              className="text-primary underline"
              href={removalPr.url}
              target="_blank"
              rel="noreferrer"
            >
              {removalPr.url}
            </a>{" "}
            (#{removalPr.number}, branch <code>{removalPr.branch}</code>)
          </AlertDescription>
        </Alert>
      )}

      {decommissionError && (
        <Alert variant="destructive">
          <AlertTitle>Could not open decommission PR</AlertTitle>
          <AlertDescription>{decommissionError}</AlertDescription>
        </Alert>
      )}

      {state === "loading" && (
        <p className="text-sm text-muted-foreground">Loading apps…</p>
      )}

      {state === "error" && (
        <Alert variant="destructive">
          <AlertTitle>Could not load apps</AlertTitle>
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      {state === "loaded" && apps.length === 0 && (
        <Card>
          <CardContent className="py-8 text-center text-sm text-muted-foreground">
            No apps yet — create one.
          </CardContent>
        </Card>
      )}

      {state === "loaded" && apps.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>{apps.length} app{apps.length === 1 ? "" : "s"}</CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            <table className="w-full text-sm" data-testid="apps-table">
              <thead>
                <tr className="border-b border-border text-left text-xs text-muted-foreground">
                  <th className="px-4 py-2 font-medium">Name</th>
                  <th className="px-4 py-2 font-medium">Stack</th>
                  <th className="px-4 py-2 font-medium">Namespace</th>
                  <th className="px-4 py-2 font-medium">Type</th>
                  <th className="px-4 py-2 font-medium">Image</th>
                  <th className="px-4 py-2 font-medium text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                {apps.map((app) => (
                  <tr
                    key={rowKey(app)}
                    className="border-b border-border/60 last:border-0"
                    data-testid="app-row"
                  >
                    <td className="px-4 py-2 font-medium">{app.name}</td>
                    <td className="px-4 py-2">{app.stack}</td>
                    <td className="px-4 py-2 text-muted-foreground">{app.namespace}</td>
                    <td className="px-4 py-2">
                      <Badge variant="secondary">{app.type || "web"}</Badge>
                    </td>
                    <td className="px-4 py-2 font-mono text-xs text-muted-foreground">
                      {app.image}
                    </td>
                    <td className="px-4 py-2">
                      <div className="flex items-center justify-end gap-2">
                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          onClick={() => onEdit(app)}
                        >
                          Edit
                        </Button>
                        <Button
                          type="button"
                          variant="destructive"
                          size="sm"
                          disabled={decommissioning === rowKey(app)}
                          onClick={() => onDecommission(app)}
                        >
                          {decommissioning === rowKey(app)
                            ? "Decommissioning…"
                            : "Decommission"}
                        </Button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
