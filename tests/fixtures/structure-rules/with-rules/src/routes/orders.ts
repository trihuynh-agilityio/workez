import { Hono } from "hono";
import { db } from "../db/client";

type Order = { id: string; userId: string };

export const orders = new Hono();

orders.get("/:id", async (c) => {
  const rows = await db.query("select * from orders where id = ?", [c.req.param("id")]);
  const order = rows[0] as Order;
  const users = await db.query("select * from users where id = ?", [order.userId]);
  return c.json({ order, user: users[0] });
});
