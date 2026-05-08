import { downloadURL, getSessionStatus, getShare, requestAccess, ShareInfo, SessionStatus } from "./api";
import { clear, h, humanSize, parseShareToken } from "./util";

const app = document.getElementById("app")!;

function renderLanding(): void {
  clear(app);
  app.append(
    h("h1", {}, "Porta"),
    h("h2", {}, "Temporary, live links from a phone."),
    h(
      "div",
      { class: "card" },
      h("p", {}, "Open a share link on your phone or paste one below to continue."),
    ),
  );
}

function renderError(msg: string): void {
  clear(app);
  app.append(
    h("h1", {}, "Porta"),
    h("div", { class: "card" }, h("p", { class: "error" }, msg)),
  );
}

function renderShare(token: string, info: ShareInfo): void {
  clear(app);

  const filesCard = h(
    "div",
    { class: "card" },
    ...info.files.map((f) =>
      h(
        "div",
        { class: "file-row" },
        h("span", { class: "name" }, f.name),
        h("span", { class: "size" }, humanSize(f.size)),
      ),
    ),
    h(
      "div",
      { class: "meta" },
      h("span", {}, `${info.file_count} file${info.file_count === 1 ? "" : "s"}`),
      h("span", {}, humanSize(info.total_bytes)),
    ),
  );

  const button = h("button", { class: "btn" }, "Request files") as HTMLButtonElement;
  button.addEventListener("click", async () => {
    button.disabled = true;
    button.textContent = "Waiting for approval…";
    try {
      const { session_id } = await requestAccess(token);
      await waitForApproval(token, session_id, info);
    } catch (e) {
      renderError((e as Error).message);
    }
  });

  app.append(
    h("h1", {}, info.title || "Someone shared files with you"),
    h("h2", {}, "Tap below to request access. The sender will approve on their phone."),
    filesCard,
    h("div", { class: "card" }, button),
  );
}

async function waitForApproval(
  token: string,
  sessionId: string,
  info: ShareInfo,
): Promise<void> {
  clear(app);
  const status = h("div", { class: "status" }, h("span", { class: "dot" }), h("span", {}, "Waiting for sender…"));
  app.append(h("h1", {}, "Approve on your phone"), h("div", { class: "card" }, status));

  const deadline = Date.now() + 5 * 60 * 1000;
  while (Date.now() < deadline) {
    const s: SessionStatus = await getSessionStatus(sessionId);
    if (s.status === "approved") {
      renderDownload(sessionId, info);
      return;
    }
    if (s.status === "rejected") {
      renderError("The sender declined the request.");
      return;
    }
    if (s.status === "closed") {
      renderError("The session was closed.");
      return;
    }
    await sleep(1500);
  }
  void token;
  renderError("Timed out waiting for approval.");
}

function renderDownload(sessionId: string, info: ShareInfo): void {
  clear(app);
  const list = h(
    "div",
    { class: "card" },
    ...info.files.map((f) => {
      const row = h("div", { class: "file-row" });
      const link = h("a", { href: downloadURL(sessionId, f.name), class: "name" }, f.name);
      link.setAttribute("download", f.name);
      row.append(link, h("span", { class: "size" }, humanSize(f.size)));
      return row;
    }),
  );

  app.append(
    h("h1", {}, "Approved"),
    h("h2", {}, "Tap a file to download. Bytes stream from the sender's phone."),
    list,
    h(
      "div",
      { class: "card small" },
      "The link is live only while the sender keeps Porta open on their phone.",
    ),
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function boot(): Promise<void> {
  const token = parseShareToken();
  if (!token) {
    renderLanding();
    return;
  }
  try {
    const info = await getShare(token);
    renderShare(token, info);
  } catch (e) {
    renderError((e as Error).message);
  }
}

boot();
