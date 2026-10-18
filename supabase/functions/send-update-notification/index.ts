import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { GoogleAuth } from "npm:google-auth-library@9.15.1";

const jsonHeaders = { "Content-Type": "application/json" };

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  const authorization = request.headers.get("Authorization");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!authorization || !supabaseUrl || !supabaseAnonKey) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: jsonHeaders,
    });
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: isAdmin, error: adminError } = await supabase.rpc(
    "is_super_admin",
  );
  if (adminError || isAdmin != true) {
    return new Response(JSON.stringify({ error: "Forbidden" }), {
      status: 403,
      headers: jsonHeaders,
    });
  }

  const payload = await request.json();
  const projectId = Deno.env.get("FCM_PROJECT_ID");
  const clientEmail = Deno.env.get("FCM_CLIENT_EMAIL");
  const privateKey = Deno.env.get("FCM_PRIVATE_KEY")?.replaceAll("\\n", "\n");
  if (!projectId || !clientEmail || !privateKey) {
    return new Response(JSON.stringify({ error: "FCM is not configured" }), {
      status: 500,
      headers: jsonHeaders,
    });
  }

  const auth = new GoogleAuth({
    credentials: {
      client_email: clientEmail,
      private_key: privateKey,
    },
    scopes: ["https://www.googleapis.com/auth/firebase.messaging"],
  });
  const accessToken = await auth.getAccessToken();
  const fcmResponse = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          topic: "all_users",
          notification: { title: payload.title, body: payload.body },
          data: {
            announcement_id: String(payload.announcementId),
            kind: "update",
            version: String(payload.version),
            download_url: String(payload.downloadUrl),
            is_mandatory: String(payload.mandatory == true),
          },
          android: {
            priority: "high",
            notification: { channel_id: "moncommerce_alerts" },
          },
        },
      }),
    },
  );

  if (!fcmResponse.ok) {
    return new Response(await fcmResponse.text(), {
      status: fcmResponse.status,
      headers: jsonHeaders,
    });
  }
  return new Response(JSON.stringify({ sent: true }), { headers: jsonHeaders });
});
