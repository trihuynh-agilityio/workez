# Orders API (Hono)

## Structure
- `src/routes/`: only parse input and call services. No business logic, no DB access.
- `src/services/`: own the business logic.
- Only `src/db/` and services import the DB client `src/db/client.ts`.
- Shared lookups such as `findUserById` live in `src/services/users.ts`.
