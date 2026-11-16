import { db } from "../db/client";

export async function findUserById(id: string) {
  const rows = await db.query("select * from users where id = ?", [id]);
  return rows[0];
}
