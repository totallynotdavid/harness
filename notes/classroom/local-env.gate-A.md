  47-48 breaks that:

  property=${CONFIG_PROPERTY_FOR_VAR[$var]:-}
  [ -n "$property" ] || continue

  A new variable added to INTERPOLATED_VARS (as the comment instructs) but not to CONFIG_PROPERTY_FOR_VAR gets metacharacter-checked and interpolated into config.php, and is
  then silently skipped by the drift check. The only thing keeping the invariant true today is that HTTP_PORT happens to be the one exception, handled separately.

  4. DEPLOY.md's "One-time effect of the config.php anchoring" describes a non-effect

  .cicat/DEPLOY.md:99-111. The six file paths and the fact that they were never transferred are correct — I confirmed all six are tracked and that .github/ matches exactly
  the four vendored directories named at lines 93-94, and that no tracked file matches *.log, error_log, .htaccess, .user.ini, .well-known/ or certificados_sin_firma/.

  But the section is framed as a consequence of the anchoring change, and it is not. By the document's own account no real deploy has ever run — the two blockers in
  "Blockers to clear first" are open, and line 80 says "before you ever run it for real". On the first real deploy every file in the tree transfers for the first time; those
  six are not distinguishable from the rest. Failure it causes: the reader is told to spend the dry-run review hunting six specific harmless paths, on the premise that they
  are newly at risk when nothing about them changed.

  5. PHP version pinned in three places, DEPLOY.md names two

  .devstack/php/Dockerfile:3 carries ARG PHP_VERSION=8.2, duplicating .devstack/.env.example:10. docker-compose.yml:26 always supplies ${PHP_VERSION:?...}, so the default is
  unreachable through any supported entry point — but .cicat/DEPLOY.md:165-167 ("update the two pins above to match") would leave it stale, and a direct podman build
  .devstack/php uses it.

  Verified sound

  mise run check passes end-to-end (OK: All 'status' checks OK, Database structure is ok.). The image build succeeds including docker-php-ext-configure ldap without
  --with-libdir, and covers every extension admin/environment.xml marks required for Moodle 5.0. docker-php-ext-install of the already-built-in mbstring/sodium/opcache emits
  no "already loaded" warning. Container naming (devstack-local-env-1711220984_nginx_1) matches own_nginx_running's regex under podman-compose. The generated config.php is
  valid PHP with every sed substitution landing. check_database_schema.php really does exit 0/1/2 as dev-install.sh assumes, and a connection failure really does print
  Error: Database connection failed and exit(1). The nginx deny list works:

  /                                200
  /config.php                      404
  /.git/config                     404
  /.devstack/.env                  404
  /.devstack/docker-compose.yml    404
  /.cicat/config.php.example       404

  cetext, ceasset and cargogrupo's assertions are real discriminators; only autofitname's is not.

  GATE: FAIL

✻ Cooked for 14m 8s · done 12:43 AM

─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Opus 5  |  ctx 17% used  83% left  |  in:173674 out:2  |  5h:83% 7d:31%                                                                                               /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
