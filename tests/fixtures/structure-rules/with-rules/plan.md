# Task: Add the order detail route
Status: approved.

## Request
Return an order with its user from `GET /orders/:id`.
- R1. The route returns the order and its user.

## Standards
- structure: CLAUDE.md (section Structure)

## T1: add the order detail route  [ ]
- **Lane**: solo
- **Goal**: add `GET /orders/:id`.
- **Files**: `src/routes/orders.ts` (new)
- **Placement**: `src/routes/orders.ts` is in the routes layer (CLAUDE.md (section Structure)).
- **Size**: ~20 lines, 1 file
- **Covers**: R1
- **Depends on**: none
- **Tests**: `src/routes/orders.test.ts`: returns the order and its user.
- **Verify**: `pnpm vitest run src/routes/orders.test.ts`
- **Done when**: the Verify command passes.
- **Slug**: order-detail-route
- **Issue**: pending
- **Branch**: `feat/<sub-issue>-order-detail-route`
- **PR target**: `main`
- **PR title**: `feat: add the order detail route (#<sub-issue>)`
