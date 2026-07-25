/* global cockpit */
"use strict";

const HELPER = "/usr/libexec/nut-cockpit-helper";
const state = {
  summary: null,
  currentConfig: "nut.conf",
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

function setNotice(message, kind = "success") {
  const notice = $("#notice");
  notice.textContent = message;
  notice.className = `notice ${kind}`;
  window.clearTimeout(setNotice.timer);
  setNotice.timer = window.setTimeout(() => {
    notice.classList.add("hidden");
  }, 9000);
}

function errorMessage(error) {
  if (!error) {
    return "Unknown error";
  }
  return error.message || error.error || String(error);
}

function callHelper(operation, payload = {}) {
  return new Promise((resolve, reject) => {
    const process = cockpit.spawn([HELPER, operation], {
      superuser: "require",
      err: "message",
    });
    process.input(JSON.stringify(payload));
    process.then((output) => {
      let response;
      try {
        response = JSON.parse(output || "{}");
      } catch (error) {
        reject(new Error(`The NUT helper returned invalid data.\n${output}`));
        return;
      }
      if (response.ok === false) {
        const detail = response.details ? `\n${response.details}` : "";
        reject(new Error(`${response.error || "Operation failed."}${detail}`));
        return;
      }
      resolve(response);
    }).catch((exception, output) => {
      if (output) {
        try {
          const response = JSON.parse(output);
          const detail = response.details ? `\n${response.details}` : "";
          reject(new Error(`${response.error || exception.message}${detail}`));
          return;
        } catch (parseError) {
          // Fall through to Cockpit's exception message.
        }
      }
      reject(new Error(exception.message || "Administrator access was denied."));
    });
  });
}

async function runWithButton(button, task) {
  const oldText = button.textContent;
  button.disabled = true;
  button.textContent = "Working…";
  try {
    return await task();
  } finally {
    button.disabled = false;
    button.textContent = oldText;
  }
}

function formDataObject(form) {
  const output = {};
  for (const [key, value] of new FormData(form).entries()) {
    output[key] = value;
  }
  return output;
}

function formatBytes(bytes) {
  const number = Number(bytes || 0);
  if (number < 1024) return `${number} B`;
  if (number < 1024 ** 2) return `${(number / 1024).toFixed(1)} KiB`;
  if (number < 1024 ** 3) return `${(number / 1024 ** 2).toFixed(1)} MiB`;
  return `${(number / 1024 ** 3).toFixed(1)} GiB`;
}

function formatResult(result) {
  const lines = [];
  const preferred = [
    ["message", "Message"],
    ["backup", "Backup"],
    ["previous_configuration_backup", "Previous configuration backup"],
    ["target", "Target"],
    ["listen", "Listen address"],
    ["role", "Role"],
    ["generated_password", "Generated password"],
    ["apply_output", "Apply output"],
    ["restart_output", "Restart output"],
    ["output", "Output"],
    ["exit_status", "Exit status"],
  ];

  for (const [key, label] of preferred) {
    if (result[key] !== undefined && result[key] !== "") {
      lines.push(`${label}:\n${result[key]}`);
    }
  }

  if (result.credentials) {
    lines.push("Credentials:");
    for (const [role, credential] of Object.entries(result.credentials)) {
      lines.push(`\n${role}:`);
      lines.push(`  username: ${credential.username}`);
      if (credential.generated) {
        lines.push(`  generated password: ${credential.password}`);
      } else {
        lines.push("  password: supplied by you");
      }
    }
    lines.push("\nSave generated passwords securely.");
  }

  if (!lines.length) {
    return JSON.stringify(result, null, 2);
  }
  return lines.join("\n\n");
}

function showDialog(title, content) {
  $("#dialog-title").textContent = title;
  $("#dialog-output").textContent = content || "No output.";
  const dialog = $("#result-dialog");
  if (typeof dialog.showModal === "function") {
    dialog.showModal();
  } else {
    setNotice(content || title, "success");
  }
}

function badgeClass(value) {
  const normalized = String(value || "").toLowerCase();
  if (["active", "enabled", "online", "ol"].includes(normalized)) return "good";
  if (["inactive", "failed", "disabled", "unknown"].includes(normalized)) return "bad";
  return "";
}

function addDefinition(list, term, value) {
  const dt = document.createElement("dt");
  const dd = document.createElement("dd");
  dt.textContent = term;
  dd.textContent = value || "—";
  list.append(dt, dd);
}

function renderServiceSummary(services) {
  const container = $("#service-summary");
  container.replaceChildren();
  for (const [name, status] of Object.entries(services || {})) {
    const row = document.createElement("div");
    row.className = "status-row";

    const serviceName = document.createElement("span");
    serviceName.className = "status-name";
    serviceName.textContent = name;

    const active = document.createElement("span");
    active.className = `badge ${badgeClass(status.active)}`;
    active.textContent = status.active || "unknown";

    const enabled = document.createElement("span");
    enabled.className = `badge ${badgeClass(status.enabled)}`;
    enabled.textContent = status.enabled || "unknown";

    row.append(serviceName, active, enabled);
    container.append(row);
  }
}

function renderUpsOverview(status) {
  const list = $("#ups-overview");
  list.replaceChildren();
  const fields = [
    ["ups.status", "Status"],
    ["battery.charge", "Battery charge"],
    ["battery.runtime", "Runtime seconds"],
    ["input.voltage", "Input voltage"],
    ["output.voltage", "Output voltage"],
    ["ups.load", "UPS load"],
    ["ups.model", "Model"],
    ["ups.serial", "Serial"],
  ];
  let shown = 0;
  for (const [key, label] of fields) {
    if (status && status[key] !== undefined) {
      let value = status[key];
      if (["battery.charge", "ups.load"].includes(key)) value += "%";
      addDefinition(list, label, value);
      shown += 1;
    }
  }
  if (!shown) {
    addDefinition(list, "Status", "No live UPS data available");
  }
}

async function loadSummary() {
  try {
    const summary = await callHelper("summary");
    state.summary = summary;
    $("#summary-host").textContent = summary.hostname || "Unknown";
    $("#summary-ip").textContent = summary.lan_ip || "";
    $("#summary-mode").textContent = summary.mode || "not configured";
    $("#summary-target").textContent = summary.default_target || "ups@localhost";
    $("#summary-ups-names").textContent = summary.ups_names && summary.ups_names.length
      ? `Configured: ${summary.ups_names.join(", ")}`
      : "No UPS sections found";
    const upsState = summary.ups_status && summary.ups_status["ups.status"];
    $("#summary-ups-state").textContent = upsState || "Unavailable";
    const charge = summary.ups_status && summary.ups_status["battery.charge"];
    $("#summary-charge").textContent = charge ? `Battery: ${charge}%` : "No battery value";
    $("#dashboard-output").textContent = summary.ups_status_text || "No UPS status returned.";
    $("#status-target").value = summary.default_target || "ups@localhost";
    if (summary.lan_ip && $("#listen-ip").value === "") {
      $("#listen-ip").value = summary.lan_ip;
    }
    renderServiceSummary(summary.services);
    renderUpsOverview(summary.ups_status);
  } catch (error) {
    setNotice(errorMessage(error), "error");
    $("#dashboard-output").textContent = errorMessage(error);
  }
}

function switchSection(name) {
  $$(".tab").forEach((tab) => tab.classList.toggle("active", tab.dataset.section === name));
  $$(".page-section").forEach((section) => {
    section.classList.toggle("active", section.id === `section-${name}`);
  });
  if (name === "editor") loadConfig();
  if (name === "backups") loadBackups();
}

function updateServerMode() {
  const networkMode = $("#server-mode").value === "netserver";
  $("#listen-ip-field").classList.toggle("hidden", !networkMode);
  $("#client-credential-fields").classList.toggle("hidden", !networkMode);
  $("#listen-ip").required = networkMode;
  $("#server-form [name=client_user]").required = networkMode;
}

async function submitServer(event) {
  event.preventDefault();
  if (!window.confirm("Replace the active core NUT server configuration after creating a backup?")) return;
  const button = event.submitter;
  await runWithButton(button, async () => {
    try {
      const result = await callHelper("server-setup", formDataObject(event.currentTarget));
      showDialog("Server configuration saved", formatResult(result));
      setNotice("NUT server configuration saved.", "success");
      await loadSummary();
      await loadBackups();
    } catch (error) {
      setNotice(errorMessage(error), "error");
    }
  });
}

async function submitClient(event) {
  event.preventDefault();
  const payload = formDataObject(event.currentTarget);
  if (payload.role === "primary" && !window.confirm("Primary role can coordinate UPS shutdown. Continue?")) return;
  if (!window.confirm("Replace this host's NUT client configuration after creating a backup?")) return;
  const button = event.submitter;
  await runWithButton(button, async () => {
    try {
      const result = await callHelper("client-setup", payload);
      showDialog("Client configuration saved", formatResult(result));
      setNotice("NUT client configuration saved.", "success");
      await loadSummary();
      await loadBackups();
    } catch (error) {
      setNotice(errorMessage(error), "error");
    }
  });
}

async function loadConfig() {
  const button = $("#load-config-button");
  state.currentConfig = $("#config-file-select").value;
  await runWithButton(button, async () => {
    try {
      const result = await callHelper("config-get", { name: state.currentConfig });
      $("#config-editor").value = result.content || "";
      setNotice(`Loaded ${result.path}.`, "success");
    } catch (error) {
      setNotice(errorMessage(error), "error");
    }
  });
}

async function saveConfig() {
  if (!window.confirm(`Save ${state.currentConfig} and create a backup?`)) return;
  const button = $("#save-config-button");
  await runWithButton(button, async () => {
    try {
      const result = await callHelper("config-save", {
        name: state.currentConfig,
        content: $("#config-editor").value,
        apply: $("#apply-after-save").checked,
      });
      showDialog("Configuration saved", formatResult(result));
      setNotice(`${state.currentConfig} saved.`, "success");
      await loadSummary();
      await loadBackups();
    } catch (error) {
      setNotice(errorMessage(error), "error");
    }
  });
}

async function submitUser(event) {
  event.preventDefault();
  const payload = formDataObject(event.currentTarget);
  if (payload.profile === "admin" && !window.confirm("Grant SET, FSD, and all instant commands to this user?")) return;
  const button = event.submitter;
  await runWithButton(button, async () => {
    try {
      const result = await callHelper("user-upsert", payload);
      showDialog("NUT user updated", formatResult(result));
      setNotice("NUT user updated.", "success");
      await loadBackups();
    } catch (error) {
      setNotice(errorMessage(error), "error");
    }
  });
}

async function submitService(event) {
  event.preventDefault();
  const payload = formDataObject(event.currentTarget);
  if (["stop", "disable"].includes(payload.action) && !window.confirm(`Run ${payload.action} on ${payload.scope} NUT services?`)) return;
  const button = event.submitter;
  await runWithButton(button, async () => {
    try {
      const result = await callHelper("service", payload);
      $("#service-output").textContent = result.output || "No output.";
      setNotice(`Service action completed with exit status ${result.exit_status}.`, result.exit_status === 0 ? "success" : "error");
      await loadSummary();
    } catch (error) {
      $("#service-output").textContent = errorMessage(error);
      setNotice(errorMessage(error), "error");
    }
  });
}

async function submitDriver(event) {
  event.preventDefault();
  const payload = formDataObject(event.currentTarget);
  const button = event.submitter;
  await runWithButton(button, async () => {
    try {
      const result = await callHelper("driver", payload);
      $("#service-output").textContent = result.output || "No output.";
      setNotice(`Driver action completed with exit status ${result.exit_status}.`, result.exit_status === 0 ? "success" : "error");
      await loadSummary();
    } catch (error) {
      $("#service-output").textContent = errorMessage(error);
      setNotice(errorMessage(error), "error");
    }
  });
}

async function runTool(operation, payload, button) {
  await runWithButton(button, async () => {
    try {
      const result = await callHelper(operation, payload);
      $("#tool-output").textContent = result.output || formatResult(result);
      setNotice("Tool completed.", result.exit_status && result.exit_status !== 0 ? "error" : "success");
    } catch (error) {
      $("#tool-output").textContent = errorMessage(error);
      setNotice(errorMessage(error), "error");
    }
  });
}

async function loadBackups() {
  const container = $("#backup-list");
  container.textContent = "Loading backups…";
  try {
    const result = await callHelper("backups-list");
    container.replaceChildren();
    if (!result.backups || !result.backups.length) {
      container.textContent = "No backups exist yet.";
      return;
    }
    for (const backup of result.backups) {
      const row = document.createElement("div");
      row.className = "backup-row";

      const description = document.createElement("div");
      const name = document.createElement("div");
      const meta = document.createElement("div");
      name.className = "backup-name";
      meta.className = "backup-meta";
      name.textContent = backup.name;
      const modified = new Date(backup.modified);
      meta.textContent = `${backup.files} files · ${formatBytes(backup.size)} · ${modified.toLocaleString()}`;
      description.append(name, meta);

      const label = document.createElement("span");
      label.className = "badge";
      label.textContent = "Configuration";

      const restore = document.createElement("button");
      restore.className = "button danger";
      restore.type = "button";
      restore.textContent = "Restore";
      restore.addEventListener("click", () => restoreBackup(backup.name, restore));

      row.append(description, label, restore);
      container.append(row);
    }
  } catch (error) {
    container.textContent = errorMessage(error);
    setNotice(errorMessage(error), "error");
  }
}

async function restoreBackup(name, button) {
  if (!window.confirm(`Restore backup ${name}? The current configuration will be backed up first.`)) return;
  await runWithButton(button, async () => {
    try {
      const result = await callHelper("backup-restore", { name });
      showDialog("Backup restored", formatResult(result));
      setNotice(`Backup ${name} restored.`, "success");
      await loadSummary();
      await loadBackups();
      if ($("#section-editor").classList.contains("active")) await loadConfig();
    } catch (error) {
      setNotice(errorMessage(error), "error");
    }
  });
}

function bindEvents() {
  $$(".tab").forEach((tab) => tab.addEventListener("click", () => switchSection(tab.dataset.section)));
  $("#refresh-button").addEventListener("click", (event) => runWithButton(event.currentTarget, loadSummary));
  $("#apply-button").addEventListener("click", async (event) => {
    if (!window.confirm("Apply the current NUT configuration and restart applicable services?")) return;
    await runWithButton(event.currentTarget, async () => {
      try {
        const result = await callHelper("apply");
        showDialog("Configuration applied", formatResult(result));
        setNotice("NUT configuration applied.", "success");
        await loadSummary();
      } catch (error) {
        setNotice(errorMessage(error), "error");
      }
    });
  });

  $("#server-mode").addEventListener("change", updateServerMode);
  $("#server-form").addEventListener("submit", submitServer);
  $("#client-form").addEventListener("submit", submitClient);
  $("#config-file-select").addEventListener("change", loadConfig);
  $("#load-config-button").addEventListener("click", loadConfig);
  $("#save-config-button").addEventListener("click", saveConfig);
  $("#user-form").addEventListener("submit", submitUser);
  $("#service-form").addEventListener("submit", submitService);
  $("#driver-form").addEventListener("submit", submitDriver);

  $("#status-form").addEventListener("submit", (event) => {
    event.preventDefault();
    runTool("ups-status", formDataObject(event.currentTarget), event.submitter);
  });
  $("#list-form").addEventListener("submit", (event) => {
    event.preventDefault();
    runTool("list-ups", formDataObject(event.currentTarget), event.submitter);
  });
  $("#logs-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const payload = formDataObject(event.currentTarget);
    payload.lines = Number(payload.lines);
    runTool("logs", payload, event.submitter);
  });
  $("#usb-scan-button").addEventListener("click", (event) => runTool("usb-scan", {}, event.currentTarget));
  $("#diagnostics-button").addEventListener("click", (event) => runTool("diagnostics", {}, event.currentTarget));

  $("#create-backup-button").addEventListener("click", async (event) => {
    await runWithButton(event.currentTarget, async () => {
      try {
        const result = await callHelper("backup-create");
        setNotice(result.message, "success");
        await loadBackups();
      } catch (error) {
        setNotice(errorMessage(error), "error");
      }
    });
  });
  $("#refresh-backups-button").addEventListener("click", (event) => runWithButton(event.currentTarget, loadBackups));
}

function initialize() {
  bindEvents();
  updateServerMode();
  loadSummary();
}

document.addEventListener("DOMContentLoaded", initialize);
