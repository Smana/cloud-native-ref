/**
 * groups-from-roles — flatten ZITADEL's project roles into a `groups` claim.
 *
 * WHY THIS EXISTS
 *
 * ZITADEL has no groups. It has project roles, and it puts them in the token as
 * a NESTED object keyed by role, then by org:
 *
 *   "urn:zitadel:iam:org:project:roles": {
 *     "platform-admin": { "273...": "ogenki.io" }
 *   }
 *
 * Every consumer on this platform wants a FLAT array of strings instead:
 *
 *   Grafana   role_attribute_path / groups mapping   (auth.generic_oauth)
 *   Headlamp  OIDC groups claim
 *   Flux UI   OIDC groups claim
 *
 * Nothing in ZITADEL emits that shape, so this Action builds it. It is the
 * documented approach rather than a workaround: native user groups are still
 * unfinished upstream (zitadel/zitadel#12308 "complete user groups support" was
 * open on 2026-08-21), and this instance runs v4.15.3, whose API has no groups
 * endpoint at all -- /v2/groups/search, /v2beta/groups/search and
 * /management/v1/groups/_search all 404.
 *
 * When native groups do land, this Action is what gets deleted.
 *
 * WHY v1 ACTIONS (inline JS) AND NOT v2
 *
 * Actions v2 replaces inline JS with an external HTTP "target": ZITADEL calls a
 * service you host. Both APIs answer on this instance, but v2 would mean
 * deploying, exposing and securing a webhook service to do fifteen lines of
 * string manipulation, plus a network path from ZITADEL to it. v1 is deprecated
 * and it is still the right trade here. If it is removed upstream, the
 * replacement is a target service -- not a rewrite of this logic.
 *
 * FLOW / TRIGGER
 *
 * Registered on flow 2 (CustomiseToken) against both triggers, because the two
 * are not interchangeable and consumers differ in which they read:
 *
 *   trigger 4  PreUserinfoCreation      -> the /userinfo response
 *   trigger 5  PreAccessTokenCreation   -> claims inside the access token
 *
 * Grafana reads userinfo; a consumer validating the JWT directly reads the
 * token. Registering only one leaves the other silently groupless.
 *
 * A NOTE ON FAILURE MODE
 *
 * This returns early rather than throwing when a user has no grants. An Action
 * that errors fails the token request, so a user with no roles would be unable
 * to log in at all -- which is a much worse outcome than logging in with no
 * groups.
 */
function groupsFromRoles(ctx, api) {
  const grants = ctx.v1.user.grants;

  // No grants at all: emit nothing and let the login proceed. Deliberately not
  // an empty array -- an absent claim and an empty one mean different things to
  // some consumers, and "this user has no roles" is better said by absence.
  if (grants === undefined || grants === null || grants.count === 0) {
    return;
  }

  const groups = [];
  grants.grants.forEach((grant) => {
    if (grant.roles === undefined || grant.roles === null) {
      return;
    }
    grant.roles.forEach((role) => {
      // De-duplicate: the same role can arrive from more than one grant when a
      // user holds it in several orgs, and a repeated entry breaks consumers
      // that treat the claim as a set.
      if (groups.indexOf(role) === -1) {
        groups.push(role);
      }
    });
  });

  if (groups.length === 0) {
    return;
  }

  api.v1.claims.setClaim('groups', groups);
}
