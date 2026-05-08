export type FileMeta = { name: string; size: number; mime?: string };

export type ShareInfo = {
  share_id: string;
  title?: string;
  files: FileMeta[];
  file_count: number;
  total_bytes: number;
  expires_at: string;
};

export type RequestResponse = { session_id: string; status: string };
export type SessionStatus = {
  session_id: string;
  status: "pending" | "approved" | "rejected" | "closed";
};

const API = ""; // vite proxies /v1 → :8080 in dev; same-origin in prod.

async function handleErr(r: Response): Promise<Response> {
  if (r.ok) return r;
  if (r.status === 404) throw new Error("This link is invalid.");
  if (r.status === 410) throw new Error("This link has expired or been revoked.");
  if (r.status === 403) throw new Error("Access denied.");
  if (r.status === 502) throw new Error("Sender appears to be offline.");
  throw new Error(`Unexpected error (${r.status}).`);
}

export async function getShare(token: string): Promise<ShareInfo> {
  const r = await fetch(`${API}/v1/shares/by-token/${encodeURIComponent(token)}`);
  return (await handleErr(r)).json();
}

export async function requestAccess(token: string): Promise<RequestResponse> {
  const r = await fetch(`${API}/v1/shares/by-token/${encodeURIComponent(token)}/requests`, {
    method: "POST",
  });
  return (await handleErr(r)).json();
}

export async function getSessionStatus(sessionId: string): Promise<SessionStatus> {
  const r = await fetch(`${API}/v1/sessions/${sessionId}/status`);
  return (await handleErr(r)).json();
}

export function downloadURL(sessionId: string, filename: string): string {
  return `${API}/p/${encodeURIComponent(sessionId)}/files/${encodeURIComponent(filename)}`;
}
