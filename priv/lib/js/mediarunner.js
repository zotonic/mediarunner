/* Queue data stays visible during failures; job text uses textContent; chart markup comes from the server SVG scomp. */
(() => {
    "use strict";
    const root = document.getElementById("mediarunner");
    if (!root) return;
    const el = id => document.getElementById(`mr-${id}`);
    const labels = Object.fromEntries([...el("labels").children].map(n => [n.dataset.key, n.textContent]));
    const text = (id, value) => { el(id).textContent = value; };
    const label = key => labels[key] || key;
    const node = (tag, value) => { const n = document.createElement(tag); n.textContent = value; return n; };
    const count = (items, field, key) => Number(items.find(x => x[field] === key)?.count || 0);
    const date = value => new Date(value * 1000).toLocaleString([], {month: "short", day: "numeric", hour: "2-digit", minute: "2-digit"});
    const badge = state => { const n = node("span", label(state)); n.className = "mr-badge"; n.dataset.state = state; return n; };
    let busy = false;
    let lastUpdated = null;
    let stale = false;
    const filter = el("filter");
    const fromUrl = () => {
        const value = new URL(location.href).searchParams.get("status") || "";
        filter.value = [...filter.options].some(o => o.value === value) ? value : "";
    };
    fromUrl();
    const renderChart = data => {
        const hour = Math.floor(data.updated / 3600) * 3600;
        const hours = Array.from({length: 25}, (_, i) => {
            const timestamp = hour - (24-i)*3600;
            return {hour: timestamp, completed: 0, failed: 0, ...data.hourly.find(h => Number(h.hour) === timestamp)};
        });
        // These fragments come only from the authorized model's SVG chart scomp.
        ["completed", "failed"].forEach(key => {
            el(`throughput-${key}`).innerHTML = data.charts[key];
        });
        el("chart-data").replaceChildren(...hours.map(h => {
            const row = node("tr", ""); [new Date(h.hour*1000).toISOString().slice(0,16).replace("T", " "), h.completed, h.failed].forEach(v => row.append(node("td", v))); return row;
        }));
    };
    const renderSandbox = sandbox => {
        const status = el("sandbox");
        const alarm = el("isolation-alarm");
        if (!status || !alarm) return;
        const unavailable = ["unsupported", "error"].includes(sandbox.state);
        const message = el("isolation-message");
        // Avoid announcing an unchanged alarm on every background refresh.
        if (message.textContent !== sandbox.message) message.textContent = sandbox.message;
        if (status.textContent !== sandbox.message) status.textContent = sandbox.message;
        status.dataset.state = sandbox.state;
        status.hidden = unavailable;
        alarm.hidden = !unavailable;
    };
    const render = data => {
        renderSandbox(data.sandbox);
        ["queued", "running", "completed"].forEach(k => text(k, count(data.counts, "status", k)));
        text("workers", data.workers);
        text("attention", count(data.counts, "status", "failed") + count(data.delivery, "delivery", "failed"));
        renderChart(data);
        const mib = n => (n / 1048576).toLocaleString([], {maximumFractionDigits: 1});
        text("cache-size", `${mib(data.cache.bytes)} / ${mib(data.cache.limit)} MiB`);
        text("cache-items", data.cache.items);
        el("cache-meter").max = data.cache.limit;
        el("cache-meter").value = data.cache.bytes;
        const states = ["pending", "sending", "delivered", "failed", "expired"];
        const total = Math.max(1, states.reduce((n,k) => n+count(data.delivery, "delivery", k), 0));
        el("delivery").replaceChildren(...states.map(k => {
            const row = node("div", ""); row.className = "mr-delivery-row";
            const value = count(data.delivery, "delivery", k), meter = document.createElement("meter");
            meter.min = 0; meter.max = total; meter.value = value; meter.setAttribute("aria-label", label(k));
            row.append(node("span", label(k)), meter, node("strong", value)); return row;
        }));
        el("jobs").replaceChildren(...data.jobs.map(job => {
            const row = node("tr", "");
            const id = node("td", job.id.slice(0, 12)); id.title = job.id;
            const status = node("td", ""); status.append(badge(job.status));
            if (job.cache_hit) status.append(node("small", label("cached")));
            if (job.error) status.append(node("small", job.error));
            const duration = job.started ? `${Math.max(0, (job.finished || data.updated)-job.started)} s` : "—";
            const delivery = node("td", ""); delivery.append(badge(job.delivery));
            row.append(id, node("td", job.profile), status, node("td", date(job.created)), node("td", duration), delivery, node("td", job.attempts));
            return row;
        }));
        el("empty").hidden = data.jobs.length !== 0;
        lastUpdated = data.updated;
        freshness();
    };
    const freshness = () => {
        if (lastUpdated) text("freshness", `${label("updated")} ${date(lastUpdated)}${el("live").checked ? "" : ` · ${label("paused")}`}`);
        el("error").hidden = !stale;
    };
    const refresh = async () => {
        if (busy) return;
        busy = true; el("refresh").disabled = true;
        const requestedFilter = filter.value;
        try {
            const response = await cotonic.broker.call("bridge/origin/model/mediarunner/get/status", {filter: requestedFilter}, {timeout: 15000});
            if (response.payload.status !== "ok" || !response.payload.result?.jobs) throw new Error("No snapshot");
            stale = false;
            if (requestedFilter === filter.value) render(response.payload.result);
        } catch (_) { stale = true; freshness(); }
        finally { busy = false; el("refresh").disabled = false; }
        if (requestedFilter !== filter.value) refresh();
    };
    filter.addEventListener("change", () => {
        const url = new URL(location.href);
        if (filter.value) url.searchParams.set("status", filter.value); else url.searchParams.delete("status");
        history.pushState(null, "", url); refresh();
    });
    window.addEventListener("popstate", () => { fromUrl(); refresh(); });
    el("refresh").addEventListener("click", refresh);
    el("live").addEventListener("change", () => { freshness(); if (el("live").checked) refresh(); });
    document.addEventListener("visibilitychange", () => { if (!document.hidden && el("live").checked) refresh(); });
    cotonic.ready.then(() => { refresh(); setInterval(() => { if (!document.hidden && el("live").checked) refresh(); }, 10000); });
})();
