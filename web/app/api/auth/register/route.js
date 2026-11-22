import { z } from "zod";
import { query } from "../../../../lib/db.mjs";
import { hashPassword } from "../../../../lib/passwords.mjs";
import { issueSession } from "../../../../lib/auth.mjs";
import { body, json, fail } from "../../../../lib/http.mjs";

export async function POST(request) {
  try {
    const b = z
      .object({
        full_name: z
          .string()
          .trim()
          .min(2, "Name must be at least 2 characters")
          .max(100),
        email: z.email().max(160),
        password: z
          .string()
          .min(8, "Password must be at least 8 characters")
          .max(128),
        role: z.enum(["ADMIN", "STAFF"]).default("ADMIN"),
      })
      .parse(await body(request));

    const email = b.email.toLowerCase();

    const existing = await query(
      "AUTH",
      "SELECT user_id FROM smartvault.app_users WHERE lower(email)=$1",
      [email],
    );
    if (existing.rows.length > 0) {
      return json({ error: "An account with this email already exists." }, 409);
    }

    const hashedPassword = await hashPassword(b.password);
    const result = await query(
      "AUTH",
      "SELECT smartvault.create_app_user($1, $2, $3, $4) AS id",
      [b.full_name, email, b.role, hashedPassword],
    );

    const newUserId = result.rows[0].id;
    const user = {
      user_id: newUserId,
      full_name: b.full_name,
      email: email,
      role: b.role,
    };

    await issueSession(user);
    return json({ ok: true, user });
  } catch (e) {
    return fail(e);
  }
}
