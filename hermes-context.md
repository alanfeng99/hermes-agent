# Hermes agent ops cheat sheet (hearing-action, Zeabur)

The container ships ready to query the live MySQL DB (read-only) and to fetch
Zeabur runtime logs for any project service. Use these patterns when the user
asks about data or service health — credentials are already in env, no setup.

## MySQL — read-only

Internal DNS, self-signed cert, so the client needs `--ssl=0`:

```sh
mysql --ssl=0 -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "<SQL>"
```

env already set: DB_HOST=mysql.zeabur.internal, DB_PORT=3306, DB_NAME=zeabur,
DB_USER=hermes_ro (SELECT only — DDL/DML denied). Useful tables: staff_accounts,
organizations (type IN ("HA","REF")), stores, visits, appointments, redemptions,
qualified_lead_events, cases, consent_grants, audit_logs (monthly-partitioned).

## Zeabur runtime logs (api/web/admin/worker)

Auth via $ZEABUR_TOKEN env (already injected). CLI invoked via npx so no
install needed:

```sh
npx -y zeabur@latest deployment log --service-id <svc-id> -t runtime -i=false
npx -y zeabur@latest deployment log --service-id <svc-id> -t build   -i=false
```

Service IDs in the hearing-action project:
- api    6a14dfef8e146773fe9eb020   (Laravel API)
- web    6a14e2e62f7f6c94448d174c   (partner store + pharmacy SPA, B2/B4)
- admin  6a14e2fb8e146773fe9eb137   (platform admin SPA, B3)
- worker 6a14e5612f7f6c94448d17bf   (queue worker)
- mysql  6a14a0fa2f7f6c94448d0f6e

List + status of all services:
```sh
npx -y zeabur@latest service list --project-id 6a14a0c42f7f6c94448d0f66 -i=false --json
```

## Source code

The repo this cheat sheet lives in IS the alanfeng99/hearing-action source.
It is git-cloned fresh from main on every container start by the cont-init.d
script. PHP under apps/api/, Vue 3 under apps/web/ (partner) and apps/admin/.
