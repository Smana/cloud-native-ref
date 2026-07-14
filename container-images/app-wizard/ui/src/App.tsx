// App shell: auth gate (GET /api/me) + schema load, then the schema-driven
// create wizard. When unauthenticated (401), shows the GitHub sign-in button.
import { useEffect, useState } from "react";
import type { AppSummary, SchemaPayload, User } from "./api/types";
import * as api from "./api/client";
import { UnauthorizedError } from "./api/client";
import { Alert, AlertDescription, AlertTitle } from "./components/ui/alert";
import { Button } from "./components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "./components/ui/card";
import { WizardForm, type WizardInitial } from "./form/WizardForm";
import { AppList } from "./form/AppList";

type AuthState = "loading" | "authed" | "anonymous";
type View = "create" | "list";

export function App() {
  const [schema, setSchema] = useState<SchemaPayload | null>(null);
  const [user, setUser] = useState<User | null>(null);
  const [auth, setAuth] = useState<AuthState>("loading");
  const [error, setError] = useState<string | null>(null);

  // Top-level view: create wizard (default) or the day-2 inventory.
  const [view, setView] = useState<View>("create");
  // When set, the wizard renders in edit mode for this loaded app.
  const [editing, setEditing] = useState<WizardInitial | null>(null);
  const [loadingApp, setLoadingApp] = useState(false);

  function openList() {
    setEditing(null);
    setView("list");
  }

  function openCreate() {
    setEditing(null);
    setView("create");
  }

  function onEditApp(app: AppSummary) {
    setError(null);
    setLoadingApp(true);
    api
      .getApp(app.stack, app.name)
      .then((detail) => {
        setEditing({
          mode: "update",
          appName: detail.name,
          stack: detail.stack,
          spec: detail.spec ?? {},
        });
      })
      .catch((e) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => setLoadingApp(false));
  }

  useEffect(() => {
    api
      .getSchema()
      .then(setSchema)
      .catch((e) => setError(e instanceof Error ? e.message : String(e)));

    api
      .getMe()
      .then((u) => {
        setUser(u);
        setAuth("authed");
      })
      .catch((e) => {
        if (e instanceof UnauthorizedError) setAuth("anonymous");
        else setError(e instanceof Error ? e.message : String(e));
      });
  }, []);

  return (
    <div>
      <header className="bg-brand-navy text-brand-navy-fg">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-3">
          <div className="flex items-center gap-3">
            {/* Dark logo variant (light artwork) on the navy brand header */}
            <img
              src="/ogenki-logo-dark.webp"
              alt="Ogenki"
              className="h-9 w-auto shrink-0"
            />
            <div>
              <h1 className="text-lg font-semibold leading-tight">App Wizard</h1>
              <p className="text-xs text-brand-navy-fg/70">
                Declare an application and open a GitOps pull request — no YAML by hand.
              </p>
            </div>
          </div>
          {user && (
            <div className="flex items-center gap-2 text-sm">
              {user.avatarUrl && (
                <img src={user.avatarUrl} alt="" className="h-7 w-7 rounded-full" />
              )}
              <span>{user.name || user.login}</span>
            </div>
          )}
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-4 py-6">

      {error && (
        <Alert variant="destructive" className="mb-4">
          <AlertTitle>Something went wrong</AlertTitle>
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      {auth === "anonymous" && (
        <Card className="mx-auto max-w-md">
          <CardHeader>
            <CardTitle>Sign in to continue</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <p className="text-sm text-muted-foreground">
              The wizard opens the pull request under your own GitHub identity. Sign in to
              continue.
            </p>
            <Button type="button" onClick={() => api.login()}>
              Sign in with GitHub
            </Button>
          </CardContent>
        </Card>
      )}

      {auth === "authed" && schema && user && (
        <div className="space-y-4">
          {/* Segmented control: Create app (default) vs My apps (inventory). */}
          <div className="inline-flex rounded-md border border-border p-0.5">
            <Button
              type="button"
              size="sm"
              variant={view === "create" && !editing ? "default" : "ghost"}
              onClick={openCreate}
            >
              Create app
            </Button>
            <Button
              type="button"
              size="sm"
              variant={view === "list" || editing ? "default" : "ghost"}
              onClick={openList}
            >
              My apps
            </Button>
          </div>

          {loadingApp && (
            <p className="text-sm text-muted-foreground">Loading app…</p>
          )}

          {editing ? (
            <WizardForm
              key={`${editing.stack}/${editing.appName}`}
              schema={schema}
              user={user}
              initial={editing}
              onBack={openList}
            />
          ) : view === "list" ? (
            <AppList onEdit={onEditApp} />
          ) : (
            <WizardForm key="create" schema={schema} user={user} />
          )}
        </div>
      )}

      {auth === "authed" && !schema && !error && (
        <p className="text-sm text-muted-foreground">Loading schema…</p>
      )}
      </main>
    </div>
  );
}
