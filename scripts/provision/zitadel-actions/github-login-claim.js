/**
 * githubLoginClaim -- assert the remembered GitHub login as the `github_login`
 * claim.
 *
 * Flow: Complement Token (2), triggers 4 (Pre Userinfo Creation) and
 * 5 (Pre Access Token Creation), like groupsFromRoles. The function name is the
 * Action name, so this file holds exactly one function.
 *
 * No metadata means no claim, and a missing claim never fails the token:
 * users who have not signed in through GitHub get exactly the tokens they got
 * before. Task 8 (the room broker) reads this exact claim name.
 *
 * getMetadata() returns { count, metadata: [{ key, value }] }. The value's
 * runtime shape is not documented (string, or bytes), so both are handled, plus
 * the JSON-quoted form appendMetadata writes.
 */
function githubLoginClaim(ctx, api) {
  const md = ctx.v1.user.getMetadata();
  if (!md || !md.metadata) {
    return;
  }
  for (let i = 0; i < md.metadata.length; i++) {
    if (md.metadata[i].key !== 'github_login') {
      continue;
    }
    let value = md.metadata[i].value;
    if (typeof value !== 'string') {
      value = String.fromCharCode.apply(null, Array.from(value || []));
    }
    value = value.replace(/^"(.*)"$/, '$1');
    if (value !== '') {
      api.v1.claims.setClaim('github_login', value);
    }
    return;
  }
}
