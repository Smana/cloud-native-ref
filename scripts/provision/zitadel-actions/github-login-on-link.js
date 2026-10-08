/**
 * githubLoginOnLink -- remember the GitHub login a user signs in with.
 *
 * Flow: External Authentication (1), trigger: Post Authentication (1).
 * The function name is the Action name (see groups-from-roles.js), so this
 * file holds exactly one function.
 *
 * The room broker matches the github_login claim against GitHub repo
 * permissions (spec D7). The claim is asserted by githubLoginClaim from the
 * user metadata this writes.
 *
 * WHERE THE LOGIN COMES FROM. ctx.v1.externalUser documents only externalId
 * (GitHub's NUMERIC id) and human.* -- no preferredUsername. The provider's own
 * response is ctx.v1.providerInfo, and GitHub's /user payload carries `login`.
 * Deliberately no fallback to a username-ish field: on a Google login that would
 * be an e-mail address, stored as a "GitHub login" and then matched against
 * repo permissions. No providerInfo.login means no write.
 *
 * Not checked live (the platform was torn down when this was written): the
 * first GitHub login after a bootstrap must be confirmed with
 * `GET /management/v1/users/{id}/metadata/github_login`.
 *
 * appendMetadataRaw stores the plain UTF-8 bytes; appendMetadata would store
 * the JSON-quoted string.
 */
function githubLoginOnLink(ctx, api) {
  const info = ctx.v1.providerInfo;
  const login = info && (info.login || (info.rawInfo && info.rawInfo.login));
  // GitHub logins are [A-Za-z0-9-]; anything else is not one.
  if (typeof login !== 'string' || !/^[A-Za-z0-9-]+$/.test(login)) {
    return;
  }
  api.v1.user.appendMetadataRaw('github_login', login);
}
